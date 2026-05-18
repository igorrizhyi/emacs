;;; agent-shell-team-events.el --- WebSocket notification router for agent-shell-team -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Igor Rizhyi
;; Keywords: tools, ai, team

;;; Commentary:

;; Routes incoming WebSocket notifications from the gang-of-none Python
;; backend to the appropriate Emacs handlers in agent-shell-team.
;;
;; The WS module calls `agent-shell-team-events--handle-notification'
;; for every server notification.  This module dispatches based on the
;; method string and translates snake_case JSON params to the signatures
;; expected by existing handlers.

;;; Code:

(require 'map)
(require 'agent-shell-chat-buffer)

;; Cross-module forward declarations
(declare-function agent-shell-team--handle-task-update "agent-shell-team"
                  (raw-input))
(declare-function agent-shell-team--notify-group-complete "agent-shell-team"
                  (session-id group-id group))
(declare-function agent-shell-team--register-agent "agent-shell-team"
                  (session-id buffer role mode &optional worktree worktree-name))
(declare-function agent-shell-team--unregister-agent "agent-shell-team"
                  (buffer))
(declare-function agent-shell-team--notify "agent-shell-team"
                  (title message))
(declare-function agent-shell-team--get-session-agents "agent-shell-team"
                  (session-id))
(declare-function agent-shell-team--buffer-name "agent-shell-team"
                  (session-id role &optional worktree-name))
(declare-function my/team-sidebar--render "my-agent-shell-sidebar")
(declare-function my/approval--receive-request "my-approval-ui"
                  (request))
(declare-function my/approval--remove-request "my-approval-ui"
                  (request-id))
(declare-function agent-shell-team-merge--show-conflict "agent-shell-team-merge"
                  (request-id error-msg))
(declare-function agent-shell-team-state-set-task "agent-shell-team-state"
                  (request-id task-alist))
(declare-function agent-shell-team-state-set-approval "agent-shell-team-state"
                  (request-id approval-alist))
(declare-function agent-shell-team-state-remove-approval "agent-shell-team-state"
                  (request-id))
(declare-function agent-shell-team-state-remove-task "agent-shell-team-state"
                  (request-id))
(declare-function agent-shell-team-dispatch-prompt-agent "agent-shell-team-dispatch"
                  (agent-id message &optional callback))
;; agent-shell-ui — collapsible section system (works in any buffer)
(declare-function agent-shell-ui-mode "agent-shell-ui" (&optional arg))
(declare-function agent-shell-ui-make-fragment-model "agent-shell-ui"
                  (&rest args))
(declare-function agent-shell-ui-update-fragment "agent-shell-ui"
                  (model &rest args))
(declare-function agent-shell--make-status-kind-label "agent-shell-styles"
                  (&rest args))

;; Task chat — mirror session updates to task-scoped buffers
(declare-function agent-shell-team-task-chat--on-status-changed
                  "agent-shell-team-task-chat" (params))
(declare-function agent-shell-team-task-chat--on-session-update
                  "agent-shell-team-task-chat" (params))

;; Variables from agent-shell-team we reference
(defvar agent-shell-team--session-id)
(defvar agent-shell-team--agent-id)
(defvar agent-shell-team--init-finished-p)
(defvar agent-shell-team--model-id)
(defvar agent-shell-team--request-to-session)
(defvar agent-shell-team--task-groups)
(defvar agent-shell-team--sessions)
(defvar agent-shell-team--server-mode-p)

;; Variables from my-agent-shell-style we reference
(defvar my/agent-shell-server--current-msg-ov)
(defvar my/agent-shell-server--current-thought-ov)

;;; Buffer-local variables for streaming agent output

(defvar-local agent-shell-team-events--tool-calls (make-hash-table :test 'equal)
  "Hash-table mapping toolCallId -> marker for in-progress tool call sections.")

(defvar-local agent-shell-team-events--usage nil
  "Plist of latest usage data from the agent session, for modeline display.")

(defvar-local agent-shell-team-events--turn-in-progress nil
  "Non-nil when an agent turn is in progress (waiting for response).")

;;; Hook point — the WS module sets this to our dispatcher

(defvar agent-shell-team-ws-notification-handler nil
  "Function called by the WS module for every incoming server notification.
Set to `agent-shell-team-events--handle-notification' on module load.")

;;; Pending events queue — buffers events that arrive before agent/spawned

