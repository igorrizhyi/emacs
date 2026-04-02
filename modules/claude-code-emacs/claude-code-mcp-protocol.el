;;; claude-code-mcp-protocol.el --- JSON-RPC protocol implementation for MCP -*- lexical-binding: t; -*-

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

;; This module implements the JSON-RPC protocol for MCP communication:
;; - Message parsing and dispatching
;; - Request/response handling
;; - Error handling
;; - WebSocket event handlers

;;; Code:

(require 'json)
(require 'websocket nil t)
(require 'projectile)

;; Declare websocket functions to avoid eager macro-expansion failures
(declare-function websocket-send-text "websocket" (websocket text))
(declare-function websocket-frame-text "websocket" (frame))

;; Forward declarations
(declare-function claude-code-mcp-get-connection-info "claude-code-mcp-connection" (conn-key))
(declare-function claude-code-mcp-get-websocket "claude-code-mcp-connection" (conn-key))
(declare-function claude-code-mcp-set-websocket "claude-code-mcp-connection" (websocket conn-key))
(declare-function claude-code-mcp-get-any-websocket-for-project "claude-code-mcp-connection" (project-root))
(declare-function claude-code-mcp-handle-pong "claude-code-mcp-connection" (conn-key))
(declare-function claude-code-mcp-handle-connection-lost "claude-code-mcp-connection" (conn-key))

;; Tool handler forward declarations
(declare-function claude-code-mcp-handle-getOpenBuffers "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-getCurrentSelection "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-getDiagnostics "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-get-buffer-content "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-get-project-info "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-get-project-files "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-getDefinition "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-findReferences "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-describeSymbol "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-openDiffFile "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-openRevisionDiff "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-openCurrentChanges "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-openDiffContent "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-sendNotification "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-getTerminalContent "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-executeTerminalCommandInEmacs "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-getTerminalList "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-createTerminal "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-tasksPut "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-taskUpdate "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-dismissAgent "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-presentOptions "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-listPendingReviews "claude-code-mcp-tools" (params))
(declare-function claude-code-mcp-handle-messageNamespacePeer "claude-code-mcp-tools" (params))

;;; JSON-RPC Communication

(defun claude-code-mcp-send-response (id result error project-root &optional websocket)
  "Send response for request ID with RESULT or ERROR for PROJECT-ROOT.
When WEBSOCKET is provided, send directly on it (bypassing project lookup).
This is critical for multi-agent setups where multiple MCP servers share
the same project-root — ensures the response reaches the correct server."
  (let ((ws (or websocket (claude-code-mcp-get-any-websocket-for-project project-root)))
        (response (if error
                      `((jsonrpc . "2.0")
                        (id . ,id)
                        (error . ,error))
                    `((jsonrpc . "2.0")
                      (id . ,id)
                      (result . ,result)))))
    (if ws
        (condition-case send-err
            (progn
              (websocket-send-text ws (json-encode response))
              (message "📤 [RESPONSE] Sent for request: %s (error: %s)" id (if error "yes" "no")))
          (error
           (message "❌ [RESPONSE] Failed to send response for %s: %s" id (error-message-string send-err))))
      (message "⚠️ [RESPONSE] No websocket available for request: %s (project: %s)" id project-root))))

;;; Message Handling

(defun claude-code-mcp-handle-message (message project-root &optional websocket conn-key)
  "Handle incoming JSON-RPC MESSAGE for PROJECT-ROOT.
WEBSOCKET is the connection that received this message.
CONN-KEY identifies the specific connection for pong and pending-request lookup."
  (condition-case err
      (let* ((json-object-type 'alist)
             (json-array-type 'list)
             (msg (json-read-from-string message)))
        (cond
         ;; Handle ping/pong messages
         ((equal (cdr (assoc 'type msg)) "pong")
          (when conn-key
            (claude-code-mcp-handle-pong conn-key)))

         ;; Request from server (check method first)
         ((assoc 'method msg)
          (claude-code-mcp-handle-request msg project-root websocket))

         ;; Response to our request
         ((assoc 'id msg)
          (when-let* ((id (cdr (assoc 'id msg)))
                      (info (when conn-key (claude-code-mcp-get-connection-info conn-key)))
                      (pending-requests (cdr (assoc 'pending-requests info)))
                      (callback (gethash id pending-requests)))
            (remhash id pending-requests)
            (if (assoc 'error msg)
                (funcall callback nil (cdr (assoc 'error msg)))
              (funcall callback (cdr (assoc 'result msg)) nil))))

         ;; Invalid message
         (t
          (message "Invalid JSON-RPC message: %s" message))))
    (error
     (message "Error handling MCP message: %s" err))))

(defun claude-code-mcp-handle-request (request project-root &optional websocket)
  "Handle incoming REQUEST from MCP server for PROJECT-ROOT.
WEBSOCKET is the connection that received this request — responses
are sent back on this exact connection to avoid cross-agent routing."
  (let* ((id (cdr (assoc 'id request)))
         (method (cdr (assoc 'method request)))
         (params (cdr (assoc 'params request)))
         (handler (intern (format "claude-code-mcp-handle-%s" method))))

    (message "MCP Request: method=%s, handler=%s, fboundp=%s"
             method handler (fboundp handler))

    (if (fboundp handler)
        (condition-case err
            (let ((result (funcall handler params)))
              ;; Check if result is async (contains :async-pending marker)
              (if (and (listp result) (eq (plist-get result :async-pending) t))
                  ;; Async operation - don't send response yet
                  (let* ((async-id (plist-get result :async-id))
                         (async-callback (plist-get result :async-callback)))
                    (message "🔄 [ASYNC] Starting operation: %s (request-id: %s)" async-id id)
                    ;; Store pending async request
                    (claude-code-mcp-store-async-request id async-id project-root)
                    ;; Execute async operation with callback
                    (funcall async-callback
                             (lambda (async-result)
                               (message "🔄 [ASYNC] Operation completed: %s, sending response..." async-id)
                               ;; Send response when async completes
                               (condition-case callback-err
                                   (progn
                                     (claude-code-mcp-send-response id async-result nil project-root websocket)
                                     (message "✅ [ASYNC] Response sent successfully for: %s" async-id))
                                 (error
                                  (message "❌ [ASYNC] Failed to send response for %s: %s" async-id (error-message-string callback-err))))
                               (claude-code-mcp-remove-async-request id project-root))))
                ;; Synchronous result - send immediately
                (message "🔄 [SYNC] Sending immediate response for request: %s" id)
                (claude-code-mcp-send-response id result nil project-root websocket)))
          (error
           (message "Error in handler %s: %s" handler err)
           (claude-code-mcp-send-response id nil
                                                `((code . -32603)
                                                  (message . ,(error-message-string err)))
                                                project-root websocket)))
      (claude-code-mcp-send-response id nil
                                           `((code . -32601)
                                             (message . ,(format "Method not found: %s" method)))
                                           project-root websocket))))

;;; Async Request Management

(defvar claude-code-mcp-async-requests (make-hash-table :test 'equal)
  "Hash table storing pending async requests by instance-project key.")

(defun claude-code-mcp-store-async-request (request-id async-id project-root)
  "Store async REQUEST-ID with ASYNC-ID for PROJECT-ROOT."
  ;; Extract instance ID from request-id if it's in format "instance-id-actual-id"
  (let* ((instance-id (if (stringp request-id)
                          (when (string-match "^\\([0-9]+\\)-" request-id)
                            (match-string 1 request-id))
                        (emacs-pid)))
         (instance-key (format "%s:%s" (or instance-id (emacs-pid)) project-root))
         (project-requests (gethash instance-key claude-code-mcp-async-requests)))
    (unless project-requests
      (setq project-requests (make-hash-table :test 'equal))
      (puthash instance-key project-requests claude-code-mcp-async-requests))
    (puthash request-id async-id project-requests)
    (message "📝 [ASYNC] Stored request: %s -> %s (instance-project: %s)" request-id async-id instance-key)))

(defun claude-code-mcp-remove-async-request (request-id project-root)
  "Remove async REQUEST-ID for PROJECT-ROOT."
  ;; Extract instance ID from request-id if it's in format "instance-id-actual-id"
  (let* ((instance-id (if (stringp request-id)
                          (when (string-match "^\\([0-9]+\\)-" request-id)
                            (match-string 1 request-id))
                        (emacs-pid)))
         (instance-key (format "%s:%s" (or instance-id (emacs-pid)) project-root))
         (project-requests (gethash instance-key claude-code-mcp-async-requests)))
    (if (and project-requests (gethash request-id project-requests))
        (progn
          (remhash request-id project-requests)
          (message "🗑️ [ASYNC] Removed request: %s (instance-project: %s)" request-id instance-key))
      (message "⚠️ [ASYNC] Attempted to remove non-existent request: %s (instance-project: %s)" request-id instance-key))))

(defun claude-code-mcp-get-async-request (request-id project-root)
  "Get async request info for REQUEST-ID in PROJECT-ROOT."
  ;; Extract instance ID from request-id if it's in format "instance-id-actual-id"
  (let* ((instance-id (if (stringp request-id)
                          (when (string-match "^\\([0-9]+\\)-" request-id)
                            (match-string 1 request-id))
                        (emacs-pid)))
         (instance-key (format "%s:%s" (or instance-id (emacs-pid)) project-root))
         (project-requests (gethash instance-key claude-code-mcp-async-requests)))
    (when project-requests
      (gethash request-id project-requests))))

;;; WebSocket Event Handlers

(defun claude-code-mcp-on-message (websocket frame project-root conn-key)
  "Handle incoming WebSocket message on WEBSOCKET for PROJECT-ROOT.
CONN-KEY identifies the specific connection for routing pong/responses."
  (let ((payload (websocket-frame-text frame)))
    (when payload
      (claude-code-mcp-handle-message payload project-root websocket conn-key))))

(defun claude-code-mcp-on-error (_websocket type error &optional _project-root)
  "Handle WebSocket error."
  (message "MCP WebSocket error (%s): %s" type error))

(defun claude-code-mcp-on-close (websocket conn-key)
  "Handle WebSocket close for CONN-KEY.
Only modify state if WEBSOCKET is still the current connection.
When disconnect nils the websocket before closing, this callback
sees a stale connection and ignores it (preventing spurious reconnects)."
  (let ((current-ws (claude-code-mcp-get-websocket conn-key)))
    (if (eq websocket current-ws)
        (progn
          (claude-code-mcp-set-websocket nil conn-key)
          (message "MCP WebSocket connection closed (conn: %s)" conn-key)
          (claude-code-mcp-handle-connection-lost conn-key))
      (message "MCP WebSocket close ignored (stale) for conn: %s" conn-key))))

(provide 'claude-code-mcp-protocol)
;;; claude-code-mcp-protocol.el ends here
