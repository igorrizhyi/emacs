;;; agent-shell-team-ws.el --- WebSocket JSON-RPC 2.0 client for gang-of-none -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Igor Rizhyi
;; Keywords: tools, ai, websocket
;; Version: 0.1.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; WebSocket JSON-RPC 2.0 client for connecting to the gang-of-none
;; Python backend.  Provides request/response with callback tracking,
;; server-initiated notification dispatch, and auto-reconnect with
;; exponential backoff.
;;
;; Public API:
;;   agent-shell-team-ws-connect         — open WebSocket connection
;;   agent-shell-team-ws-disconnect      — graceful close
;;   agent-shell-team-ws-connected-p     — connection predicate
;;   agent-shell-team-ws-call            — JSON-RPC request with callback
;;   agent-shell-team-ws-notify          — JSON-RPC notification (fire-and-forget)
;;
;; Incoming server notifications are dispatched through
;; `agent-shell-team-ws-notification-handler', which the event-handlers
;; module should set.

;;; Code:

(require 'websocket)
(require 'json)

;;; --- Configuration ---

(defvar agent-shell-team-ws-request-timeout 30
  "Seconds before a pending JSON-RPC request times out.")

(defvar agent-shell-team-ws-notification-handler nil
  "Function called for server-initiated notifications.
Called as (funcall handler METHOD PARAMS) where METHOD is a string
and PARAMS is a plist.")

;;; --- Connection state ---

(defvar agent-shell-team-ws--connection nil
  "Current `websocket' object, or nil if disconnected.")

(defvar agent-shell-team-ws--url nil
  "URL of the current or last connection attempt.")

(defvar agent-shell-team-ws--on-open-callback nil
  "Callback passed to `agent-shell-team-ws-connect', called on open.")

;;; --- JSON-RPC state ---

(defvar agent-shell-team-ws--next-id 0
  "Monotonic counter for outgoing JSON-RPC request IDs.")