(defvar agent-shell-team-events--pending-events (make-hash-table :test 'equal)
  "Hash-table mapping agent-id -> list of (METHOD . PARAMS) conses.
Events that arrive before the agent is registered are queued here and
replayed after `agent/spawned' completes registration.")

;;; Internal helpers

(defun agent-shell-team-events--finish-turn ()
  "Finish the current agent turn.
Finalizes overlays, adds outer spacing, writes a fresh prompt, and
hides the input area.  Must be called from within the agent buffer."
  (message "CALLER: finish-turn -> finalize-overlays")
  (when (fboundp 'my/agent-shell-server--finalize-overlays)
    (my/agent-shell-server--finalize-overlays))
  ;; Add outer spacing between last block and prompt
  (when agent-shell-team-events--turn-in-progress
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (marker-position agent-shell-chat-buffer--history-end))
        (unless (bolp) (insert "\n"))
        (insert "\n"))))
  ;; Write a fresh prompt and hide it
  (when agent-shell-team-events--turn-in-progress
    (agent-shell-chat-buffer-finish-turn (current-buffer))
    (agent-shell-chat-buffer-hide-input (current-buffer))
    (setq agent-shell-team-events--turn-in-progress nil)))

(defun agent-shell-team-events--hide-prompt ()
  "Hide the input area in server-mode agent buffers."
  (when (bound-and-true-p agent-shell-team--server-mode-p)
    (agent-shell-chat-buffer-hide-input (current-buffer))))

(defun agent-shell-team-events--show-prompt ()
  "Show the input area in server-mode agent buffers."
  (when (bound-and-true-p agent-shell-team--server-mode-p)
    (agent-shell-chat-buffer-show-input (current-buffer))))

(defun agent-shell-team-events--dump-overlays (label)
  "Log all styled overlays in the current buffer with LABEL prefix."
  (let ((ovs (seq-filter
              (lambda (ov)
                (or (overlay-get ov 'face)
                    (overlay-get ov 'agent-shell-prompt-hide)
                    (overlay-get ov 'invisible)))
              (overlays-in (point-min) (point-max)))))
    (message "OVERLAY-DUMP [%s]: %d overlays in %s (point-max=%s)"
             label (length ovs) (buffer-name) (point-max))
    (dolist (ov ovs)
      (message "  ov %s-%s face=%s invis=%s prompt-hide=%s evap=%s"
               (overlay-start ov) (overlay-end ov)
               (overlay-get ov 'face)
               (overlay-get ov 'invisible)
               (overlay-get ov 'agent-shell-prompt-hide)
               (overlay-get ov 'evaporate)))))

;; submit-and-trim is no longer needed — agent-shell-chat-buffer--submit
;; handles input extraction and history commitment directly.

(defun agent-shell-team-events--set-agent-status (agent-id status)
  "Update the status field of AGENT-ID in the session registry."
  (when (and agent-id status (boundp 'agent-shell-team--sessions))
    (catch 'done
      (maphash
       (lambda (_session-id agents)
         (dolist (agent agents)
           (let ((wt-name (alist-get 'worktree-name agent))
                 (buf (alist-get 'buffer agent))
                 (aid (alist-get 'agent-id agent)))
             (when (or (and wt-name (string= wt-name agent-id))
                       (and aid (string= aid agent-id))
                       (and buf (buffer-live-p buf)
                            (buffer-local-value 'agent-shell-team--agent-id buf)
                            (equal (buffer-local-value 'agent-shell-team--agent-id buf)
                                   agent-id)))
               (if (assq 'status agent)
                   (setcdr (assq 'status agent) status)
                 (push (cons 'status status) (cdr agent)))
               (throw 'done t)))))
       agent-shell-team--sessions))))

(defun agent-shell-team-events--queue-event (agent-id method params)
  "Queue a (METHOD . PARAMS) event for AGENT-ID to replay after spawned."
  (let ((queue (gethash agent-id agent-shell-team-events--pending-events)))
    (puthash agent-id (append queue (list (cons method params)))
             agent-shell-team-events--pending-events))
  (message "agent-shell-team-events: queued %s for unregistered agent %s" method agent-id))

(defun agent-shell-team-events--replay-pending (agent-id)
  "Replay any queued events for AGENT-ID, then clear the queue."
  (when-let ((events (gethash agent-id agent-shell-team-events--pending-events)))
    (message "agent-shell-team-events: replaying %d pending events for %s"
             (length events) agent-id)
    (remhash agent-id agent-shell-team-events--pending-events)
    (dolist (event events)
      (let ((method (car event))
            (params (cdr event)))
        (agent-shell-team-events--handle-notification method params)))))

(defun agent-shell-team-events--get-param (params key)
  "Extract KEY from PARAMS, trying keyword, symbol, and string forms."
  (or (plist-get params (intern (concat ":" key)))
      (map-elt params (intern key))
      (map-elt params key)))

(defun agent-shell-team-events--get-agent-id (params)
  "Extract agent ID from PARAMS, trying agent_id and id keys.
The backend uses `agent_id' in some frames (spawned, session/update) and
`id' in others (statusChanged, dismissed)."
  (or (agent-shell-team-events--get-param params "agent_id")
      (agent-shell-team-events--get-param params "id")))

(defun agent-shell-team-events--find-agent-buffer (agent-id)
  "Find the Emacs buffer for AGENT-ID by matching worktree-name across all sessions.
Returns the buffer or nil if not found.  Also checks buffer-local agent-id."
  (when (and agent-id (boundp 'agent-shell-team--sessions))
    (catch 'found
      (maphash
       (lambda (_session-id agents)
         (dolist (agent agents)
           (let* ((buf (alist-get 'buffer agent))
                  (buf (if (and (stringp buf) (get-buffer buf))
                           (get-buffer buf)
                         buf))
                  (wt-name (alist-get 'worktree-name agent)))
             (when (and buf (buffer-live-p buf))
               (when (or (and wt-name (string= wt-name agent-id))
                         (and (boundp 'agent-shell-team--agent-id)
                              (buffer-local-value 'agent-shell-team--agent-id buf)
                              (equal (buffer-local-value 'agent-shell-team--agent-id buf)
                                     agent-id)))
                 (throw 'found buf))))))
       agent-shell-team--sessions)
      nil)))

;;; Event handlers

(defun agent-shell-team-events--on-task-status-changed (params)
  "Handle task/statusChanged — delegate to `agent-shell-team--handle-task-update'.
PARAMS contains request_id, status, content, commit."
  (agent-shell-team--handle-task-update params))

(defun agent-shell-team-events--on-task-group-complete (params)
  "Handle task/groupComplete — delegate to `agent-shell-team--notify-group-complete'.
PARAMS contains group_id and completed (list of request IDs)."
  (let ((group-id (agent-shell-team-events--get-param params "group_id"))
        (completed (agent-shell-team-events--get-param params "completed")))
    (when group-id
      (let* ((session-id (or (bound-and-true-p agent-shell-team--session-id)
                             ;; Try to find session from the group tracker
                             (when (boundp 'agent-shell-team--task-groups)
                               (let ((group (gethash group-id agent-shell-team--task-groups)))
                                 (plist-get group :session-id)))))
             (group (list :completed (append completed nil))))
        (when session-id
          (agent-shell-team--notify-group-complete session-id group-id group))))))

(defvar-local agent-shell-team--server-mode-p nil
  "Non-nil when this buffer is backed by the Python backend.")

(defun agent-shell-team-events--on-agent-spawned (params)
  "Handle agent/spawned — create a plain chat buffer and register it.
PARAMS contains agent_id, project_id (or legacy session_id), role,
worktree_path, worktree_name, model.
In server mode the backend manages the ACP subprocess.  The buffer uses
`agent-shell-chat-buffer' for interactive input, routing to `promptAgent'
WS RPC."
  (let ((session-id (or (agent-shell-team-events--get-param params "session_id")
                        (agent-shell-team-events--get-param params "project_id")
                        (bound-and-true-p agent-shell-team--session-id)))
        (role (agent-shell-team-events--get-param params "role"))
        (worktree-path (agent-shell-team-events--get-param params "worktree_path"))
        (worktree-name (agent-shell-team-events--get-param params "worktree_name"))
        (model (agent-shell-team-events--get-param params "model"))
        (agent-id (agent-shell-team-events--get-agent-id params)))
    (message "agent-shell-team-events: on-agent-spawned ENTER id=%s role=%s session=%s"
             agent-id role session-id)
    ;; Normalize master_lead → lead for buffer naming and UI
    (when (equal role "master_lead")
      (setq role "lead"))
    ;; Guard: skip if buffer already exists for this agent-id (prevents duplicates
    ;; when both RPC callback and broadcast notification fire)
    (if (and agent-id (agent-shell-team-events--find-agent-buffer agent-id))
        (message "agent-shell-team-events: on-agent-spawned SKIP duplicate id=%s" agent-id)
      (when (and session-id role)
        (let* ((wt-name (or worktree-name agent-id))
               (buf-name (agent-shell-team--buffer-name session-id role wt-name))
               (agent-id-copy agent-id)
               ;; Create plain chat buffer with promptAgent as submit handler
               (buffer (agent-shell-chat-buffer-create
                        buf-name
                        "agent> "
                        (lambda (command)
                          (let ((buf (current-buffer)))
                            (setq agent-shell-team-events--turn-in-progress t)
                            (agent-shell-team-dispatch-prompt-agent
                             agent-id-copy
                             command
                             (lambda (_result error)
                               (when error
                                 (message "promptAgent error for %s: %s"
                                          agent-id-copy error))
                               ;; Finish turn when RPC response arrives
                               (when (and buf (buffer-live-p buf))
                                 (with-current-buffer buf
                                   (agent-shell-team-events--finish-turn))))))))))
          (message "agent-shell-team-events: agent/spawned id=%s role=%s model=%s buffer=%s"
                   agent-id role (or model "default") buf-name)
          ;; Register in team session roster (mode "server" = backend-managed)
          (agent-shell-team--register-agent session-id buffer role "server"
                                            worktree-path wt-name)
          ;; Set buffer-local variables for server-mode agents
          (with-current-buffer buffer
            (setq agent-shell-team--session-id session-id
                  agent-shell-team--agent-id agent-id
                  agent-shell-team--init-finished-p t
                  agent-shell-team--server-mode-p t)
            (when model
              (setq agent-shell-team--model-id model))
            ;; Evil mode show/hide is already wired by agent-shell-chat-buffer-create
            ;; but we also want our wrappers for server-mode checks
            (add-hook 'evil-insert-state-entry-hook
                      #'agent-shell-team-events--show-prompt nil t)
            (add-hook 'evil-normal-state-entry-hook
                      #'agent-shell-team-events--hide-prompt nil t)
            ;; Enable collapsible section system
            (when (fboundp 'agent-shell-ui-mode)
              (agent-shell-ui-mode +1)))
          ;; Store agent-id in the roster alist entry for lookup by dismissed handler
          (let* ((agents (agent-shell-team--get-session-agents session-id))
                 (entry (cl-find buffer agents
                                 :key (lambda (a) (alist-get 'buffer a)))))
            (when entry
              (push (cons 'agent-id agent-id) (cdr entry))))
          ;; Replay any events that arrived before this agent was registered
          (when agent-id
            (agent-shell-team-events--replay-pending agent-id))
          ;; Refresh sidebar if visible
          (when-let ((sidebar-buf (get-buffer " *team-sidebar*")))
            (when (get-buffer-window sidebar-buf)
              (my/team-sidebar--render)))
          ;; Auto-switch to lead buffer on initial team start (not slave_leads)
          (when (equal role "lead")
            (switch-to-buffer buffer)))))))


(defun agent-shell-team-events--on-agent-dismissed (params)
  "Handle agent/dismissed — unregister the agent from the session roster.
PARAMS contains agent_id, project_id (or legacy session_id).
Matches by worktree-name or buffer-local agent-id, searching all sessions."
  (let ((agent-id (agent-shell-team-events--get-agent-id params)))
    (message "agent-shell-team-events: agent/dismissed id=%s" agent-id)
    (when agent-id
      ;; Search all sessions for a matching agent
      (let ((agent-buf (agent-shell-team-events--find-agent-buffer agent-id)))
        (if agent-buf
            (progn
              (message "agent-shell-team-events: agent/dismissed — unregistering buffer %s"
                       (if (bufferp agent-buf) (buffer-name agent-buf) agent-buf))
              (agent-shell-team--unregister-agent agent-buf))
          (message "agent-shell-team-events: agent/dismissed — no buffer found for agent-id=%s"
                   agent-id))))))

(defun agent-shell-team-events--on-agent-status-changed (params)
  "Handle agent/statusChanged — update sidebar and modeline.
PARAMS contains agent_id, status, project_id (or legacy session_id), current_task_id."
  (let ((agent-id (agent-shell-team-events--get-agent-id params))
        (status (agent-shell-team-events--get-param params "status"))
        (session-id (or (agent-shell-team-events--get-param params "session_id")
                        (agent-shell-team-events--get-param params "project_id")
                        (bound-and-true-p agent-shell-team--session-id))))
    (when agent-id
      (message "agent-shell-team-events: agent/statusChanged id=%s status=%s"
               agent-id status)
      ;; Update agent → task mapping for task chat routing
      (when (fboundp 'agent-shell-team-task-chat--on-status-changed)
        (agent-shell-team-task-chat--on-status-changed params))
      ;; Check if agent is registered yet; if not, queue for replay after spawned
      (if (not (agent-shell-team-events--find-agent-buffer agent-id))
          (agent-shell-team-events--queue-event agent-id "agent/statusChanged" params)
        ;; Update status in the agent registry alist
        (agent-shell-team-events--set-agent-status agent-id status)
        ;; When agent becomes idle, finish the turn (backup trigger)
        (when (equal status "idle")
          (let ((buffer (agent-shell-team-events--find-agent-buffer agent-id)))
            (when (and buffer (buffer-live-p buffer))
              (with-current-buffer buffer
                (message "CALLER: statusChanged-idle -> finish-turn")
                (agent-shell-team-events--finish-turn))))))
      ;; Refresh sidebar if visible
      (when-let ((sidebar-buf (get-buffer " *team-sidebar*")))
        (when (get-buffer-window sidebar-buf)
          (my/team-sidebar--render)))
      ;; Force modeline update on all team buffers in this session
      (when session-id
        (dolist (agent (agent-shell-team--get-session-agents session-id))
          (let ((buf (alist-get 'buffer agent)))
            (when (buffer-live-p buf)
              (with-current-buffer buf
                (force-mode-line-update)))))))))

(defun agent-shell-team-events--on-notification (params)
  "Handle notification — desktop notification.
PARAMS contains title, message."
  (let ((title (agent-shell-team-events--get-param params "title"))
        (message-text (agent-shell-team-events--get-param params "message")))
    (when (and title message-text)
      (agent-shell-team--notify title message-text))))

(defun agent-shell-team-events--on-approval-request (params)
  "Handle approval/request — route to `my/approval--receive-request'.
PARAMS contains request_id, title, type, items, description."
  (let ((request-id (agent-shell-team-events--get-param params "request_id"))
        (title (agent-shell-team-events--get-param params "title"))
        (type-str (agent-shell-team-events--get-param params "type"))
        (items (agent-shell-team-events--get-param params "items"))
        (description (agent-shell-team-events--get-param params "description")))
    (message "agent-shell-team-events: approval/request id=%s title=%s type=%s items=%d"
             request-id title type-str (length items))
    (if (fboundp 'my/approval--receive-request)
        ;; Convert backend items (alists) to the plist format expected by the UI
        (my/approval--receive-request
         (list :request-id request-id
               :title title
               :description (or description "")
               :type type-str
               :items (mapcar
                       (lambda (item)
                         (let ((id (or (plist-get item :id)
                                       (map-elt item 'id)
                                       (map-elt item "id")))
                               (label (or (plist-get item :label)
                                          (map-elt item 'label)
                                          (map-elt item "label")))
                               (desc (or (plist-get item :description)
                                         (map-elt item 'description)
                                         (map-elt item "description") ""))
                               (default-sel (or (plist-get item :default_selected)
                                                (map-elt item 'default_selected)
                                                (map-elt item "default_selected"))))
                           (list :id id
                                 :label label
                                 :description (or desc "")
                                 (if (equal type-str "checklist") :checked :selected)
                                 (eq default-sel t))))
                       (append items nil))
               :notes ""
               :timestamp (float-time)))
      ;; Fallback: desktop notification if approval UI not loaded
      (agent-shell-team--notify
       (or title "Approval Required")
       (or description (format "Approval request: %s" request-id))))))

;;; Session update handlers — streaming agent output

(defun agent-shell-team-events--insert-at-end (buffer text)
  "Insert TEXT into the history region of BUFFER.
Uses `agent-shell-chat-buffer-insert' which inserts before the
history-end marker.  The marker has insertion-type t so it advances
automatically — no comint prompt juggling needed.
Returns (START . END) of the inserted region, or nil."
  (agent-shell-chat-buffer-insert buffer text))

(defun agent-shell-team-events--on-message-chunk (buffer update)
  "Handle agent_message_chunk — append text to agent BUFFER.
UPDATE contains content.text."
  (let* ((content (agent-shell-team-events--get-param update "content"))
         (text (and content (agent-shell-team-events--get-param content "text"))))
    ;; First chunk of a new message: trim leading \n from text AND
    ;; collapse excess blank lines above the insertion point to \n\n
    ;; (one visible blank line between user input and response block)
    (when (and text (buffer-live-p buffer)
               (not (buffer-local-value 'my/agent-shell-server--current-msg-ov buffer)))
      (setq text (string-trim-left text "\n+"))
      (with-current-buffer buffer
        (let* ((inhibit-read-only t)
               ;; Trim at history-end marker — the insertion point
               (trim-pos (marker-position agent-shell-chat-buffer--history-end)))
          (when trim-pos
            (save-excursion
              (goto-char trim-pos)
              (when (re-search-backward "[^\n\r ]" nil t)
                (forward-char 1)
                (let ((gap (- trim-pos (point))))
                  (message "on-message-chunk TRIM: trim-pos=%s last-content=%s gap=%s"
                           trim-pos (point) gap)
                  ;; Keep up to 2 newlines (\n\n = one blank line gap)
                  (when (> gap 2)
                    (delete-region (+ (point) 2) trim-pos)))))))))
    (when-let ((range (agent-shell-team-events--insert-at-end buffer text)))
      (with-current-buffer buffer
        (when (fboundp 'my/agent-shell-server--extend-or-create-msg-ov)
          (my/agent-shell-server--extend-or-create-msg-ov
           (car range) (cdr range)))))))

(defun agent-shell-team-events--on-thought-chunk (buffer update)
  "Handle agent_thought_chunk — append thinking text to agent BUFFER.
UPDATE contains content.text."
  (let* ((content (agent-shell-team-events--get-param update "content"))
         (text (and content (agent-shell-team-events--get-param content "text"))))
    (when (and (stringp text) (> (length text) 0))
      (when-let ((range (agent-shell-team-events--insert-at-end buffer text)))
        (with-current-buffer buffer
          (when (fboundp 'my/agent-shell-server--extend-or-create-thought-ov)
            (my/agent-shell-server--extend-or-create-thought-ov
             (car range) (cdr range))))))))

(defun agent-shell-team-events--tool-status-to-ui (status)
  "Map WS tool STATUS string to agent-shell-ui status."
  (pcase status
    ((or "pending" "running") "in_progress")
    ((or "done" "completed") "completed")
    ("error" "failed")
    (_ (or status "in_progress"))))

(defun agent-shell-team-events--tool-kind (title)
  "Extract tool kind from TITLE string (e.g. \"Read\" -> \"read\")."
  (when (stringp title)
    (let ((word (car (split-string title " " t))))
      (when word (downcase word)))))

(defun agent-shell-team-events--on-tool-call (buffer update)
  "Handle tool_call — insert collapsible tool call section in BUFFER.
UPDATE contains toolCallId, title, status, kind."
  (let ((tool-id (agent-shell-team-events--get-param update "toolCallId"))
        (title (or (agent-shell-team-events--get-param update "title") "Tool"))
        (status (or (agent-shell-team-events--get-param update "status") "running"))
        (kind (agent-shell-team-events--get-param update "kind")))
    (when (and (buffer-live-p buffer) tool-id)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (if (fboundp 'agent-shell-ui-update-fragment)
              ;; Use agent-shell-ui collapsible sections
              (let* ((ui-status (agent-shell-team-events--tool-status-to-ui status))
                     (ui-kind (or kind (agent-shell-team-events--tool-kind title)))
                     (label-left (when (fboundp 'agent-shell--make-status-kind-label)
                                   (agent-shell--make-status-kind-label
                                    :status ui-status :kind ui-kind)))
                     (label-right (propertize title 'font-lock-face
                                             'font-lock-doc-markup-face))
                     (model (agent-shell-ui-make-fragment-model
                             :namespace-id (or (bound-and-true-p agent-shell-team--agent-id)
                                               "server")
                             :block-id tool-id
                             :label-left label-left
                             :label-right label-right
                             :body nil)))
                (agent-shell-ui-update-fragment model
                                                :expanded nil
                                                :no-undo t))
            ;; Fallback: plain text
            (save-excursion
              (goto-char (point-max))
              (insert (format "\n[%s] %s\n" title status)))))))))

(defun agent-shell-team-events--on-tool-call-update (buffer update)
  "Handle tool_call_update — update existing tool call section in BUFFER.
UPDATE contains toolCallId, status, content, title."
  (let ((tool-id (agent-shell-team-events--get-param update "toolCallId"))
        (status (agent-shell-team-events--get-param update "status"))
        (content (agent-shell-team-events--get-param update "content"))
        (title (agent-shell-team-events--get-param update "title")))
    (when (and (buffer-live-p buffer) tool-id)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (if (fboundp 'agent-shell-ui-update-fragment)
              (progn
                ;; Append body content if present
                (when (and (stringp content) (> (length content) 0))
                  (agent-shell-ui-update-fragment
                   (agent-shell-ui-make-fragment-model
                    :namespace-id (or (bound-and-true-p agent-shell-team--agent-id)
                                      "server")
                    :block-id tool-id
                    :body content)
                   :append t :no-undo t))
                ;; Update status badge on completion/error
                (when (member status '("done" "completed" "error"))
                  (let* ((ui-status (agent-shell-team-events--tool-status-to-ui status))
                         (ui-kind (agent-shell-team-events--tool-kind
                                   (or title "Tool")))
                         (label-left (agent-shell--make-status-kind-label
                                     :status ui-status :kind ui-kind)))
                    (agent-shell-ui-update-fragment
                     (agent-shell-ui-make-fragment-model
                      :namespace-id (or (bound-and-true-p agent-shell-team--agent-id)
                                        "server")
                      :block-id tool-id
                      :label-left label-left)
                     :no-undo t))))
            ;; Fallback: plain text
            (when (and (stringp content) (> (length content) 0))
              (agent-shell-team-events--insert-at-end buffer content))))))))

(defun agent-shell-team-events--on-plan (buffer update)
  "Handle plan — render plan entries in BUFFER.
UPDATE contains entries array."
  (let ((entries (agent-shell-team-events--get-param update "entries")))
    (when (and entries (> (length entries) 0))
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              start)
          (save-excursion
            (goto-char (point-max))
            (setq start (point))
            (insert "\n--- Plan ---\n")
            (seq-do
             (lambda (entry)
               (let ((content (or (agent-shell-team-events--get-param entry "content")
                                  (format "%s" entry))))
                 (insert (format "  - %s\n" content))))
             entries)
            (when (boundp 'my/agent-shell-server-plan-face)
              (my/agent-shell-server--apply-block-overlay
               start (point) my/agent-shell-server-plan-face))))))))

(defun agent-shell-team-events--on-usage-update (buffer update)
  "Handle usage_update — store usage data as buffer-local var in BUFFER.
UPDATE contains usage plist."
  (let ((usage (agent-shell-team-events--get-param update "usage")))
    (when (and (buffer-live-p buffer) usage)
      (with-current-buffer buffer
        (setq agent-shell-team-events--usage usage)
        (force-mode-line-update)))))

(defun agent-shell-team-events--on-session-update (params)
  "Handle agent/session/update — route streaming output to the agent buffer.
PARAMS contains agent_id, sessionId, and update with sessionUpdate type."
  (let* ((agent-id (agent-shell-team-events--get-agent-id params))
         (update (agent-shell-team-events--get-param params "update"))
         (update-type (and update
                           (agent-shell-team-events--get-param update "sessionUpdate")))
         (buffer (agent-shell-team-events--find-agent-buffer agent-id)))
    ;; Mirror to task chat buffer (if agent has an active task with open chat)
    (when (and agent-id update
               (fboundp 'agent-shell-team-task-chat--on-session-update))
      (agent-shell-team-task-chat--on-session-update params))
    (if (not buffer)
        ;; Agent not registered yet — queue for replay after spawned
        (when agent-id
          (agent-shell-team-events--queue-event agent-id "agent/session/update" params))
      (message "agent-shell-team-events: sessionUpdate type=%s agent=%s" update-type agent-id)
      (pcase update-type
        ("agent_message_chunk"
         (agent-shell-team-events--on-message-chunk buffer update))
        ("agent_thought_chunk"
         (agent-shell-team-events--on-thought-chunk buffer update))
        ("tool_call"
         (agent-shell-team-events--on-tool-call buffer update))
        ("tool_call_update"
         (agent-shell-team-events--on-tool-call-update buffer update))
        ("plan"
         (agent-shell-team-events--on-plan buffer update))
        ("usage_update"
         (agent-shell-team-events--on-usage-update buffer update))
        ("new_message_start"
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq-local agent-shell-team--new-message-pending t)
             (when (fboundp 'my/agent-shell-server--reset-msg-overlay)
               (my/agent-shell-server--reset-msg-overlay)))))
        ;; Silent/modeline-only updates
        ("available_commands_update" nil)
        ("current_mode_update"
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (force-mode-line-update))))
        (_
         (message "agent-shell-team-events: unknown sessionUpdate type %S for agent %s"
                  update-type agent-id))))))

;;; Additional event handlers (gang-of-none spec)

(defvar-local agent-shell-team--new-message-pending nil
  "Non-nil when the next message chunk should start a new message bubble.")

(defvar-local agent-shell-team--pending-permission nil
  "Plist of the current pending permission request, or nil.")

(defun agent-shell-team-events--on-task-created (params)
  "Handle task/created — log new task creation.
PARAMS is the full task object."
  (let ((request-id (agent-shell-team-events--get-param params "request_id"))
        (role (agent-shell-team-events--get-param params "role")))
    (message "agent-shell-team-events: task/created request_id=%s role=%s"
             request-id role)))

(defun agent-shell-team-events--on-agent-respawned (params)
  "Handle agent/respawned — update or create agent buffer.
PARAMS contains agent_id, role, status, worktree_name, worktree_path."
  (let ((agent-id (agent-shell-team-events--get-agent-id params))
        (role (agent-shell-team-events--get-param params "role"))
        (status (agent-shell-team-events--get-param params "status"))
        (worktree-name (agent-shell-team-events--get-param params "worktree_name"))
        (worktree-path (agent-shell-team-events--get-param params "worktree_path")))
    (message "agent-shell-team-events: agent/respawned id=%s status=%s" agent-id status)
    (let ((buffer (agent-shell-team-events--find-agent-buffer agent-id)))
      (if buffer
          ;; Agent buffer exists — just update status
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (force-mode-line-update)))
        ;; No buffer — create one (reuse spawned handler logic)
        (agent-shell-team-events--on-agent-spawned params)))))

(defun agent-shell-team-events--on-permission-request (params)
  "Handle agent/session/request_permission — show permission prompt.
PARAMS contains agent_id and request (with toolCallId, title, description)."
  (let* ((agent-id (agent-shell-team-events--get-agent-id params))
         (request (agent-shell-team-events--get-param params "request"))
         (title (and request (agent-shell-team-events--get-param request "title")))
         (description (and request (agent-shell-team-events--get-param request "description")))
         (buffer (agent-shell-team-events--find-agent-buffer agent-id)))
    (message "agent-shell-team-events: permission request for agent %s: %s" agent-id title)
    (when (and buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        (setq-local agent-shell-team--pending-permission
                    (list :agent-id agent-id
                          :request request
                          :title title
                          :description description))
        (agent-shell-team-events--insert-at-end
         buffer
         (format "\n⚠ Permission requested: %s\n  %s\n"
                 (or title "unknown")
                 (or description "")))))))

(defun agent-shell-team-events--on-approval-cancelled (params)
  "Handle approval/cancelled — remove from approval UI.
PARAMS contains request_id."
  (let ((request-id (agent-shell-team-events--get-param params "request_id")))
    (message "agent-shell-team-events: approval/cancelled request_id=%s" request-id)
    (when (and request-id (fboundp 'my/approval--remove-request))
      (my/approval--remove-request request-id))))

;;; Merge approval event handlers

(defun agent-shell-team-events--on-task-implemented (params)
  "Handle task/implemented — update state and create merge approval.
PARAMS contains request_id, objective, dev_branch, commit, report_path."
  (let ((request-id (agent-shell-team-events--get-param params "request_id"))
        (objective (or (agent-shell-team-events--get-param params "objective")
                       (agent-shell-team-events--get-param params "message") ""))
        (dev-branch (agent-shell-team-events--get-param params "dev_branch"))
        (commit (agent-shell-team-events--get-param params "commit")))
    (message "agent-shell-team-events: task/implemented request_id=%s branch=%s"
             request-id dev-branch)
    ;; Update task state to implemented
    (when (fboundp 'agent-shell-team-state-set-task)
      (agent-shell-team-state-set-task
       request-id
       `((request_id . ,request-id)
         (status . "implemented")
         (objective . ,objective)
         (dev_branch . ,dev-branch)
         (commit . ,commit))))
    ;; Create a merge approval in the approval UI
    (when (fboundp 'my/approval--receive-request)
      (my/approval--receive-request
       (list :request-id (concat "merge:" request-id)
             :title (format "Merge: %s" (truncate-string-to-width objective 50))
             :description (format "Branch: %s  Commit: %s"
                                  (or dev-branch "?") (or commit "?"))
             :type "choice"
             :merge-p t
             :merge-request-id request-id
             :merge-branch dev-branch
             :merge-commit commit
             :items (list (list :id "approve" :label "Approve & Merge" :selected t
                                :description "Merge the dev branch into main")
                          (list :id "reject" :label "Reject"
                                :description "Reject and send back for revision"))
             :notes ""
             :timestamp (float-time))))))

(defun agent-shell-team-events--on-merge-approval-created (params)
  "Handle merge_approval/created — show merge approval in approval UI.
PARAMS contains approval_id, request_id, task data."
  (let ((approval-id (agent-shell-team-events--get-param params "approval_id"))
        (request-id (agent-shell-team-events--get-param params "request_id"))
        (objective (or (agent-shell-team-events--get-param params "objective") ""))
        (dev-branch (agent-shell-team-events--get-param params "dev_branch"))
        (commit (agent-shell-team-events--get-param params "commit")))
    (message "agent-shell-team-events: merge_approval/created approval=%s task=%s"
             approval-id request-id)
    ;; Store in approval state
    (when (fboundp 'agent-shell-team-state-set-approval)
      (agent-shell-team-state-set-approval
       (or approval-id request-id)
       `((approval_id . ,approval-id)
         (request_id . ,request-id)
         (type . "merge_approval")
         (status . "pending")
         (objective . ,objective)
         (dev_branch . ,dev-branch)
         (commit . ,commit))))
    ;; Route to approval UI
    (when (fboundp 'my/approval--receive-request)
      (my/approval--receive-request
       (list :request-id (or approval-id (concat "merge:" request-id))
             :title (format "Merge: %s" (truncate-string-to-width objective 50))
             :description (format "Branch: %s  Commit: %s"
                                  (or dev-branch "?") (or commit "?"))
             :type "choice"
             :merge-p t
             :merge-request-id request-id
             :merge-approval-id approval-id
             :merge-branch dev-branch
             :merge-commit commit
             :items (list (list :id "approve" :label "Approve & Merge" :selected t
                                :description "Merge the dev branch into main")
                          (list :id "reject" :label "Reject"
                                :description "Reject and send back for revision"))
             :notes ""
             :timestamp (float-time))))))

(defun agent-shell-team-events--on-merge-approval-merged (params)
  "Handle merge_approval/merged — merge succeeded, clean up.
PARAMS contains approval_id, request_id."
  (let ((approval-id (agent-shell-team-events--get-param params "approval_id"))
        (request-id (agent-shell-team-events--get-param params "request_id")))
    (message "agent-shell-team-events: merge_approval/merged approval=%s task=%s"
             approval-id request-id)
    ;; Remove from approval state
    (when (and approval-id (fboundp 'agent-shell-team-state-remove-approval))
      (agent-shell-team-state-remove-approval approval-id))
    ;; Remove task from implemented list
    (when (and request-id (fboundp 'agent-shell-team-state-remove-task))
      (agent-shell-team-state-remove-task request-id))
    ;; Remove from approval UI
    (when (fboundp 'my/approval--remove-request)
      (my/approval--remove-request
       (or approval-id (concat "merge:" request-id))))
    ;; Desktop notification
    (agent-shell-team--notify "Merge Complete"
                               (format "Task %s merged successfully" request-id))))

(defun agent-shell-team-events--on-merge-approval-conflict (params)
  "Handle merge_approval/conflict — show conflict UI.
PARAMS contains approval_id, request_id, error or details."
  (let ((approval-id (agent-shell-team-events--get-param params "approval_id"))
        (request-id (agent-shell-team-events--get-param params "request_id"))
        (error-msg (or (agent-shell-team-events--get-param params "error")
                       (agent-shell-team-events--get-param params "details")
                       "Merge conflict detected")))
    (message "agent-shell-team-events: merge_approval/conflict approval=%s task=%s"
             approval-id request-id)
    ;; Update approval state
    (when (and approval-id (fboundp 'agent-shell-team-state-set-approval))
      (agent-shell-team-state-set-approval
       approval-id
       `((approval_id . ,approval-id)
         (request_id . ,request-id)
         (type . "merge_approval")
         (status . "conflict"))))
    ;; Show conflict buffer
    (when (fboundp 'agent-shell-team-merge--show-conflict)
      (agent-shell-team-merge--show-conflict
       (or request-id approval-id) error-msg))
    ;; Desktop notification
    (agent-shell-team--notify "Merge Conflict"
                               (format "Conflict on task %s" request-id))))

;;; Main dispatcher

(defun agent-shell-team-events--handle-notification (method params)
  "Dispatch a WebSocket notification based on METHOD string.
PARAMS is the parsed JSON params object.
Called by the WS module for every incoming server notification."
  (pcase method
    ("task/statusChanged"
     (agent-shell-team-events--on-task-status-changed params))
    ("task/groupComplete"
     (agent-shell-team-events--on-task-group-complete params))
    ("agent/spawned"
     (agent-shell-team-events--on-agent-spawned params))
    ("agent/dismissed"
     (agent-shell-team-events--on-agent-dismissed params))
    ("agent/statusChanged"
     (agent-shell-team-events--on-agent-status-changed params))
    ("agent/session/update"
     (agent-shell-team-events--on-session-update params))
    ("notification"
     (agent-shell-team-events--on-notification params))
    ("approval/request"
     (agent-shell-team-events--on-approval-request params))
    ("approval/cancelled"
     (agent-shell-team-events--on-approval-cancelled params))
    ("task/implemented"
     (agent-shell-team-events--on-task-implemented params))
    ("merge_approval/created"
     (agent-shell-team-events--on-merge-approval-created params))
    ("merge_approval/merged"
     (agent-shell-team-events--on-merge-approval-merged params))
    ("merge_approval/conflict"
     (agent-shell-team-events--on-merge-approval-conflict params))
    ("task/created"
     (agent-shell-team-events--on-task-created params))
    ("agent/respawned"
     (agent-shell-team-events--on-agent-respawned params))
    ("agent/session/request_permission"
     (agent-shell-team-events--on-permission-request params))
    ;; Silent — modeline/polling only
    ("quota/update" nil)
    ("agent/usage" nil)
    (_
     (message "agent-shell-team-events: unknown method %S" method))))

;;; Wiring — set the hook point on load

(setq agent-shell-team-ws-notification-handler
      #'agent-shell-team-events--handle-notification)

(provide 'agent-shell-team-events)

;;; agent-shell-team-events.el ends here
