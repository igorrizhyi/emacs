;;; my-agent-shell-session-recovery.el --- Auto-recover from "Session not found" errors -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; The `claude-agent-acp' binary can return a JSON-RPC error with
;; "Session not found" when its internal session store loses track of
;; a session ID.  This module intercepts that error and automatically
;; creates a fresh session, preventing the agent from becoming
;; permanently unresponsive.
;;
;; The fix is implemented as :around advice on `acp--route-incoming-message'
;; so it catches the error before any on-failure callback runs.

;;; Code:

(message "agent-shell-team: session-recovery loading...")

(defvar-local my/session-recovery--attempt-count 0
  "Number of recovery attempts in this buffer.  Guards against infinite loops.")

(defvar-local my/session-recovery--max-attempts 2
  "Maximum recovery attempts before giving up.")

(after! agent-shell
  (defun my/session-recovery--session-not-found-p (message-object)
    "Return non-nil if MESSAGE-OBJECT is an error response with \"Session not found\"."
    (when-let* ((err (alist-get 'error message-object))
                (msg (alist-get 'message err)))
      (and (alist-get 'id message-object)
           (stringp msg)
           (string-match-p "Session not found" msg))))

  (defun my/session-recovery--recover (client shell-buffer)
    "Create a fresh session for CLIENT in SHELL-BUFFER."
    (when (buffer-live-p shell-buffer)
      (with-current-buffer shell-buffer
        (cl-incf my/session-recovery--attempt-count)
        (if (> my/session-recovery--attempt-count my/session-recovery--max-attempts)
            (progn
              (message "[session-recovery] Max attempts (%d) exceeded, giving up"
                       my/session-recovery--max-attempts)
              (shell-maker-finish-output :config shell-maker--config :success nil))
          (message "[session-recovery] Session not found detected, attempting recovery (attempt %d/%d)..."
                   my/session-recovery--attempt-count my/session-recovery--max-attempts)
          (agent-shell--initiate-new-session
           :shell-buffer shell-buffer
           :on-session-init
           (lambda ()
             (with-current-buffer shell-buffer
               (setq my/session-recovery--attempt-count 0)
               (message "[session-recovery] New session created (%s). You may retry your last command."
                        (map-nested-elt agent-shell--state '(:session :id)))
               ;; Finish any pending output so the shell is usable again
               (agent-shell-heartbeat-stop
                :heartbeat (map-elt agent-shell--state :heartbeat))
               (shell-maker-finish-output :config shell-maker--config :success nil))))))))

  (defun my/session-recovery--route-advice (orig-fn &rest args)
    "Around advice for `acp--route-incoming-message'.
Intercepts error responses containing \"Session not found\" and triggers
automatic session recovery instead of passing to the on-failure callback."
    (let* ((message-plist (plist-get args :message))
           (client (plist-get args :client))
           (obj (map-elt message-plist :object)))
      (if (my/session-recovery--session-not-found-p obj)
          ;; Intercept: clean up the pending request and recover
          (let* ((id (alist-get 'id obj))
                 (incoming-response
                  (and id (funcall (map-elt client :request-resolver)
                                   :client client :id id))))
            ;; Remove from pending requests (same as original code does)
            (map-put! client :pending-requests
                      (map-delete (map-elt client :pending-requests) id))
            ;; Determine the shell buffer from the pending request or client context
            (let ((shell-buffer (or (and incoming-response
                                         (map-elt incoming-response :buffer))
                                    (map-elt client :context-buffer))))
              (my/session-recovery--recover client shell-buffer))
            t)
        ;; Not a session-not-found error: pass through to original
        (apply orig-fn args))))

  (advice-add 'acp--route-incoming-message :around #'my/session-recovery--route-advice)
  (message "agent-shell-team: session-recovery advice installed"))

(defun my/agent-shell-session-recovery-remove ()
  "Remove all session-recovery advice."
  (interactive)
  (advice-remove 'acp--route-incoming-message #'my/session-recovery--route-advice)
  (message "agent-shell-team: session-recovery advice removed"))

(message "agent-shell-team: session-recovery loaded")

(provide 'my-agent-shell-session-recovery)
;;; my-agent-shell-session-recovery.el ends here
