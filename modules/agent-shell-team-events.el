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
(declare-function make-shell-maker-config "shell-maker")
(declare-function shell-maker-start "shell-maker"
                  (config &optional no-focus welcome-function new-session buffer-name mode-line-name))
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

;; Variables from agent-shell-team we reference
(defvar agent-shell-team--session-id)
(defvar agent-shell-team--agent-id)
(defvar agent-shell-team--init-finished-p)
(defvar agent-shell-team--model-id)
(defvar agent-shell-team--request-to-session)
(defvar agent-shell-team--task-groups)
(defvar agent-shell-team--sessions)
(defvar agent-shell-team--server-mode-p)

;; Variables from shell-maker we reference
(defvar shell-maker--busy)
(defvar shell-maker--config)

;; Variables from my-agent-shell-style we reference
(defvar my/agent-shell-server--current-msg-ov)
(defvar my/agent-shell-server--current-thought-ov)

;;; Buffer-local variables for streaming agent output

(defvar-local agent-shell-team-events--tool-calls (make-hash-table :test 'equal)
  "Hash-table mapping toolCallId -> marker for in-progress tool call sections.")

(defvar-local agent-shell-team-events--usage nil
  "Plist of latest usage data from the agent session, for modeline display.")

(defvar-local agent-shell-team-events--pending-finish nil
  "Closure to call when the agent turn completes (shell-maker :finish-output).")

(defvar-local agent-shell-team-events--prompt-hidden-ov nil
  "Overlay that hides the comint prompt in normal mode.
Non-nil means the prompt is currently hidden.")

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
  "Finish the current agent turn without inserting a duplicate prompt.
In server-mode buffers the prompt is always visible at the bottom, so
`shell-maker-finish-output' (which appends reply + prompt) must NOT be
called.  Instead we just clear the busy flag and the pending-finish
closure.  Must be called from within the agent buffer."
  (setq shell-maker--busy nil)
  (setq agent-shell-team-events--pending-finish nil))

(defun agent-shell-team-events--hide-prompt ()
  "Hide the comint prompt with an invisible overlay.
Only acts in server-mode agent buffers that have a prompt."
  (when (and (bound-and-true-p agent-shell-team--server-mode-p)
             comint-last-prompt
             (markerp (car comint-last-prompt))
             (marker-position (car comint-last-prompt))
             (not agent-shell-team-events--prompt-hidden-ov))
    (let ((ov (make-overlay (car comint-last-prompt)
                            (cdr comint-last-prompt)
                            nil nil nil)))
      (overlay-put ov 'invisible t)
      (overlay-put ov 'evaporate nil)
      (overlay-put ov 'agent-shell-prompt-hide t)
      (setq agent-shell-team-events--prompt-hidden-ov ov))))

(defun agent-shell-team-events--show-prompt ()
  "Show the comint prompt, relocating it to the end of the buffer if needed.
Only acts in server-mode agent buffers."
  (when (and (bound-and-true-p agent-shell-team--server-mode-p)
             agent-shell-team-events--prompt-hidden-ov)
    (delete-overlay agent-shell-team-events--prompt-hidden-ov)
    (setq agent-shell-team-events--prompt-hidden-ov nil)
    (when (and comint-last-prompt
               (markerp (car comint-last-prompt))
               (markerp (cdr comint-last-prompt))
               (marker-position (car comint-last-prompt))
               (marker-position (cdr comint-last-prompt)))
      (let* ((inhibit-read-only t)
             (prompt-start (marker-position (car comint-last-prompt)))
             (prompt-end (marker-position (cdr comint-last-prompt)))
             (prompt-text (buffer-substring prompt-start prompt-end)))
        (message "show-prompt: prompt-pos=%s-%s point-max=%s relocate=%s"
                 prompt-start prompt-end (point-max)
                 (if (< prompt-end (point-max)) "yes" "no"))
        ;; If content was appended after the prompt, relocate prompt to end
        (when (< prompt-end (point-max))
          ;; Delete prompt from its current position
          (delete-region prompt-start prompt-end)
          ;; Insert at new point-max
          (goto-char (point-max))
          (let ((new-start (point)))
            (insert prompt-text)
            ;; Update comint markers
            (set-marker (car comint-last-prompt) new-start)
            (set-marker (cdr comint-last-prompt) (point))))))
    ;; Jump to end of prompt so user can type immediately
    (when (and comint-last-prompt
               (markerp (cdr comint-last-prompt))
               (marker-position (cdr comint-last-prompt)))
      (goto-char (cdr comint-last-prompt)))))

(defun agent-shell-team-events--submit-and-trim ()
  "Submit input via shell-maker, then trim excess blank lines.
Ensures only one newline between the user input and subsequent content."
  (interactive)
  (shell-maker-submit)
  ;; After submit, trim excess newlines between user input and point-max/prompt
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-max))
      (when (re-search-backward "[^\n]" nil t)
        (forward-char 1)
        (let ((gap (- (point-max) (point))))
          (message "submit-and-trim: point-max=%s last-content=%s gap=%s comint-last-prompt=%s"
                   (point-max) (point) gap comint-last-prompt)
          (when (> gap 1)
            (message "submit-and-trim: TRIMMING %s chars" (- gap 1))
            (delete-region (+ (point) 1) (point-max))))))))

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
               (setcdr (assq 'status agent) status)
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
  "Handle agent/spawned — create an interactive buffer and register it.
PARAMS contains agent_id, project_id (or legacy session_id), role,
worktree_path, worktree_name, model.
In server mode the backend manages the ACP subprocess.  The buffer uses
`shell-maker' for interactive input, routing to `promptAgent' WS RPC."
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
             ;; Capture agent-id for the closure
             (agent-id-copy agent-id)
             ;; Create shell-maker config with promptAgent as the execute-command
             (config (make-shell-maker-config
                      :name "agent-server"
                      :prompt "agent> "
                      :execute-command
                      (lambda (command shell)
                        ;; Store :finish-output to call when agent turn completes.
                        ;; Primary trigger: promptAgent RPC callback.
                        ;; Backup trigger: agent/statusChanged → idle.
                        (let ((shell-buf (map-elt shell :buffer)))
                          (setq-local agent-shell-team-events--pending-finish
                                      (map-elt shell :finish-output))
                          (agent-shell-team-dispatch-prompt-agent
                           agent-id-copy
                           command
                           (lambda (result error)
                             (when error
                               (message "promptAgent error for %s: %s"
                                        agent-id-copy error))
                             ;; Finish output when RPC response arrives
                             (when (and shell-buf (buffer-live-p shell-buf))
                               (with-current-buffer shell-buf
                                 (message "CALLER: promptAgent-callback -> finalize-overlays")
                                 (when (fboundp 'my/agent-shell-server--finalize-overlays)
                                   (my/agent-shell-server--finalize-overlays))
                                 ;; Add outer spacing OUTSIDE the overlay so there's
                                 ;; a visible gap between the block and the prompt.
                                 ;; Only when pending-finish exists (about to write prompt).
                                 (when agent-shell-team-events--pending-finish
                                   (let ((inhibit-read-only t))
                                     (save-excursion
                                       (goto-char (point-max))
                                       (unless (bolp) (insert "\n"))
                                       (insert "\n"))))
                                 (when agent-shell-team-events--pending-finish
                                   (funcall agent-shell-team-events--pending-finish
                                            (not error))
                                   (setq agent-shell-team-events--pending-finish
                                         nil)
                                   ;; Hide prompt until user enters insert mode
                                   (agent-shell-team-events--hide-prompt))))))))))
             (buffer (shell-maker-start config t nil nil buf-name)))
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
          ;; Bind Enter in evil insert mode to shell-maker-submit
          (evil-local-set-key 'insert (kbd "RET") #'agent-shell-team-events--submit-and-trim)
          (evil-local-set-key 'insert (kbd "<return>") #'agent-shell-team-events--submit-and-trim)
          ;; Show/hide prompt based on evil state
          (add-hook 'evil-insert-state-entry-hook
                    #'agent-shell-team-events--show-prompt nil t)
          (add-hook 'evil-normal-state-entry-hook
                    #'agent-shell-team-events--hide-prompt nil t)
          ;; Start with prompt hidden (normal mode is default)
          (agent-shell-team-events--hide-prompt)
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
      ;; Check if agent is registered yet; if not, queue for replay after spawned
      (if (not (agent-shell-team-events--find-agent-buffer agent-id))
          (agent-shell-team-events--queue-event agent-id "agent/statusChanged" params)
        ;; Update status in the agent registry alist
        (agent-shell-team-events--set-agent-status agent-id status)
        ;; When agent becomes idle, finish the shell-maker output cycle
        (when (equal status "idle")
          (let ((buffer (agent-shell-team-events--find-agent-buffer agent-id)))
            (when (and buffer (buffer-live-p buffer))
              (with-current-buffer buffer
                (message "CALLER: statusChanged-idle -> finalize-overlays")
                (when (fboundp 'my/agent-shell-server--finalize-overlays)
                  (my/agent-shell-server--finalize-overlays))
                ;; Outer spacing — only when pending-finish exists
                (when agent-shell-team-events--pending-finish
                  (let ((inhibit-read-only t))
                    (save-excursion
                      (goto-char (point-max))
                      (unless (bolp) (insert "\n"))
                      (insert "\n"))))
                (when agent-shell-team-events--pending-finish
                  (funcall agent-shell-team-events--pending-finish t)
                  (setq agent-shell-team-events--pending-finish nil)
                  ;; Hide prompt until user enters insert mode
                  (agent-shell-team-events--hide-prompt)))))))
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
  "Insert TEXT at the end of BUFFER, before the comint prompt if present.
In server-mode agent buffers the prompt should stay at the bottom so
follow-up messages don't corrupt it.  When `comint-last-prompt' exists,
text is inserted just before the prompt; otherwise at `point-max'.
Returns (START . END) of the inserted region, or nil."
  (when (and (buffer-live-p buffer) (stringp text) (> (length text) 0))
    (with-current-buffer buffer
      (let* ((inhibit-read-only t)
             ;; If a VISIBLE comint prompt exists, insert before it so the
             ;; prompt stays at the very bottom of the buffer.
             ;; When prompt is hidden (invisible overlay), insert at point-max
             ;; instead — the hidden prompt is from a previous turn.
             (prompt-pos (when (and (bound-and-true-p agent-shell-team--server-mode-p)
                                    (not agent-shell-team-events--prompt-hidden-ov)
                                    comint-last-prompt
                                    (markerp (car comint-last-prompt))
                                    (marker-position (car comint-last-prompt)))
                           (marker-position (car comint-last-prompt))))
             (insert-pos (or prompt-pos (point-max)))
             start end)
        (message "insert-at-end: prompt-pos=%s insert-pos=%s point-max=%s text-len=%s"
                 prompt-pos insert-pos (point-max) (length text))
        (save-excursion
          (goto-char insert-pos)
          (setq start (point))
          (insert text)
          (setq end (point)))
        ;; Scroll windows showing this buffer to bottom
        (dolist (win (get-buffer-window-list buffer nil t))
          (set-window-point win (point-max)))
        (cons start end)))))

(defun agent-shell-team-events--on-message-chunk (buffer update)
  "Handle agent_message_chunk — append text to agent BUFFER.
UPDATE contains content.text."
  (let* ((content (agent-shell-team-events--get-param update "content"))
         (text (and content (agent-shell-team-events--get-param content "text"))))
    ;; First chunk of a new message: trim leading \n from text AND
    ;; collapse excess blank lines above the insertion point to one
    (when (and text (buffer-live-p buffer)
               (not (buffer-local-value 'my/agent-shell-server--current-msg-ov buffer)))
      (setq text (string-trim-left text "\n+"))
      (with-current-buffer buffer
        (let* ((inhibit-read-only t)
               ;; Always trim at point-max — after submit, the blank lines
               ;; are between the user's input and the end of the buffer.
               (trim-pos (point-max)))
          (save-excursion
            (goto-char trim-pos)
            (when (re-search-backward "[^\n\r ]" nil t)
              (forward-char 1)
              (let ((gap (- trim-pos (point))))
                (message "on-message-chunk TRIM: trim-pos=%s last-content=%s gap=%s"
                         trim-pos (point) gap)
                (when (> gap 1)
                  (delete-region (+ (point) 1) trim-pos))))))))
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
  "Handle approval/cancelled — log cancellation.
PARAMS contains request_id."
  (let ((request-id (agent-shell-team-events--get-param params "request_id")))
    (message "agent-shell-team-events: approval/cancelled request_id=%s" request-id)))

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
