;;; agent-shell-team-dispatch.el --- Backend dispatch for team orchestration -*- lexical-binding: t; -*-

;; Author: Igor Rizhyi
;; Keywords: tools, ai

;;; Commentary:

;; Dispatch layer that routes team orchestration calls to either local
;; Elisp functions or the Python gang-of-none backend over WebSocket.
;;
;; Each operation has a dedicated dispatch function.  When the backend is
;; `elisp', the existing Elisp handler is called directly.  When the
;; backend is `python', the call is serialized as JSON-RPC and sent via
;; `agent-shell-team-ws-call'.

;;; Code:

(require 'cl-lib)

;;;; --- Custom variables ---

(defgroup agent-shell-team-dispatch nil
  "Backend dispatch for agent-shell team orchestration."
  :group 'agent-shell
  :prefix "agent-shell-team-")

(defcustom agent-shell-team-backend 'elisp
  "Backend for team orchestration.
`elisp' runs everything locally; `python' delegates to gang-of-none."
  :type '(choice (const :tag "Local Elisp" elisp)
                 (const :tag "Python (gang-of-none)" python))
  :group 'agent-shell-team-dispatch)

(defcustom agent-shell-team-python-url "ws://localhost:8000"
  "WebSocket base URL for the gang-of-none Python backend."
  :type 'string
  :group 'agent-shell-team-dispatch)

;;;; --- Forward declarations (Elisp path) ---

(declare-function agent-shell-team--handle-tasks-put "agent-shell-team" (raw-input))
(declare-function agent-shell-team--handle-task-update "agent-shell-team" (raw-input))
(declare-function agent-shell-team--handle-dismiss-agent "agent-shell-team" (raw-input))
(declare-function agent-shell-team--register-agent "agent-shell-team"
                  (session-id buffer role mode &optional worktree worktree-name))
(declare-function agent-shell-team--unregister-agent "agent-shell-team" (buffer))
(declare-function agent-shell-team--try-assign-tasks "agent-shell-team" ())
(declare-function agent-shell-team--handle-send-notification "agent-shell-team" (raw-input))
(declare-function agent-shell-team--handle-present-options "agent-shell-team" (raw-input))
(declare-function agent-shell-team--handle-list-pending-reviews "agent-shell-team" (raw-input))

(declare-function agent-shell-bus-send "agent-shell-bus" (target-pid type data))
(defvar agent-shell-bus--peers)

;;;; --- Forward declaration (Python/WS path) ---

(declare-function agent-shell-team-ws-call "agent-shell-team-ws"
                  (method params &optional callback))

;;;; --- Internal helpers ---

(defun agent-shell-team-dispatch--python-p ()
  "Return non-nil when the Python backend is active."
  (eq agent-shell-team-backend 'python))

(defun agent-shell-team-dispatch--ws-require ()
  "Ensure the WebSocket module is loaded."
  (require 'agent-shell-team-ws))

;;;; --- Dispatch functions ---

(defun agent-shell-team-dispatch-tasks-put (raw-input &optional callback)
  "Dispatch tasksPut.
RAW-INPUT is the MCP params alist.  Optional CALLBACK receives the result."
  (if (agent-shell-team-dispatch--python-p)
      (progn
        (agent-shell-team-dispatch--ws-require)
        (agent-shell-team-ws-call "tasksPut" raw-input callback))
    (let ((result (agent-shell-team--handle-tasks-put raw-input)))
      (when callback (funcall callback result))
      result)))

(defun agent-shell-team-dispatch-task-update (raw-input &optional callback)
  "Dispatch taskUpdate.
RAW-INPUT is the MCP params alist.  Optional CALLBACK receives the result."
  (if (agent-shell-team-dispatch--python-p)
      (progn
        (agent-shell-team-dispatch--ws-require)
        (agent-shell-team-ws-call "taskUpdate" raw-input callback))
    (let ((result (agent-shell-team--handle-task-update raw-input)))
      (when callback (funcall callback result))
      result)))

(defun agent-shell-team-dispatch-dismiss-agent (raw-input &optional callback)
  "Dispatch dismissAgent.
RAW-INPUT is the MCP params alist.  Optional CALLBACK receives the result."
  (if (agent-shell-team-dispatch--python-p)
      (progn
        (agent-shell-team-dispatch--ws-require)
        (agent-shell-team-ws-call "dismissAgent" raw-input callback))
    (let ((result (agent-shell-team--handle-dismiss-agent raw-input)))
      (when callback (funcall callback result))
      result)))

(defun agent-shell-team-dispatch-register-agent
    (session-id buffer role mode &optional worktree worktree-name callback)
  "Dispatch agent registration.
SESSION-ID, BUFFER, ROLE, MODE, WORKTREE, WORKTREE-NAME match the
elisp handler signature.  Optional CALLBACK receives the result."
  (if (agent-shell-team-dispatch--python-p)
      (progn
        (agent-shell-team-dispatch--ws-require)
        (let ((params `((session_id . ,session-id)
                        (buffer . ,(if (bufferp buffer) (buffer-name buffer) buffer))
                        (role . ,role)
                        (mode . ,mode)
                        ,@(when worktree `((worktree . ,worktree)))
                        ,@(when worktree-name `((worktree_name . ,worktree-name))))))
          (agent-shell-team-ws-call "agent/create" params callback)))
    (let ((result (agent-shell-team--register-agent
                   session-id buffer role mode worktree worktree-name)))
      (when callback (funcall callback result))
      result)))

(defun agent-shell-team-dispatch-unregister-agent (buffer &optional callback)
  "Dispatch agent unregistration.
BUFFER is the agent shell buffer.  Optional CALLBACK receives the result.
In Python mode this is handled by dismissAgent, so we send that instead."
  (if (agent-shell-team-dispatch--python-p)
      (progn
        (agent-shell-team-dispatch--ws-require)
        (let ((params `((target . ,(if (bufferp buffer)
                                       (buffer-name buffer)
                                     buffer)))))
          (agent-shell-team-ws-call "dismissAgent" params callback)))
    (let ((result (agent-shell-team--unregister-agent buffer)))
      (when callback (funcall callback result))
      result)))

(defun agent-shell-team-dispatch-try-assign-tasks (&optional callback)
  "Dispatch task assignment.
Optional CALLBACK receives the result."
  (if (agent-shell-team-dispatch--python-p)
      (progn
        (agent-shell-team-dispatch--ws-require)
        (agent-shell-team-ws-call "orchestrator/assignTasks" nil callback))
    (let ((result (agent-shell-team--try-assign-tasks)))
      (when callback (funcall callback result))
      result)))

(defun agent-shell-team-dispatch-send-notification (raw-input &optional callback)
  "Dispatch sendNotification.
RAW-INPUT is the MCP params alist.  Optional CALLBACK receives the result."
  (if (agent-shell-team-dispatch--python-p)
      (progn
        (agent-shell-team-dispatch--ws-require)
        (agent-shell-team-ws-call "sendNotification" raw-input callback))
    (let ((result (agent-shell-team--handle-send-notification raw-input)))
      (when callback (funcall callback result))
      result)))

(defun agent-shell-team-dispatch-present-options (raw-input &optional callback)
  "Dispatch presentOptions.
RAW-INPUT is the MCP params alist.  Optional CALLBACK receives the result."
  (if (agent-shell-team-dispatch--python-p)
      (progn
        (agent-shell-team-dispatch--ws-require)
        (agent-shell-team-ws-call "presentOptions" raw-input callback))
    (let ((result (agent-shell-team--handle-present-options raw-input)))
      (when callback (funcall callback result))
      result)))

(defun agent-shell-team-dispatch-list-pending-reviews (raw-input &optional callback)
  "Dispatch listPendingReviews.
RAW-INPUT is the MCP params alist.  Optional CALLBACK receives the result."
  (if (agent-shell-team-dispatch--python-p)
      (progn
        (agent-shell-team-dispatch--ws-require)
        (agent-shell-team-ws-call "listPendingReviews" raw-input callback))
    (let ((result (agent-shell-team--handle-list-pending-reviews raw-input)))
      (when callback (funcall callback result))
      result)))

(defun agent-shell-team-dispatch-message-peer (target-pid message &optional callback)
  "Dispatch messageNamespacePeer.
TARGET-PID is the integer PID of the target Emacs instance.
MESSAGE is the string content to send."
  (if (agent-shell-team-dispatch--python-p)
      (progn
        (agent-shell-team-dispatch--ws-require)
        (let ((params `((target_pid . ,target-pid)
                        (message . ,message))))
          (agent-shell-team-ws-call "messageNamespacePeer" params callback)))
    (let ((result (agent-shell-bus-send target-pid 'lead-message
                                        (list :message message))))
      (when callback (funcall callback result))
      result)))

(defun agent-shell-team-dispatch-list-peers (&optional callback)
  "Dispatch listNamespacePeers.
Returns a list of peer plists.  Optional CALLBACK receives the result."
  (if (agent-shell-team-dispatch--python-p)
      (progn
        (agent-shell-team-dispatch--ws-require)
        (agent-shell-team-ws-call "listNamespacePeers" nil callback))
    (let ((peers nil))
      (maphash (lambda (_pid info) (push info peers))
               agent-shell-bus--peers)
      (let ((result (nreverse peers)))
        (when callback (funcall callback result))
        result))))

(provide 'agent-shell-team-dispatch)
;;; agent-shell-team-dispatch.el ends here
