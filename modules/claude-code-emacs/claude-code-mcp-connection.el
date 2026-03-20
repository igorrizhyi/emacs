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
;; - Per-project connection tracking
;; - Port discovery and registration
;; - Connection retry logic with exponential backoff
;; - WebSocket lifecycle management
;; - Health monitoring via ping/pong heartbeat
;; - Automatic reconnection on connection loss

;;; Code:

(require 'websocket nil t)
(require 'projectile)
(require 'json)
(require 'claude-code-core)

;; Declare websocket functions to avoid eager macro-expansion failures
(declare-function websocket-open "websocket" (url &rest args))
(declare-function websocket-send-text "websocket" (websocket text))
(declare-function websocket-close "websocket" (websocket))
(declare-function websocket-openp "websocket" (websocket))

;; Forward declarations
(declare-function claude-code-mcp-on-message "claude-code-mcp-protocol" (_websocket frame project-root))
(declare-function claude-code-mcp-on-error "claude-code-mcp-protocol" (_websocket type error &optional _project-root))
(declare-function claude-code-mcp-on-close "claude-code-mcp-protocol" (_websocket project-root))

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
  "Hash table mapping instance-specific project keys to connection info.
Key format: \"{instance-id}:{project-root}\" (e.g., \"12345:/path/to/project\")
Each value is an alist with keys:
  - websocket: The WebSocket connection
  - port: The MCP server port (for reconnection)
  - request-id: Counter for JSON-RPC request IDs
  - pending-requests: Hash table of pending requests
  - connection-attempts: Number of connection attempts
  - ping-timer: Timer for periodic ping messages
  - ping-timeout-timer: Timer for ping timeout detection
  - last-pong-time: Time of last received pong
  - reconnect-timer: Timer for pending reconnection attempt")

(defun claude-code-mcp-make-instance-project-key (project-root)
  "Create instance-specific project key for PROJECT-ROOT.
Returns key in format: \"{instance-id}:{project-root}\"."
  (format "%d:%s" (emacs-pid) (claude-code-normalize-project-root project-root)))

(defun claude-code-mcp-is-project-for-current-instance (project-root)
  "Check if PROJECT-ROOT belongs to current Emacs instance."
  (gethash (claude-code-mcp-make-instance-project-key project-root)
           claude-code-mcp-project-connections))

(defun claude-code-mcp-get-current-instance-projects ()
  "Get list of project roots managed by current Emacs instance.
Returns a list suitable for maphash iteration."
  (let ((current-instance-id (emacs-pid))
        (projects '()))
    (maphash 
     (lambda (key value)
       (when (string-prefix-p (format "%d:" current-instance-id) key)
         ;; Extract project root from "instance-id:project-root"
         (let ((project-root (substring key (+ (length (format "%d:" current-instance-id)) 0))))
           (push (cons project-root value) projects))))
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

(defun claude-code-mcp-initialize-connection-info (project-root)
  "Initialize and return connection info for PROJECT-ROOT.
Creates a new connection info structure with default values."
  ;; Ensure instance-specific server is running
  (claude-code-mcp-ensure-instance-server)
  
  (let* ((instance-key (claude-code-mcp-make-instance-project-key project-root))
         ;; QUESTION: '((websocket . nil)) みたいな書き方だと setcdr したときに全て変更されるのはなんで？
         (info (list (cons 'websocket nil)
                     (cons 'port nil)
                     (cons 'request-id 0)
                     (cons 'pending-requests (make-hash-table :test 'equal))
                     (cons 'connection-attempts 0)
                     (cons 'ping-timer nil)
                     (cons 'ping-timeout-timer nil)
                     (cons 'last-pong-time nil)
                     (cons 'reconnect-timer nil))))
    (puthash instance-key info claude-code-mcp-project-connections)
    info))

(defun claude-code-mcp-get-connection-info (project-root)
  "Get connection info for PROJECT-ROOT.
Returns nil if no connection info exists for the project in this instance."
  (gethash (claude-code-mcp-make-instance-project-key project-root)
           claude-code-mcp-project-connections))


(defun claude-code-mcp-get-websocket (project-root)
  "Get WebSocket for PROJECT-ROOT."
  (when-let ((info (claude-code-mcp-get-connection-info project-root)))
    (cdr (assoc 'websocket info))))

(defun claude-code-mcp-set-websocket (websocket project-root)
  "Set WEBSOCKET for PROJECT-ROOT."
  (when-let ((info (claude-code-mcp-get-connection-info project-root)))
    (setcdr (assoc 'websocket info) websocket)))

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
Resolves worktree paths to the main project root before normalization.
If an existing connection exists for this project, disconnect it first
to avoid stale websocket/timer state when a new MCP server replaces
the old one (e.g., when multiple agents share the same project root)."
  (let* ((resolved-root (claude-code-mcp--resolve-main-project-root project-root))
         (normalized-root (claude-code-normalize-project-root resolved-root)))
    ;; Cancel any pending reconnect timer to avoid duplicate connections
    (when-let* ((info (claude-code-mcp-get-connection-info normalized-root))
                (reconnect-timer (cdr (assoc 'reconnect-timer info))))
      (when (timerp reconnect-timer)
        (cancel-timer reconnect-timer)
        (message "MCP: Cancelled pending reconnect timer for %s" normalized-root))
      (setcdr (assoc 'reconnect-timer info) nil))
    ;; Clean up any existing connection before registering the new one
    (when (claude-code-mcp-get-connection-info normalized-root)
      (message "MCP: Closing existing connection for %s before registering new port %d"
               normalized-root port)
      (claude-code-mcp-disconnect normalized-root))
    ;; Initialize connection info for this project
    (claude-code-mcp-initialize-connection-info normalized-root)
    ;; Store port in connection info for reconnection
    (let ((info (claude-code-mcp-get-connection-info normalized-root)))
      (setcdr (assoc 'port info) port))
    (message "MCP server registered on port %d for project %s" port normalized-root)
    ;; Delay connection to allow old WebSocket close frame to complete,
    ;; avoiding MASK errors from close/connect frame collision
    (run-at-time 0.1 nil
                 #'claude-code-mcp-try-connect-async normalized-root port)))

(defun claude-code-mcp-unregister-port (project-root)
  "Unregister the MCP port for PROJECT-ROOT and disconnect.
This function is called when the MCP server shuts down or when
the Claude Code session ends.  It resolves worktree paths, normalizes
the project root, and disconnects the WebSocket connection."
  (let* ((resolved-root (claude-code-mcp--resolve-main-project-root project-root))
         (normalized-root (claude-code-normalize-project-root resolved-root)))
    (claude-code-mcp-disconnect normalized-root)))

;;; Connection Management

(defun claude-code-mcp-try-connect-async (project-root port)
  "Try to connect to MCP server asynchronously for PROJECT-ROOT."
  (let* ((info (claude-code-mcp-get-connection-info project-root))
         (attempts (cdr (assoc 'connection-attempts info))))
    (if (>= attempts claude-code-mcp-max-connection-attempts)
        (progn
          (message "Failed to connect to MCP server after %d attempts for project %s"
                   claude-code-mcp-max-connection-attempts project-root))
      (setcdr (assoc 'connection-attempts info) (1+ attempts))
      (message "Attempting to connect to MCP server (attempt %d/%d) for project %s..."
               (1+ attempts)
               claude-code-mcp-max-connection-attempts
               project-root)
      (claude-code-mcp-connect
       project-root
       port
       (lambda (connected)
         (unless connected
           ;; Connection failed, retry
           (run-at-time claude-code-mcp-connection-retry-delay nil
                        #'claude-code-mcp-try-connect-async project-root port)))))))

(defun claude-code-mcp-connect (project-root port &optional callback)
  "Connect to MCP server WebSocket for PROJECT-ROOT.
If CALLBACK is provided, call it with connection result."
  (condition-case err
      (progn
        (websocket-open
         (format "ws://%s:%d/?session=%s"
                 claude-code-mcp-host
                 port
                 (url-hexify-string (format "%d:%s" (emacs-pid) project-root)))
         :on-open (lambda (websocket)
                    (message "MCP WebSocket opened for project %s" project-root)
                    (when-let ((info (claude-code-mcp-get-connection-info project-root)))
                      (setcdr (assoc 'connection-attempts info) 0))
                    (claude-code-mcp-set-websocket websocket project-root)
                    ;; Start ping timer
                    (claude-code-mcp-start-ping-timer project-root)
                    (when callback (funcall callback t)))
         :on-message (lambda (websocket frame)
                       (claude-code-mcp-on-message websocket frame project-root))
         :on-error (lambda (websocket type error)
                     (claude-code-mcp-on-error websocket type error project-root))
         :on-close (lambda (websocket)
                     (claude-code-mcp-on-close websocket project-root)))
        (message "Initiating MCP WebSocket connection on port %d for project %s" port project-root)
        t)
    (error
     (message "Failed to open WebSocket: %s" err)
     (when callback (funcall callback nil))
     nil)))

(defun claude-code-mcp-disconnect (project-root)
  "Disconnect from MCP server for PROJECT-ROOT."
  ;; Stop ping timers
  (claude-code-mcp-stop-ping-timer project-root)
  (claude-code-mcp-stop-ping-timeout project-root)
  ;; Close websocket
  (let ((websocket (claude-code-mcp-get-websocket project-root)))
    (when websocket
      (websocket-close websocket)
      (claude-code-mcp-set-websocket nil project-root))
    (when-let* ((info (claude-code-mcp-get-connection-info project-root))
                (pending-requests (cdr (assoc 'pending-requests info))))
      (clrhash pending-requests))
    (message "Disconnected from MCP server for project %s" project-root)))

;;; Ping/Pong functionality

(defun claude-code-mcp-send-ping (project-root)
  "Send ping message to MCP server for PROJECT-ROOT."
  (let ((websocket (claude-code-mcp-get-websocket project-root)))
    (when (and websocket (websocket-openp websocket))
      (condition-case err
          (progn
            (websocket-send-text websocket "{\"type\":\"ping\"}")
            ;; Set up timeout timer
            (claude-code-mcp-start-ping-timeout project-root))
        (error
         (message "Error sending ping to MCP server: %s" err)
         (claude-code-mcp-handle-connection-lost project-root))))))

(defun claude-code-mcp-start-ping-timer (project-root)
  "Start periodic ping timer for PROJECT-ROOT."
  (claude-code-mcp-stop-ping-timer project-root)
  (let* ((info (claude-code-mcp-get-connection-info project-root))
         (timer (run-with-timer claude-code-mcp-ping-interval
                                claude-code-mcp-ping-interval
                                #'claude-code-mcp-send-ping
                                project-root)))
    (setcdr (assoc 'ping-timer info) timer)))

(defun claude-code-mcp-stop-ping-timer (project-root)
  "Stop ping timer for PROJECT-ROOT."
  (let* ((info (claude-code-mcp-get-connection-info project-root))
         (timer (cdr (assoc 'ping-timer info))))
    (when (timerp timer)
      (cancel-timer timer))
    (setcdr (assoc 'ping-timer info) nil)))

(defun claude-code-mcp-start-ping-timeout (project-root)
  "Start ping timeout timer for PROJECT-ROOT."
  (claude-code-mcp-stop-ping-timeout project-root)
  (let* ((info (claude-code-mcp-get-connection-info project-root))
         (timer (run-with-timer claude-code-mcp-ping-timeout
                                nil
                                #'claude-code-mcp-handle-ping-timeout
                                project-root)))
    (setcdr (assoc 'ping-timeout-timer info) timer)))

(defun claude-code-mcp-stop-ping-timeout (project-root)
  "Stop ping timeout timer for PROJECT-ROOT."
  (let* ((info (claude-code-mcp-get-connection-info project-root))
         (timer (cdr (assoc 'ping-timeout-timer info))))
    (when (timerp timer)
      (cancel-timer timer))
    (setcdr (assoc 'ping-timeout-timer info) nil)))

(defun claude-code-mcp-handle-ping-timeout (project-root)
  "Handle ping timeout for PROJECT-ROOT."
  (message "MCP WebSocket ping timeout for project %s" project-root)
  (claude-code-mcp-handle-connection-lost project-root))

(defun claude-code-mcp-handle-pong (project-root)
  "Handle pong response for PROJECT-ROOT."
  ;; Cancel timeout timer
  (claude-code-mcp-stop-ping-timeout project-root)
  ;; Update last pong time
  (let ((info (claude-code-mcp-get-connection-info project-root)))
    (setcdr (assoc 'last-pong-time info) (current-time))))

(defun claude-code-mcp-handle-connection-lost (project-root)
  "Handle lost connection for PROJECT-ROOT and attempt reconnection."
  (message "MCP WebSocket connection lost for project %s, attempting reconnect..." project-root)
  ;; Stop timers
  (claude-code-mcp-stop-ping-timer project-root)
  (claude-code-mcp-stop-ping-timeout project-root)
  ;; Close existing connection
  (claude-code-mcp-disconnect project-root)
  ;; Actually attempt reconnection
  (let* ((info (claude-code-mcp-get-connection-info project-root))
         (port (cdr (assoc 'port info))))
    (when port
      (setcdr (assoc 'connection-attempts info) 0)
      (let ((timer (run-at-time claude-code-mcp-connection-retry-delay nil
                                #'claude-code-mcp-try-connect-async project-root port)))
        (setcdr (assoc 'reconnect-timer info) timer)))))

;;; Event notification functions

(defun claude-code-mcp-send-event-to-project (project-root event-name params)
  "Send an event notification to a specific project's MCP server.
PROJECT-ROOT is the root directory of the project.
EVENT-NAME is the event type (e.g., \"bufferListUpdated\").
PARAMS is an alist of event parameters."
  (let ((websocket (claude-code-mcp-get-websocket project-root)))
    (when (and websocket (websocket-openp websocket))
      (condition-case err
          (let* ((enhanced-params (append params
                                         `((emacs_instance_id . ,(emacs-pid))
                                           (project_root . ,project-root))))
                 (message (json-encode
                          `((jsonrpc . "2.0")
                            (method . ,(concat "emacs/" event-name))
                            (params . ,enhanced-params)))))
            (websocket-send-text websocket message))
        (error
         (message "Error sending event %s to MCP server for project %s: %s"
                  event-name project-root err))))))

(provide 'claude-code-mcp-connection)
;;; claude-code-mcp-connection.el ends here