(defvar agent-shell-team-ws--pending (make-hash-table :test 'eql)
  "Hash-table: request-id (integer) → plist (:callback :timer).")

;;; --- Reconnect state ---

(defvar agent-shell-team-ws--reconnect-timer nil
  "Timer for the next reconnect attempt, or nil.")

(defvar agent-shell-team-ws--reconnect-attempts 0
  "Number of consecutive reconnect attempts since last successful connection.")

(defvar agent-shell-team-ws--max-reconnect-delay 60
  "Maximum delay in seconds between reconnect attempts.")

(defvar agent-shell-team-ws--reconnecting-p nil
  "Non-nil when auto-reconnect is active (prevents duplicate reconnect loops).")

;;; --- JSON helpers ---

(defun agent-shell-team-ws--encode-json (obj)
  "Encode OBJ (a plist or alist) to a JSON string.
Uses native `json-serialize' when available, falls back to `json-encode'."
  (if (fboundp 'json-serialize)
      (json-serialize obj :null-object nil :false-object :json-false)
    (let ((json-encoding-pretty-print nil))
      (json-encode obj))))

(defun agent-shell-team-ws--parse-json (string)
  "Parse JSON STRING into a plist.  Return nil on error."
  (condition-case nil
      (if (fboundp 'json-parse-string)
          (json-parse-string string
                             :object-type 'plist
                             :null-object nil
                             :false-object :json-false)
        (let ((json-object-type 'plist)
              (json-key-type 'keyword)
              (json-array-type 'list))
          (json-read-from-string string)))
    (error nil)))

;;; --- Pending request management ---

(defun agent-shell-team-ws--register-callback (id callback)
  "Register CALLBACK for request ID, with a timeout timer."
  (let ((timer (run-with-timer
                agent-shell-team-ws-request-timeout nil
                #'agent-shell-team-ws--timeout-request id)))
    (puthash id (list :callback callback :timer timer)
             agent-shell-team-ws--pending)))

(defun agent-shell-team-ws--resolve-callback (id result error)
  "Resolve pending callback for ID with RESULT or ERROR, then clean up."
  (let ((entry (gethash id agent-shell-team-ws--pending)))
    (when entry
      (let ((callback (plist-get entry :callback))
            (timer (plist-get entry :timer)))
        (when timer (cancel-timer timer))
        (remhash id agent-shell-team-ws--pending)
        (when callback
          (condition-case err
              (funcall callback result error)
            (error
             (message "agent-shell-team-ws: callback error for id %s: %s"
                      id (error-message-string err)))))))))

(defun agent-shell-team-ws--timeout-request (id)
  "Handle timeout for pending request ID."
  (let ((entry (gethash id agent-shell-team-ws--pending)))
    (when entry
      (message "agent-shell-team-ws: request %d timed out" id)
      (let ((callback (plist-get entry :callback)))
        (remhash id agent-shell-team-ws--pending)
        (when callback
          (condition-case err
              (funcall callback nil (list :code -32000 :message "Request timed out"))
            (error
             (message "agent-shell-team-ws: timeout callback error: %s"
                      (error-message-string err)))))))))

(defun agent-shell-team-ws--cancel-all-pending (reason)
  "Cancel all pending requests with REASON string."
  (maphash
   (lambda (_id entry)
     (let ((callback (plist-get entry :callback))
           (timer (plist-get entry :timer)))
       (when timer (cancel-timer timer))
       (when callback
         (condition-case nil
             (funcall callback nil (list :code -32001 :message reason))
           (error nil)))))
   agent-shell-team-ws--pending)
  (clrhash agent-shell-team-ws--pending))

;;; --- WebSocket message handling ---

(defun agent-shell-team-ws--on-message (_ws frame)
  "Handle an incoming WebSocket FRAME."
  (let* ((text (websocket-frame-text frame))
         (msg (agent-shell-team-ws--parse-json text)))
    (unless msg
      (message "agent-shell-team-ws: failed to parse frame: %s"
               (truncate-string-to-width text 200))
      (cl-return-from agent-shell-team-ws--on-message))
    (let ((id (plist-get msg :id))
          (method (plist-get msg :method))
          (error-obj (plist-get msg :error))
          (result (plist-get msg :result))
          (params (plist-get msg :params)))
      (cond
       ;; Response to a pending request (has id, matches pending)
       ((and id (gethash id agent-shell-team-ws--pending))
        (agent-shell-team-ws--resolve-callback id result error-obj))
       ;; Server notification (has method, no id)
       ((and method (not id))
        (if agent-shell-team-ws-notification-handler
            (condition-case err
                (funcall agent-shell-team-ws-notification-handler method params)
              (error
               (message "agent-shell-team-ws: notification handler error for %s: %s"
                        method (error-message-string err))))
          (message "agent-shell-team-ws: unhandled server notification: %s" method)))
       ;; Error response with id but no pending callback
       ((and id error-obj)
        (message "agent-shell-team-ws: error response for unknown id %s: %s"
                 id error-obj))
       (t
        (message "agent-shell-team-ws: unrecognized message: %s"
                 (truncate-string-to-width text 200)))))))

;;; --- Reconnect logic ---

(defun agent-shell-team-ws--reconnect-delay ()
  "Compute exponential backoff delay for current attempt count."
  (min agent-shell-team-ws--max-reconnect-delay
       (* 1 (expt 2 (min agent-shell-team-ws--reconnect-attempts 6)))))

(defun agent-shell-team-ws--schedule-reconnect ()
  "Schedule a reconnect attempt with exponential backoff."
  (when (and agent-shell-team-ws--url
             (not agent-shell-team-ws--reconnecting-p))
    (setq agent-shell-team-ws--reconnecting-p t)
    (let ((delay (agent-shell-team-ws--reconnect-delay)))
      (message "agent-shell-team-ws: reconnecting in %ds (attempt %d)"
               delay (1+ agent-shell-team-ws--reconnect-attempts))
      (setq agent-shell-team-ws--reconnect-timer
            (run-with-timer delay nil #'agent-shell-team-ws--do-reconnect)))))

(defun agent-shell-team-ws--do-reconnect ()
  "Execute a reconnect attempt."
  (setq agent-shell-team-ws--reconnect-timer nil)
  (setq agent-shell-team-ws--reconnecting-p nil)
  (cl-incf agent-shell-team-ws--reconnect-attempts)
  (when agent-shell-team-ws--url
    (condition-case err
        (agent-shell-team-ws-connect agent-shell-team-ws--url
                                     agent-shell-team-ws--on-open-callback)
      (error
       (message "agent-shell-team-ws: reconnect failed: %s"
                (error-message-string err))
       (agent-shell-team-ws--schedule-reconnect)))))

(defun agent-shell-team-ws--cancel-reconnect ()
  "Cancel any pending reconnect timer."
  (when agent-shell-team-ws--reconnect-timer
    (cancel-timer agent-shell-team-ws--reconnect-timer)
    (setq agent-shell-team-ws--reconnect-timer nil))
  (setq agent-shell-team-ws--reconnecting-p nil)
  (setq agent-shell-team-ws--reconnect-attempts 0))

;;; --- WebSocket lifecycle callbacks ---

(defun agent-shell-team-ws--on-open (_ws)
  "Handle successful WebSocket connection."
  (message "agent-shell-team-ws: connected to %s" agent-shell-team-ws--url)
  (setq agent-shell-team-ws--reconnect-attempts 0)
  (setq agent-shell-team-ws--reconnecting-p nil)
  (when agent-shell-team-ws--on-open-callback
    (condition-case err
        (funcall agent-shell-team-ws--on-open-callback)
      (error
       (message "agent-shell-team-ws: on-open callback error: %s"
                (error-message-string err))))))

(defun agent-shell-team-ws--on-close (_ws)
  "Handle WebSocket close."
  (message "agent-shell-team-ws: connection closed")
  (setq agent-shell-team-ws--connection nil)
  (agent-shell-team-ws--cancel-all-pending "Connection closed")
  (agent-shell-team-ws--schedule-reconnect))

(defun agent-shell-team-ws--on-error (_ws type err)
  "Handle WebSocket error of TYPE with ERR."
  (message "agent-shell-team-ws: error (%s): %s" type err))

;;; --- Public API ---

(defun agent-shell-team-ws-connect (url callback)
  "Open a WebSocket connection to URL.
CALLBACK is called with no arguments once the connection is open.
URL should be like `ws://localhost:8000/ws/{session-id}'."
  (when agent-shell-team-ws--connection
    (agent-shell-team-ws-disconnect))
  (agent-shell-team-ws--cancel-reconnect)
  (setq agent-shell-team-ws--url url)
  (setq agent-shell-team-ws--on-open-callback callback)
  (setq agent-shell-team-ws--connection
        (websocket-open url
                        :on-message #'agent-shell-team-ws--on-message
                        :on-open    #'agent-shell-team-ws--on-open
                        :on-close   #'agent-shell-team-ws--on-close
                        :on-error   #'agent-shell-team-ws--on-error)))

(defun agent-shell-team-ws-disconnect ()
  "Gracefully close the WebSocket connection.
Cancels auto-reconnect and all pending requests."
  (agent-shell-team-ws--cancel-reconnect)
  (agent-shell-team-ws--cancel-all-pending "Disconnecting")
  (when agent-shell-team-ws--connection
    (condition-case nil
        (websocket-close agent-shell-team-ws--connection)
      (error nil))
    (setq agent-shell-team-ws--connection nil))
  (setq agent-shell-team-ws--url nil)
  (setq agent-shell-team-ws--on-open-callback nil)
  (message "agent-shell-team-ws: disconnected"))

(defun agent-shell-team-ws-connected-p ()
  "Return non-nil if the WebSocket connection is open."
  (and agent-shell-team-ws--connection
       (websocket-openp agent-shell-team-ws--connection)))

(defun agent-shell-team-ws-call (method params callback)
  "Send a JSON-RPC 2.0 request with METHOD and PARAMS.
CALLBACK is called as (funcall callback RESULT ERROR) when the
response arrives or the request times out.  RESULT is a plist on
success; ERROR is a plist with :code and :message on failure."
  (unless (agent-shell-team-ws-connected-p)
    (funcall callback nil (list :code -32002 :message "Not connected"))
    (cl-return-from agent-shell-team-ws-call))
  (let* ((id (cl-incf agent-shell-team-ws--next-id))
         (request `(:jsonrpc "2.0"
                    :id ,id
                    :method ,method
                    :params ,params)))
    (agent-shell-team-ws--register-callback id callback)
    (condition-case err
        (websocket-send-text agent-shell-team-ws--connection
                             (agent-shell-team-ws--encode-json request))
      (error
       (agent-shell-team-ws--resolve-callback
        id nil (list :code -32003 :message (error-message-string err)))))))

(defun agent-shell-team-ws-notify (method params)
  "Send a JSON-RPC 2.0 notification with METHOD and PARAMS.
Notifications have no ID and expect no response."
  (unless (agent-shell-team-ws-connected-p)
    (message "agent-shell-team-ws: cannot notify, not connected")
    (cl-return-from agent-shell-team-ws-notify))
  (let ((request `(:jsonrpc "2.0"
                   :method ,method
                   :params ,params)))
    (condition-case err
        (websocket-send-text agent-shell-team-ws--connection
                             (agent-shell-team-ws--encode-json request))
      (error
       (message "agent-shell-team-ws: notify error: %s"
                (error-message-string err))))))

(provide 'agent-shell-team-ws)
;;; agent-shell-team-ws.el ends here
