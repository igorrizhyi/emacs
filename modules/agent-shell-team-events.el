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

;; Variables from agent-shell-team we reference
(defvar agent-shell-team--session-id)
(defvar agent-shell-team--agent-id)
(defvar agent-shell-team--init-finished-p)
(defvar agent-shell-team--model-id)
(defvar agent-shell-team--request-to-session)
(defvar agent-shell-team--task-groups)
(defvar agent-shell-team--sessions)

;;; Buffer-local variables for streaming agent output

(defvar-local agent-shell-team-events--tool-calls (make-hash-table :test 'equal)
  "Hash-table mapping toolCallId -> marker for in-progress tool call sections.")

(defvar-local agent-shell-team-events--usage nil
  "Plist of latest usage data from the agent session, for modeline display.")

(defvar-local agent-shell-team-events--pending-finish nil
  "Closure to call when the agent turn completes (shell-maker :finish-output).")

;;; Hook point — the WS module sets this to our dispatcher

(defvar agent-shell-team-ws-notification-handler nil
  "Function called by the WS module for every incoming server notification.
Set to `agent-shell-team-events--handle-notification' on module load.")

;;; Internal helpers

(defun agent-shell-team-events--get-param (params key)
  "Extract KEY from PARAMS, trying keyword, symbol, and string forms."
  (or (plist-get params (intern (concat ":" key)))
      (map-elt params (intern key))
      (map-elt params key)))

(defun agent-shell-team-events--find-agent-buffer (agent-id)
  "Find the Emacs buffer for AGENT-ID by matching worktree-name across all sessions.
Returns the buffer or nil if not found."
  (when (and agent-id (boundp 'agent-shell-team--sessions))
    (catch 'found
      (maphash
       (lambda (_session-id agents)
         (dolist (agent agents)
           (let ((buf (alist-get 'buffer agent))
                 (wt-name (alist-get 'worktree-name agent)))
             (when (and (buffer-live-p buf)
                        wt-name
                        (string= wt-name agent-id))
               (throw 'found buf)))))
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
PARAMS contains agent_id, session_id, role, worktree_path, worktree_name, model.
In server mode the backend manages the ACP subprocess.  The buffer uses
`shell-maker' for interactive input, routing to `promptAgent' WS RPC."
  (let ((session-id (agent-shell-team-events--get-param params "session_id"))
        (role (agent-shell-team-events--get-param params "role"))
        (worktree-path (agent-shell-team-events--get-param params "worktree_path"))
        (worktree-name (agent-shell-team-events--get-param params "worktree_name"))
        (model (agent-shell-team-events--get-param params "model"))
        (agent-id (agent-shell-team-events--get-param params "agent_id")))
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
                                 (when agent-shell-team-events--pending-finish
                                   (funcall agent-shell-team-events--pending-finish
                                            (not error))
                                   (setq agent-shell-team-events--pending-finish
                                         nil))))))))))
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
          (evil-local-set-key 'insert (kbd "RET") #'shell-maker-submit)
          (evil-local-set-key 'insert (kbd "<return>") #'shell-maker-submit))
        ;; Store agent-id in the roster alist entry for lookup by dismissed handler
        (let* ((agents (agent-shell-team--get-session-agents session-id))
               (entry (cl-find buffer agents
                               :key (lambda (a) (alist-get 'buffer a)))))
          (when entry
            (push (cons 'agent-id agent-id) (cdr entry))))
        ;; Refresh sidebar if visible
        (when-let ((sidebar-buf (get-buffer " *team-sidebar*")))
          (when (get-buffer-window sidebar-buf)
            (my/team-sidebar--render)))))))

(defun agent-shell-team-events--on-agent-dismissed (params)
  "Handle agent/dismissed — delegate to `agent-shell-team--unregister-agent'.
PARAMS contains agent_id, session_id.
The current codebase identifies agents by buffer, not agent_id.
We match by looking for a buffer whose worktree-name or buffer-name
contains the agent_id."
  (let ((agent-id (agent-shell-team-events--get-param params "agent_id"))
        (session-id (agent-shell-team-events--get-param params "session_id")))
    (when (and agent-id session-id)
      ;; Find the buffer associated with this agent-id.
      ;; Since agent-id is a new backend concept, try matching by
      ;; worktree-name (the backend uses worktree names as agent IDs).
      (let ((agent-buf
             (cl-loop for agent in (agent-shell-team--get-session-agents session-id)
                      for buf = (alist-get 'buffer agent)
                      for wt-name = (alist-get 'worktree-name agent)
                      when (and (buffer-live-p buf)
                                wt-name
                                (string= wt-name agent-id))
                      return buf)))
        (if agent-buf
            (agent-shell-team--unregister-agent agent-buf)
          (message "agent-shell-team-events: agent/dismissed — no buffer found for agent-id=%s"
                   agent-id))))))

(defun agent-shell-team-events--on-agent-status-changed (params)
  "Handle agent/statusChanged — update sidebar and modeline.
PARAMS contains agent_id, status, session_id, current_task_id."
  (let ((agent-id (agent-shell-team-events--get-param params "agent_id"))
        (status (agent-shell-team-events--get-param params "status"))
        (session-id (agent-shell-team-events--get-param params "session_id")))
    (when agent-id
      (message "agent-shell-team-events: agent/statusChanged id=%s status=%s"
               agent-id status)
      ;; When agent becomes idle, finish the shell-maker output cycle
      ;; so a new prompt appears.
      (when (equal status "idle")
        (let ((buffer (agent-shell-team-events--find-agent-buffer agent-id)))
          (when (and buffer (buffer-live-p buffer))
            (with-current-buffer buffer
              (when agent-shell-team-events--pending-finish
                (funcall agent-shell-team-events--pending-finish t)
                (setq agent-shell-team-events--pending-finish nil))))))
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
                         (let ((id (or (map-elt item 'id)
                                       (map-elt item "id")))
                               (label (or (map-elt item 'label)
                                          (map-elt item "label")))
                               (desc (or (map-elt item 'description)
                                         (map-elt item "description") ""))
                               (default-sel (or (map-elt item 'default_selected)
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
  "Insert TEXT at the end of BUFFER, preserving point for non-visible windows."
  (when (and (buffer-live-p buffer) (stringp text) (> (length text) 0))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert text))
        ;; Scroll windows showing this buffer to bottom
        (dolist (win (get-buffer-window-list buffer nil t))
          (set-window-point win (point-max)))))))

(defun agent-shell-team-events--on-message-chunk (buffer update)
  "Handle agent_message_chunk — append text to agent BUFFER.
UPDATE contains content.text."
  (let* ((content (agent-shell-team-events--get-param update "content"))
         (text (and content (agent-shell-team-events--get-param content "text"))))
    (agent-shell-team-events--insert-at-end buffer text)))

(defun agent-shell-team-events--on-thought-chunk (buffer update)
  "Handle agent_thought_chunk — append thinking text to agent BUFFER.
UPDATE contains content.text.  Rendered with a dimmed face."
  (let* ((content (agent-shell-team-events--get-param update "content"))
         (text (and content (agent-shell-team-events--get-param content "text"))))
    (when (and (stringp text) (> (length text) 0))
      (agent-shell-team-events--insert-at-end
       buffer (propertize text 'face 'shadow)))))

(defun agent-shell-team-events--on-tool-call (buffer update)
  "Handle tool_call — insert tool call header in BUFFER.
UPDATE contains toolCallId, title, status, kind."
  (let ((tool-id (agent-shell-team-events--get-param update "toolCallId"))
        (title (or (agent-shell-team-events--get-param update "title") "Tool"))
        (status (or (agent-shell-team-events--get-param update "status") "running")))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (let ((marker (point-marker)))
              (insert (propertize (format "\n[%s] %s\n" title status)
                                  'face 'font-lock-function-name-face))
              ;; Track the marker for later updates
              (when tool-id
                (unless (hash-table-p agent-shell-team-events--tool-calls)
                  (setq agent-shell-team-events--tool-calls
                        (make-hash-table :test 'equal)))
                (puthash tool-id marker
                         agent-shell-team-events--tool-calls)))))))))

(defun agent-shell-team-events--on-tool-call-update (buffer update)
  "Handle tool_call_update — update existing tool call section in BUFFER.
UPDATE contains toolCallId, status, content, title."
  (let ((tool-id (agent-shell-team-events--get-param update "toolCallId"))
        (status (agent-shell-team-events--get-param update "status"))
        (content (agent-shell-team-events--get-param update "content"))
        (title (agent-shell-team-events--get-param update "title")))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (marker (and tool-id
                           (hash-table-p agent-shell-team-events--tool-calls)
                           (gethash tool-id agent-shell-team-events--tool-calls))))
          ;; If we have a tracked marker, update the header line
          (when (and marker (marker-position marker))
            (save-excursion
              (goto-char marker)
              (when (looking-at "\\[.*\\].*$")
                (replace-match
                 (propertize (format "[%s] %s"
                                     (or title "Tool")
                                     (or status "done"))
                             'face 'font-lock-function-name-face)))))
          ;; Append content at buffer end
          (when (and (stringp content) (> (length content) 0))
            (agent-shell-team-events--insert-at-end
             buffer (propertize content 'face 'font-lock-comment-face)))
          ;; Clean up completed tool calls
          (when (and tool-id (member status '("done" "error")))
            (when (hash-table-p agent-shell-team-events--tool-calls)
              (remhash tool-id agent-shell-team-events--tool-calls))))))))

(defun agent-shell-team-events--on-plan (buffer update)
  "Handle plan — render plan entries in BUFFER.
UPDATE contains entries array."
  (let ((entries (agent-shell-team-events--get-param update "entries")))
    (when (and entries (> (length entries) 0))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (insert (propertize "\n--- Plan ---\n" 'face 'font-lock-keyword-face))
            (seq-do
             (lambda (entry)
               (let ((content (or (agent-shell-team-events--get-param entry "content")
                                  (format "%s" entry))))
                 (insert (format "  - %s\n" content))))
             entries)))))))

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
  (let* ((agent-id (agent-shell-team-events--get-param params "agent_id"))
         (update (agent-shell-team-events--get-param params "update"))
         (update-type (and update
                           (agent-shell-team-events--get-param update "sessionUpdate")))
         (buffer (agent-shell-team-events--find-agent-buffer agent-id)))
    (if (not buffer)
        (message "agent-shell-team-events: agent/session/update — no buffer for agent-id=%s type=%s"
                 agent-id update-type)
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
             (setq-local agent-shell-team--new-message-pending t))))
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
  (let ((agent-id (agent-shell-team-events--get-param params "agent_id"))
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
  (let* ((agent-id (agent-shell-team-events--get-param params "agent_id"))
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
    (_
     (message "agent-shell-team-events: unknown method %S" method))))

;;; Wiring — set the hook point on load

(setq agent-shell-team-ws-notification-handler
      #'agent-shell-team-events--handle-notification)

(provide 'agent-shell-team-events)

;;; agent-shell-team-events.el ends here
