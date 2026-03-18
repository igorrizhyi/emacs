;;; agent-shell-namespace.el --- Namespace integration for agent-shell-team -*- lexical-binding: t; -*-

;; Author: Igor Rizhyi
;; Keywords: tools, ai, ipc

;;; Commentary:

;; Glue layer between the cross-instance event bus (agent-shell-bus.el),
;; the team module (agent-shell-team.el), and the sidebar.
;;
;; Reads namespace config from .agent-shell/namespace.json, starts the
;; event bus, emits agent lifecycle events, and handles incoming events
;; from namespace peers to populate the sidebar's foreign agents section.

;;; Code:

(require 'json)
(require 'agent-shell-bus)

(defvar agent-shell-team--session-id)
(defvar agent-shell-team--pending-for-lead)
(defvar my/team-sidebar--foreign-agents)
(defvar my/team-sidebar--namespace-active)

(declare-function agent-shell-team--get-lead "agent-shell-team")
(declare-function agent-shell-team--agent-status "agent-shell-team")
(declare-function agent-shell-team--prompt-agent "agent-shell-team")
(declare-function my/team-sidebar-refresh "my-agent-shell-sidebar")

;;; --- State ---

(defvar agent-shell-namespace--config nil
  "Parsed namespace config plist from namespace.json, or nil.")

(defvar agent-shell-namespace--project-root nil
  "Project root directory where .agent-shell/namespace.json was found.")

(defvar agent-shell-namespace--peer-projects (make-hash-table :test 'equal)
  "Hash-table mapping peer PID (number) to project root path string.")

;;; --- Config reading ---

(defun agent-shell-namespace--read-config ()
  "Read .agent-shell/namespace.json from the project root.
Return a plist with :namespace and :description, or nil."
  (let ((root (locate-dominating-file default-directory ".agent-shell")))
    (when root
      (let ((file (expand-file-name ".agent-shell/namespace.json" root)))
        (when (file-exists-p file)
          (condition-case err
              (let* ((json-object-type 'plist)
                     (json-key-type 'keyword)
                     (config (json-read-file file)))
                (when (plist-get config :namespace)
                  (setq agent-shell-namespace--project-root root)
                  config))
            (error
             (message "agent-shell-namespace: failed to read config: %s"
                      (error-message-string err))
             nil)))))))

;;; --- Event handlers ---

(defun agent-shell-namespace--on-agent-spawn (data _sender-pid)
  "Handle agent-spawn event from a peer.
DATA is a plist with :role, :worktree-name, :hostname, :pid."
  (let* ((peer-pid (plist-get data :pid))
         (agent `((role . ,(plist-get data :role))
                  (worktree-name . ,(or (plist-get data :worktree-name) "unknown"))
                  (status . busy)
                  (hostname . ,(or (plist-get data :hostname) "unknown"))))
         (existing (assoc peer-pid my/team-sidebar--foreign-agents)))
    (if existing
        (setcdr existing (cons agent (cdr existing)))
      (push (cons peer-pid (list agent)) my/team-sidebar--foreign-agents))
    (agent-shell-namespace--maybe-refresh-sidebar)))

(defun agent-shell-namespace--on-agent-status-change (data _sender-pid)
  "Handle agent-status-change event from a peer.
DATA is a plist with :pid, :worktree-name, :old-status, :new-status."
  (let* ((peer-pid (plist-get data :pid))
         (wt-name (plist-get data :worktree-name))
         (new-status (plist-get data :new-status))
         (peer-entry (assoc peer-pid my/team-sidebar--foreign-agents)))
    (when peer-entry
      (dolist (agent (cdr peer-entry))
        (when (equal (alist-get 'worktree-name agent) wt-name)
          (setf (alist-get 'status agent) (intern new-status))))
      (agent-shell-namespace--maybe-refresh-sidebar))))

(defun agent-shell-namespace--on-agent-dismiss (data _sender-pid)
  "Handle agent-dismiss event from a peer.
DATA is a plist with :pid, :worktree-name."
  (let* ((peer-pid (plist-get data :pid))
         (wt-name (plist-get data :worktree-name))
         (peer-entry (assoc peer-pid my/team-sidebar--foreign-agents)))
    (when peer-entry
      (setcdr peer-entry
              (cl-remove-if
               (lambda (agent)
                 (equal (alist-get 'worktree-name agent) wt-name))
               (cdr peer-entry)))
      ;; Remove peer entry entirely if no agents left
      (unless (cdr peer-entry)
        (setq my/team-sidebar--foreign-agents
              (assq-delete-all peer-pid my/team-sidebar--foreign-agents)))
      (agent-shell-namespace--maybe-refresh-sidebar))))

(defun agent-shell-namespace--on-peer-join (data sender-pid)
  "Handle peer-join event.
DATA is the peer's presence info plist."
  (when-let ((project (plist-get data :project_root)))
    (puthash sender-pid project agent-shell-namespace--peer-projects))
  (message "agent-shell-namespace: peer joined (pid=%s, host=%s)"
           sender-pid (or (plist-get data :hostname) "?")))

(defun agent-shell-namespace--on-peer-leave (_data sender-pid)
  "Handle peer-leave event.  Remove all foreign agents for that peer."
  (setq my/team-sidebar--foreign-agents
        (assq-delete-all sender-pid my/team-sidebar--foreign-agents))
  (remhash sender-pid agent-shell-namespace--peer-projects)
  (message "agent-shell-namespace: peer left (pid=%s)" sender-pid)
  (agent-shell-namespace--maybe-refresh-sidebar))

(defun agent-shell-namespace--on-lead-message (data _sender-pid)
  "Handle lead-message event (targeted message from a peer).
Push to the lead's pending queue or prompt directly if idle."
  (let* ((message-text (plist-get data :message))
         (sender-session (or (plist-get data :sender-session) "unknown"))
         (formatted (format "[Namespace peer %s]: %s" sender-session message-text))
         (session-id agent-shell-team--session-id)
         (lead-buf (when session-id
                     (agent-shell-team--get-lead session-id))))
    (if lead-buf
        (let ((status (agent-shell-team--agent-status lead-buf)))
          (pcase status
            ('idle (agent-shell-team--prompt-agent lead-buf formatted))
            (_
             ;; Queue for later delivery
             (let ((existing (gethash session-id agent-shell-team--pending-for-lead)))
               (puthash session-id (append existing (list formatted))
                        agent-shell-team--pending-for-lead)))))
      (message "agent-shell-namespace: lead-message received but no lead registered: %s"
               message-text))))

;;; --- Sidebar helper ---

(defun agent-shell-namespace--maybe-refresh-sidebar ()
  "Refresh the team sidebar if the function is available."
  (when (fboundp 'my/team-sidebar-refresh)
    (my/team-sidebar-refresh)))

;;; --- Public API ---

(defun agent-shell-namespace-init ()
  "Initialize namespace integration.
Read config, start bus if namespace exists, register event handlers,
set sidebar vars.  Called from `agent-shell-team' init."
  (let ((config (agent-shell-namespace--read-config)))
    (when config
      (setq agent-shell-namespace--config config)
      (let ((ns (plist-get config :namespace)))
        ;; Start the event bus
        (agent-shell-bus-start ns)
        ;; Register event handlers
        (agent-shell-bus-on 'agent-spawn
                            #'agent-shell-namespace--on-agent-spawn)
        (agent-shell-bus-on 'agent-status-change
                            #'agent-shell-namespace--on-agent-status-change)
        (agent-shell-bus-on 'agent-dismiss
                            #'agent-shell-namespace--on-agent-dismiss)
        (agent-shell-bus-on 'peer-join
                            #'agent-shell-namespace--on-peer-join)
        (agent-shell-bus-on 'peer-leave
                            #'agent-shell-namespace--on-peer-leave)
        (agent-shell-bus-on 'lead-message
                            #'agent-shell-namespace--on-lead-message)
        ;; Set sidebar state
        (setq my/team-sidebar--namespace-active t)
        (setq my/team-sidebar--foreign-agents nil)
        ;; Populate project roots for peers already present at startup
        (when (boundp 'agent-shell-bus--peers)
          (maphash (lambda (pid info)
                     (when-let ((project (plist-get info :project_root)))
                       (puthash pid project agent-shell-namespace--peer-projects)))
                   agent-shell-bus--peers))
        (message "agent-shell-namespace: initialized for namespace '%s'" ns)))))

(defun agent-shell-namespace-teardown ()
  "Stop namespace integration.  Stop bus, clean up state."
  (when agent-shell-namespace--config
    (agent-shell-bus-stop)
    (setq agent-shell-namespace--config nil)
    (setq agent-shell-namespace--project-root nil)
    (clrhash agent-shell-namespace--peer-projects)
    (setq my/team-sidebar--namespace-active nil)
    (setq my/team-sidebar--foreign-agents nil)
    (agent-shell-namespace--maybe-refresh-sidebar)
    (message "agent-shell-namespace: torn down")))

(defun agent-shell-namespace-active-p ()
  "Return non-nil if namespace is active."
  (and agent-shell-namespace--config t))

(defun agent-shell-namespace-emit-spawn (role worktree-name)
  "Emit agent-spawn event for ROLE at WORKTREE-NAME."
  (when (agent-shell-namespace-active-p)
    (agent-shell-bus-emit 'agent-spawn
                          (list :role role
                                :worktree-name worktree-name
                                :hostname (system-name)
                                :pid (emacs-pid)))))

(defun agent-shell-namespace-emit-status (worktree-name old-status new-status)
  "Emit agent-status-change for WORKTREE-NAME from OLD-STATUS to NEW-STATUS."
  (when (agent-shell-namespace-active-p)
    (agent-shell-bus-emit 'agent-status-change
                          (list :pid (emacs-pid)
                                :worktree-name worktree-name
                                :old-status (if (symbolp old-status)
                                                (symbol-name old-status)
                                              old-status)
                                :new-status (if (symbolp new-status)
                                                (symbol-name new-status)
                                              new-status)))))

(defun agent-shell-namespace-emit-dismiss (worktree-name)
  "Emit agent-dismiss event for WORKTREE-NAME."
  (when (agent-shell-namespace-active-p)
    (agent-shell-bus-emit 'agent-dismiss
                          (list :pid (emacs-pid)
                                :worktree-name worktree-name))))

;;; --- MCP handler ---

(defun claude-code-mcp-handle-messageNamespacePeer (params)
  "Handle messageNamespacePeer MCP tool call.
PARAMS should include `target_pid' (number) and `message' (string).
Sends a targeted lead-message to the specified peer via the event bus."
  (let ((target-pid (cdr (assoc 'target_pid params)))
        (message-text (cdr (assoc 'message params))))
    (unless target-pid (error "target_pid is required"))
    (unless message-text (error "message is required"))
    (unless (agent-shell-namespace-active-p)
      (error "No active namespace — cannot send cross-instance messages"))
    (condition-case err
        (progn
          (agent-shell-bus-send
           (if (numberp target-pid) target-pid (string-to-number (format "%s" target-pid)))
           'lead-message
           (list :message message-text
                 :sender-session (or agent-shell-team--session-id "unknown")))
          `((success . t)
            (message . "Sent")))
      (error
       `((success . nil)
         (message . ,(format "Failed to send: %s" (error-message-string err))))))))

(provide 'agent-shell-namespace)
;;; agent-shell-namespace.el ends here
