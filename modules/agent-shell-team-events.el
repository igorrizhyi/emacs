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
(declare-function my/team-sidebar--render "my-agent-shell-sidebar")
(declare-function my/approval--receive-request "my-approval-ui"
                  (request))

;; Variables from agent-shell-team we reference
(defvar agent-shell-team--session-id)
(defvar agent-shell-team--request-to-session)
(defvar agent-shell-team--task-groups)

;;; Hook point — the WS module sets this to our dispatcher

(defvar agent-shell-team-ws-notification-handler nil
  "Function called by the WS module for every incoming server notification.
Set to `agent-shell-team-events--handle-notification' on module load.")

;;; Internal helpers

(defun agent-shell-team-events--get-param (params key)
  "Extract KEY from PARAMS, trying both symbol and string forms."
  (or (map-elt params (intern key))
      (map-elt params key)))

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

(defun agent-shell-team-events--on-agent-spawned (params)
  "Handle agent/spawned — delegate to `agent-shell-team--register-agent'.
PARAMS contains agent_id, session_id, role, worktree_path, model.
Creates a placeholder registration; the actual buffer is set up separately."
  (let ((session-id (agent-shell-team-events--get-param params "session_id"))
        (role (agent-shell-team-events--get-param params "role"))
        (worktree-path (agent-shell-team-events--get-param params "worktree_path"))
        (model (agent-shell-team-events--get-param params "model"))
        (agent-id (agent-shell-team-events--get-param params "agent_id")))
    (when (and session-id role)
      ;; The register-agent function expects a buffer, but the WS event
      ;; arrives before the buffer exists.  Log for now; the actual
      ;; registration happens when the agent shell buffer is created.
      (message "agent-shell-team-events: agent/spawned id=%s role=%s model=%s worktree=%s"
               agent-id role (or model "default") (or worktree-path "none")))))

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
    ("notification"
     (agent-shell-team-events--on-notification params))
    ("approval/request"
     (agent-shell-team-events--on-approval-request params))
    (_
     (message "agent-shell-team-events: unknown method %S" method))))

;;; Wiring — set the hook point on load

(setq agent-shell-team-ws-notification-handler
      #'agent-shell-team-events--handle-notification)

(provide 'agent-shell-team-events)

;;; agent-shell-team-events.el ends here
