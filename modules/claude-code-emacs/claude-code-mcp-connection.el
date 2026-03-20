;;; claude-code-mcp-connection.el --- MCP WebSocket connection management -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: DESKTOP2 <yuya373@DESKTOP2>
;; Keywords: tools, convenience
;; Version: 0.1.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This module handles MCP WebSocket connection management including:
;; - Per-project, per-port connection tracking (multiple MCP servers per project)
;; - Port discovery and registration
;; - Connection retry logic with exponential backoff
;; - WebSocket lifecycle management
;; - Health monitoring via ping/pong heartbeat
;; - Automatic reconnection on connection loss
;;
;; Connection keys use the format "{instance-id}:{project-root}:{port}" so that
;; each MCP server (lead + agents) gets its own connection slot.  This prevents
;; agent MCP servers from clobbering the lead's connection when they register
;; for the same project root.

;;; Code:

(require 'websocket nil t)
(require 'projectile)
(require 'json)
(require 'cl-lib)
(require 'claude-code-core)

;; Declare websocket functions to avoid eager macro-expansion failures
(declare-function websocket-open "websocket" (url &rest args))
(declare-function websocket-send-text "websocket" (websocket text))
(declare-function websocket-close "websocket" (websocket))
(declare-function websocket-openp "websocket" (websocket))

;; Forward declarations
(declare-function claude-code-mcp-on-message "claude-code-mcp-protocol" (_websocket frame project-root conn-key))
(declare-function claude-code-mcp-on-error "claude-code-mcp-protocol" (_websocket type error &optional _project-root))
(declare-function claude-code-mcp-on-close "claude-code-mcp-protocol" (_websocket conn-key))

;;; Customization

(defgroup claude-code-mcp nil
  "MCP server integration for Claude Code Emacs."
  :group 'claude-code
  :prefix "claude-code-mcp-")

(defcustom claude-code-mcp-host "localhost"
  "Host for MCP server."
  :type 'string
  :group 'claude-code-mcp)

(defcustom claude-code-mcp-max-connection-attempts 10
  "Maximum number of connection attempts."
  :type 'integer
  :group 'claude-code-mcp)

(defcustom claude-code-mcp-connection-retry-delay 5
  "Delay in seconds between connection attempts."
  :type 'number
  :group 'claude-code-mcp)

(defcustom claude-code-mcp-ping-interval 30
  "Interval in seconds between WebSocket ping messages."
  :type 'integer
  :group 'claude-code-mcp)

(defcustom claude-code-mcp-ping-timeout 10
  "Timeout in seconds to wait for pong response."
  :type 'integer
  :group 'claude-code-mcp)

;;; Variables

(defvar claude-code-mcp-server-started nil
  "Flag to track if instance-specific Emacs server has been started.")

(defvar claude-code-mcp-project-connections (make-hash-table :test 'equal)
  "Hash table mapping connection keys to connection info.
Key format: \"{instance-id}:{project-root}:{port}\"
Each value is an alist with keys:
  - project-root: The normalized project root path
  - websocket: The WebSocket connection
  - port: The MCP server port (for reconnection)
  - request-id: Counter for JSON-RPC request IDs
  - pending-requests: Hash table of pending requests
  - connection-attempts: Number of connection attempts
  - ping-timer: Timer for periodic ping messages
  - ping-timeout-timer: Timer for ping timeout detection
  - last-pong-time: Time of last received pong
  - reconnect-timer: Timer for pending reconnection attempt")

;;; Key Management

(defun claude-code-mcp-make-connection-key (project-root port)
  "Create connection key for PROJECT-ROOT and PORT.
Returns key in format: \"{instance-id}:{project-root}:{port}\"."
  (format "%d:%s:%d" (emacs-pid) project-root port))

(defun claude-code-mcp-make-project-prefix (project-root)
  "Create prefix for matching all connections of PROJECT-ROOT.
Returns \"{instance-id}:{project-root}:\" for use with `string-prefix-p'."
  (format "%d:%s:" (emacs-pid) project-root))

(defun claude-code-mcp-get-all-project-connections (project-root)
  "Get all connection infos for PROJECT-ROOT in current instance.
Returns list of (conn-key . info) pairs."
  (let ((prefix (claude-code-mcp-make-project-prefix project-root))
        (results '()))
    (maphash (lambda (key value)
               (when (string-prefix-p prefix key)
                 (push (cons key value) results)))
             claude-code-mcp-project-connections)
    results))

(defun claude-code-mcp-is-project-for-current-instance (project-root)
  "Check if PROJECT-ROOT has any connections in current Emacs instance."
  (let ((prefix (claude-code-mcp-make-project-prefix project-root))
        (found nil))
    (maphash (lambda (key _value)
               (when (string-prefix-p prefix key)
                 (setq found t)))
             claude-code-mcp-project-connections)
    found))

(defun claude-code-mcp-get-current-instance-projects ()
  "Get unique project roots managed by current Emacs instance.
Returns a list of (project-root . conn-info) pairs, one per unique project."
  (let ((instance-prefix (format "%d:" (emacs-pid)))
        (seen (make-hash-table :test 'equal))
        (projects '()))
    (maphash
     (lambda (key value)
       (when (string-prefix-p instance-prefix key)
         (let ((project-root (cdr (assoc 'project-root value))))
           (when (and project-root (not (gethash project-root seen)))
             (puthash project-root t seen)
             (push (cons project-root value) projects)))))
     claude-code-mcp-project-connections)
    projects))

;;; Emacs Server Management

(defun claude-code-mcp-ensure-instance-server ()
  "Ensure Emacs server is running with instance-specific name.
Server name format: 'emacs-{PID}'."
  (let* ((instance-id (emacs-pid))
         (instance-server-name (format "emacs-%d" instance-id))
         (server-running (and (boundp 'server-process) server-process)))
    (message "[PID:%d] DEBUG: claude-code-mcp-ensure-instance-server called, server-started=%s, server-process=%s"
             instance-id claude-code-mcp-server-started server-running)
    (unless claude-code-mcp-server-started
      (condition-case err
          (progn
            (message "[PID:%d] DEBUG: About to configure server for instance-specific name" instance-id)

            ;; Set server name BEFORE starting/restarting
            (setq server-name instance-server-name)  ; This sets the global server-name variable

            (if server-running
                (progn
                  (message "[PID:%d] Server already running, restarting with instance name: %s" instance-id instance-server-name)
                  ;; Stop and restart with new name
                  (server-stop t)
                  (server-start))
              (progn
                (message "[PID:%d] Starting new Emacs server: %s" instance-id instance-server-name)
                (server-start)))

            (setq claude-code-mcp-server-started t)
            (message "[PID:%d] Successfully configured Emacs server: %s" instance-id instance-server-name))
        (error
         (message "[PID:%d] Failed to configure Emacs server %s: %s"
                  instance-id instance-server-name (error-message-string err)))))))

;;; Connection info management

(defun claude-code-mcp-initialize-connection-info (conn-key project-root)
  "Initialize and return connection info for CONN-KEY.
PROJECT-ROOT is stored in the info for later retrieval by internal functions."
  ;; Ensure instance-specific server is running
  (claude-code-mcp-ensure-instance-server)
  (let ((info (list (cons 'project-root project-root)
                    (cons 'websocket nil)
                    (cons 'port nil)
                    (cons 'request-id 0)
                    (cons 'pending-requests (make-hash-table :test 'equal))
                    (cons 'connection-attempts 0)
                    (cons 'ping-timer nil)
                    (cons 'ping-timeout-timer nil)
                    (cons 'last-pong-time nil)
                    (cons 'reconnect-timer nil))))
    (puthash conn-key info claude-code-mcp-project-connections)
    info))

(defun claude-code-mcp-get-connection-info (conn-key)
  "Get connection info for CONN-KEY.
Returns nil if no connection info exists."
  (gethash conn-key claude-code-mcp-project-connections))

(defun claude-code-mcp-get-websocket (conn-key)
  "Get WebSocket for CONN-KEY."
  (when-let ((info (claude-code-mcp-get-connection-info conn-key)))
    (cdr (assoc 'websocket info))))

(defun claude-code-mcp-set-websocket (websocket conn-key)
  "Set WEBSOCKET for CONN-KEY."
  (when-let ((info (claude-code-mcp-get-connection-info conn-key)))
    (setcdr (assoc 'websocket info) websocket)))

(defun claude-code-mcp-get-any-websocket-for-project (project-root)
  "Get any live websocket for PROJECT-ROOT.
Used as fallback when no specific connection is known."
  (cl-loop for (_key . info) in (claude-code-mcp-get-all-project-connections project-root)
           for ws = (cdr (assoc 'websocket info))
           when (and ws (websocket-openp ws))
           return ws))

;;; Port Registration

(defun claude-code-mcp--resolve-main-project-root (path)
  "If PATH is inside a .claude/worktrees/ dir, return the parent project root.
Worktree agents have cwd like /project/.claude/worktrees/abc/ but should
use /project/ as their project root for MCP connection scoping."
  (let ((pos (string-match "/\\.claude/worktrees/" path)))
    (if pos
        (substring path 0 pos)
      path)))

(defun claude-code-mcp-register-port (project-root port)
  "Register PORT for PROJECT-ROOT.
Each port gets its own connection slot keyed by {pid}:{project}:{port}.
Multiple MCP servers (lead + agents) can coexist for the same project
without clobbering each other's connections."
  (let* ((resolved-root (claude-code-mcp--resolve-main-project-root project-root))
         (normalized-root (claude-code-normalize-project-root resolved-root))
         (conn-key (claude-code-mcp-make-connection-key normalized-root port)))
    ;; Cancel any pending reconnect timer for THIS specific port
    (when-let* ((info (claude-code-mcp-get-connection-info conn-key))
                (reconnect-timer (cdr (assoc 'reconnect-timer info))))
      (when (timerp reconnect-timer)
        (cancel-timer reconnect-timer)
        (message "MCP: Cancelled pending reconnect timer for %s" conn-key))
      (setcdr (assoc 'reconnect-timer info) nil))
    ;; Disconnect THIS port's old connection if it exists (re-registration of same port)
    (when (claude-code-mcp-get-connection-info conn-key)
      (message "MCP: Re-registering port %d for %s, closing old connection" port normalized-root)
      (claude-code-mcp-disconnect conn-key))
    ;; Initialize connection info for this port
    (claude-code-mcp-initialize-connection-info conn-key normalized-root)
    ;; Store port
    (let ((info (claude-code-mcp-get-connection-info conn-key)))
      (setcdr (assoc 'port info) port))
    (message "MCP server registered on port %d for project %s (conn: %s)" port normalized-root conn-key)
    ;; Delay connection to allow old WebSocket close frame to complete,
    ;; avoiding MASK errors from close/connect frame collision
    (run-at-time 0.1 nil
                 #'claude-code-mcp-try-connect-async conn-key)))

(defun claude-code-mcp-unregister-port (project-root &optional port)
  "Unregister MCP connection for PROJECT-ROOT.
If PORT is given, only disconnect that specific connection.
If PORT is nil, disconnect ALL connections for the project.
This function is called when an MCP server shuts down."
  (let* ((resolved-root (claude-code-mcp--resolve-main-project-root project-root))
         (normalized-root (claude-code-normalize-project-root resolved-root)))
    (if port
        ;; Specific port — disconnect just that connection
        (let ((conn-key (claude-code-mcp-make-connection-key normalized-root port)))
          (claude-code-mcp-disconnect conn-key))
      ;; No port — disconnect all connections for this project
      (dolist (entry (claude-code-mcp-get-all-project-connections normalized-root))
        (claude-code-mcp-disconnect (car entry))))))

;;; Connection Management

(defun claude-code-mcp-try-connect-async (conn-key)
  "Try to connect to MCP server asynchronously for CONN-KEY."
  (let* ((info (claude-code-mcp-get-connection-info conn-key))
         (attempts (when info (cdr (assoc 'connection-attempts info))))
         (project-root (when info (cdr (assoc 'project-root info)))))
    (cond
     ((null info)
      (message "MCP: Connection info gone for %s, aborting connect" conn-key))
     ((>= attempts claude-code-mcp-max-connection-attempts)
      (message "Failed to connect to MCP server after %d attempts for project %s"
               claude-code-mcp-max-connection-attempts project-root))
     (t
      (setcdr (assoc 'connection-attempts info) (1+ attempts))
      (message "Attempting to connect to MCP server (attempt %d/%d) for project %s..."
               (1+ attempts)
               claude-code-mcp-max-connection-attempts
               project-root)
      (claude-code-mcp-connect
       conn-key
       (lambda (connected)
         (unless connected
           ;; Connection failed, retry
           (run-at-time claude-code-mcp-connection-retry-delay nil
                        #'claude-code-mcp-try-connect-async conn-key))))))))

(defun claude-code-mcp-connect (conn-key &optional callback)
  "Connect to MCP server WebSocket for CONN-KEY.
Reads port and project-root from the connection info.
If CALLBACK is provided, call it with connection result."
  (let* ((info (claude-code-mcp-get-connection-info conn-key))
         (port (when info (cdr (assoc 'port info))))
         (project-root (when info (cdr (assoc 'project-root info)))))
    (if (not (and port project-root))
        (progn
          (message "MCP: Missing port or project-root for %s" conn-key)
          (when callback (funcall callback nil))
          nil)
      (condition-case err
          (progn
            (websocket-open
             (format "ws://%s:%d/?session=%s"
                     claude-code-mcp-host
                     port
                     (url-hexify-string (format "%d:%s" (emacs-pid) project-root)))
             :on-open (lambda (websocket)
                        (message "MCP WebSocket opened for project %s (port %d)" project-root port)
                        (when-let ((info (claude-code-mcp-get-connection-info conn-key)))
                          (setcdr (assoc 'connection-attempts info) 0))
                        (claude-code-mcp-set-websocket websocket conn-key)
                        ;; Start ping timer
                        (claude-code-mcp-start-ping-timer conn-key)
                        (when callback (funcall callback t)))
             :on-message (lambda (websocket frame)
                           (claude-code-mcp-on-message websocket frame project-root conn-key))
             :on-error (lambda (websocket type error)
                         (claude-code-mcp-on-error websocket type error project-root))
             :on-close (lambda (websocket)
                         (claude-code-mcp-on-close websocket conn-key)))
            (message "Initiating MCP WebSocket connection on port %d for project %s" port project-root)
            t)
        (error
         (message "Failed to open WebSocket: %s" err)
         (when callback (funcall callback nil))
         nil)))))

(defun claude-code-mcp-disconnect (conn-key)
  "Disconnect MCP connection for CONN-KEY and remove from hash table."
  ;; Stop ping timers
  (claude-code-mcp-stop-ping-timer conn-key)
  (claude-code-mcp-stop-ping-timeout conn-key)
  ;; Close websocket — nil it BEFORE closing so on-close sees it as stale
  (let* ((info (claude-code-mcp-get-connection-info conn-key))
         (ws (when info (cdr (assoc 'websocket info)))))
    (when info
      (setcdr (assoc 'websocket info) nil))
    (when ws
      (ignore-errors (websocket-close ws)))
    (when-let ((pending (and info (cdr (assoc 'pending-requests info)))))
      (clrhash pending))
    ;; Remove entry from hash table
    (remhash conn-key claude-code-mcp-project-connections)
    (message "Disconnected from MCP server (conn: %s)" conn-key)))

;;; Ping/Pong functionality

(defun claude-code-mcp-send-ping (conn-key)
  "Send ping message to MCP server for CONN-KEY."
  (let ((websocket (claude-code-mcp-get-websocket conn-key)))
    (when (and websocket (websocket-openp websocket))
      (condition-case err
          (progn
            (websocket-send-text websocket "{\"type\":\"ping\"}")
            ;; Set up timeout timer
            (claude-code-mcp-start-ping-timeout conn-key))
        (error
         (message "Error sending ping to MCP server: %s" err)
         (claude-code-mcp-handle-connection-lost conn-key))))))

(defun claude-code-mcp-start-ping-timer (conn-key)
  "Start periodic ping timer for CONN-KEY."
  (claude-code-mcp-stop-ping-timer conn-key)
  (when-let ((info (claude-code-mcp-get-connection-info conn-key)))
    (let ((timer (run-with-timer claude-code-mcp-ping-interval
                                 claude-code-mcp-ping-interval
                                 #'claude-code-mcp-send-ping
                                 conn-key)))
      (setcdr (assoc 'ping-timer info) timer))))

(defun claude-code-mcp-stop-ping-timer (conn-key)
  "Stop ping timer for CONN-KEY."
  (when-let* ((info (claude-code-mcp-get-connection-info conn-key))
              (timer (cdr (assoc 'ping-timer info))))
    (when (timerp timer)
      (cancel-timer timer))
    (setcdr (assoc 'ping-timer info) nil)))

(defun claude-code-mcp-start-ping-timeout (conn-key)
  "Start ping timeout timer for CONN-KEY."
  (claude-code-mcp-stop-ping-timeout conn-key)
  (when-let ((info (claude-code-mcp-get-connection-info conn-key)))
    (let ((timer (run-with-timer claude-code-mcp-ping-timeout
                                 nil
                                 #'claude-code-mcp-handle-ping-timeout
                                 conn-key)))
      (setcdr (assoc 'ping-timeout-timer info) timer))))

(defun claude-code-mcp-stop-ping-timeout (conn-key)
  "Stop ping timeout timer for CONN-KEY."
  (when-let* ((info (claude-code-mcp-get-connection-info conn-key))
              (timer (cdr (assoc 'ping-timeout-timer info))))
    (when (timerp timer)
      (cancel-timer timer))
    (setcdr (assoc 'ping-timeout-timer info) nil)))

(defun claude-code-mcp-handle-ping-timeout (conn-key)
  "Handle ping timeout for CONN-KEY."
  (message "MCP WebSocket ping timeout (conn: %s)" conn-key)
  (claude-code-mcp-handle-connection-lost conn-key))

(defun claude-code-mcp-handle-pong (conn-key)
  "Handle pong response for CONN-KEY."
  ;; Cancel timeout timer
  (claude-code-mcp-stop-ping-timeout conn-key)
  ;; Update last pong time
  (when-let ((info (claude-code-mcp-get-connection-info conn-key)))
    (setcdr (assoc 'last-pong-time info) (current-time))))

(defun claude-code-mcp-handle-connection-lost (conn-key)
  "Handle lost connection for CONN-KEY and attempt reconnection."
  (let* ((info (claude-code-mcp-get-connection-info conn-key))
         (project-root (when info (cdr (assoc 'project-root info))))
         (port (when info (cdr (assoc 'port info)))))
    (message "MCP WebSocket connection lost (conn: %s), attempting reconnect..." conn-key)
    ;; Stop timers
    (claude-code-mcp-stop-ping-timer conn-key)
    (claude-code-mcp-stop-ping-timeout conn-key)
    ;; Clean up websocket without removing the hash entry
    (when info
      (let ((ws (cdr (assoc 'websocket info))))
        (setcdr (assoc 'websocket info) nil)
        (when ws
          (ignore-errors (websocket-close ws))))
      (when-let ((pending (cdr (assoc 'pending-requests info))))
        (clrhash pending)))
    ;; Re-create entry and schedule reconnect
    (when (and project-root port)
      (claude-code-mcp-initialize-connection-info conn-key project-root)
      (let ((new-info (claude-code-mcp-get-connection-info conn-key)))
        (setcdr (assoc 'port new-info) port)
        (setcdr (assoc 'connection-attempts new-info) 0)
        (let ((timer (run-at-time claude-code-mcp-connection-retry-delay nil
                                  #'claude-code-mcp-try-connect-async conn-key)))
          (setcdr (assoc 'reconnect-timer new-info) timer))))))

;;; Event notification functions

(defun claude-code-mcp-send-event-to-project (project-root event-name params)
  "Send an event notification to ALL MCP servers for PROJECT-ROOT.
PROJECT-ROOT is the root directory of the project.
EVENT-NAME is the event type (e.g., \"bufferListUpdated\").
PARAMS is an alist of event parameters."
  (dolist (entry (claude-code-mcp-get-all-project-connections project-root))
    (let* ((info (cdr entry))
           (ws (cdr (assoc 'websocket info))))
      (when (and ws (websocket-openp ws))
        (condition-case err
            (let* ((enhanced-params (append params
                                           `((emacs_instance_id . ,(emacs-pid))
                                             (project_root . ,project-root))))
                   (message (json-encode
                            `((jsonrpc . "2.0")
                              (method . ,(concat "emacs/" event-name))
                              (params . ,enhanced-params)))))
              (websocket-send-text ws message))
          (error
           (message "Error sending event %s to MCP server for project %s: %s"
                    event-name project-root err)))))))

(provide 'claude-code-mcp-connection)
;;; claude-code-mcp-connection.el ends here
