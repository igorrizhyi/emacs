;;; my-agent-shell-debug-logging.el --- Temporary debug logging for ACP init pipeline -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; TEMPORARY DEBUG LOGGING — remove this file when done diagnosing
;; the tester agent init hang and Gemini agent issues.
;;
;; All log messages use the `[acp-init]' or `[acp-debug]' prefix for
;; easy grepping in *Messages*.
;;
;; What's logged:
;;   1. agent-shell--handle pipeline steps (via advice)
;;   2. acp--route-incoming-message callback errors (via advice)
;;   3. acp--start-client sentinel event + stderr preservation (via advice)
;;   4. acp--start-client raw process filter output + filter error catching (via advice)
;;   5. agent-shell--initiate-new-session on-session-init callback (via advice)
;;   6. agent-shell--emit-event emissions during init (via advice)
;;   7. session/new MCP payload — mcp-servers arg, buffer, agent type (via advice)
;;   8. session/new response — session ID on success (via advice)
;;   9. ACP request errors — error details with buffer context (via advice)

;;; Code:

(require 'map)

;; Suppress byte-compiler "not known to be defined" for advice functions
;; defined inside `after!' blocks (which are deferred and invisible at
;; compile time).  This prevents false-positive "error" grep matches
;; in the pre-commit hook.
(declare-function my/acp-init--log-handle-step "my-agent-shell-debug-logging")
(declare-function my/acp-init--log-route-message "my-agent-shell-debug-logging")
(declare-function my/acp-init--log-sentinel "my-agent-shell-debug-logging")
(declare-function my/acp-init--log-start-client "my-agent-shell-debug-logging")
(declare-function my/acp-init--log-new-session "my-agent-shell-debug-logging")
(declare-function my/acp-init--log-emit-event "my-agent-shell-debug-logging")
(declare-function my/acp-debug-log-session-new-request "my-agent-shell-debug-logging")
(declare-function my/acp-debug-log-session-new-response "my-agent-shell-debug-logging")
(declare-function my/acp-debug-log-err-handler "my-agent-shell-debug-logging")
(declare-function my/acp-stderr--cleanup-old-buffers "my-agent-shell-debug-logging")
(declare-function agent-shell--state "agent-shell")
(declare-function agent-shell--mcp-servers "agent-shell")
(defvar agent-shell--state)  ; buffer-local, defined in agent-shell.el
(defvar agent-shell)  ; feature symbol used by after!
(defvar acp)          ; feature symbol used by after!

(defvar my/acp-stderr-max-buffers 5
  "Maximum number of preserved acp-client-stderr buffers to keep.
Oldest buffers beyond this limit are killed after each new preservation.")

;; ---------------------------------------------------------------------------
;; 1. agent-shell--handle — log each pipeline step
;; ---------------------------------------------------------------------------

(after! agent-shell
  (defun my/acp-init--log-handle-step (orig-fn &rest args)
    "Around advice on `agent-shell--handle': log which init step is entered."
    (let* ((shell-buffer (plist-get args :shell-buffer))
           (command (plist-get args :command))
           (buf-name (when (buffer-live-p shell-buffer)
                       (buffer-name shell-buffer))))
      (when (buffer-live-p shell-buffer)
        (with-current-buffer shell-buffer
          (let* ((state (agent-shell--state))
                 (client (map-elt state :client))
                 (has-handlers (and (map-nested-elt state '(:client :request-handlers))
                                    (map-nested-elt state '(:client :notification-handlers))
                                    (map-nested-elt state '(:client :error-handlers))))
                 (initialized (map-elt state :initialized))
                 (needs-auth (map-elt state :needs-authentication))
                 (authenticated (map-elt state :authenticated))
                 (session-id (map-nested-elt state '(:session :id)))
                 (set-model (map-elt state :set-model))
                 (set-session-mode (map-elt state :set-session-mode))
                 (step (cond
                        ((not client) "initialize-client")
                        ((not has-handlers) "subscriptions")
                        ((not initialized) "handshake (sending initialize request)")
                        ((and needs-auth (not authenticated)) "authenticate")
                        ((not session-id) "session/new")
                        ;; For model/mode steps we check the config fns
                        ((not set-model) "set-model (or skip)")
                        ((not set-session-mode) "set-session-mode (or skip)")
                        (t "init-finished → send prompt"))))
            (message "[acp-init] handle: entering %s [buf=%s cmd=%s]"
                     step buf-name (and command (truncate-string-to-width command 40))))))
      (apply orig-fn args)))

  (advice-add 'agent-shell--handle :around #'my/acp-init--log-handle-step))

;; ---------------------------------------------------------------------------
;; 2. acp--route-incoming-message — protect callbacks + log request IDs
;; ---------------------------------------------------------------------------

(after! acp
  (defun my/acp-init--log-route-message (orig-fn &rest args)
    "Log request routing and protect callbacks."
    (let* ((message (plist-get args :message))
           (object (and message (map-elt message :object)))
           (id (and object (map-elt object 'id)))
           (method (and object (map-elt object 'method)))
           (has-result (and object (map-contains-key object 'result)))
           (has-error (and object (map-elt object 'error))))
      ;; Log what we're routing
      (cond
       ((and id has-result)
        (message "[acp-init] response received for request %s (success)" id))
       ((and id has-error)
        (message "[acp-init] response received for request %s (error: %S)" id has-error))
       ((and method id)
        (message "[acp-init] incoming request: method=%s id=%s" method id))
       ((and method (not id))
        (message "[acp-init] notification: method=%s" method))
       (t
        (message "[acp-init] unrecognized message: %S" (and object (truncate-string-to-width
                                                                     (format "%S" object) 200)))))
      ;; Call original but wrap in condition-case to catch callback errors
      (condition-case err
          (apply orig-fn args)
        (error
         (message "[acp-init] ERROR in route-incoming-message (request-id=%s): %S" id err)
         nil))))

  (advice-add 'acp--route-incoming-message :around #'my/acp-init--log-route-message)

  ;; ---------------------------------------------------------------------------
  ;; 3. acp--start-client sentinel — log event string + preserve stderr on error
  ;; ---------------------------------------------------------------------------

  (defun my/acp-stderr--cleanup-old-buffers ()
    "Kill oldest acp-client-stderr buffers exceeding `my/acp-stderr-max-buffers'."
    (let ((stderr-bufs (seq-filter
                        (lambda (buf)
                          (string-prefix-p "acp-client-stderr(" (buffer-name buf)))
                        (buffer-list))))
      (when (> (length stderr-bufs) my/acp-stderr-max-buffers)
        ;; buffer-list returns buffers in MRU order; reverse to get oldest first
        (let ((to-kill (seq-take (reverse stderr-bufs)
                                 (- (length stderr-bufs) my/acp-stderr-max-buffers))))
          (dolist (buf to-kill)
            (message "[acp-init] cleaning up old stderr buffer: %s" (buffer-name buf))
            (kill-buffer buf))))))

  (defun my/acp-init--log-sentinel (orig-fn &rest args)
    "Around advice on `acp--start-client': wrap sentinel and filter to log events."
    (apply orig-fn args)
    ;; After orig-fn, the process is on the client. Wrap its sentinel and filter.
    (let* ((client (plist-get args :client))
           (process (map-elt client :process))
           (orig-sentinel (and process (process-sentinel process))))
      (when process
        ;; Wrap the sentinel
        (set-process-sentinel
         process
         (lambda (proc event)
           (message "[acp-init] process sentinel: event=%S status=%s cmd=%s"
                    (string-trim event)
                    (process-status proc)
                    (map-elt client :command))
           ;; On abnormal exit, preserve stderr buffer (don't let downstream kill it)
           (let ((abnormal (not (string-prefix-p "finished" (string-trim event)))))
             (when abnormal
               (message "[acp-init] ABNORMAL EXIT — preserving stderr buffer for diagnostics"))
             ;; The sentinel-fix advice (from stuck-busy-fixes) is the orig-sentinel here.
             ;; We need to prevent stderr buffer kill on abnormal exit.
             ;; We do this by temporarily making the stderr buffer immortal.
             (if (and abnormal orig-sentinel)
                 ;; Advise kill-buffer temporarily to skip stderr
                 (let ((stderr-buf-name (format "acp-client-stderr(%s)-%s"
                                                (map-elt client :command)
                                                (map-elt client :instance-count))))
                   (cl-letf (((symbol-function 'kill-buffer)
                              (let ((real-kill (symbol-function 'kill-buffer)))
                                (lambda (buf)
                                  (if (and (bufferp buf)
                                           (string= (buffer-name buf) stderr-buf-name))
                                      (message "[acp-init] preserved stderr buffer: %s" stderr-buf-name)
                                    (funcall real-kill buf))))))
                     (when orig-sentinel
                       (funcall orig-sentinel proc event)))
                   (my/acp-stderr--cleanup-old-buffers))
               (when orig-sentinel
                 (funcall orig-sentinel proc event))))))
        ;; Wrap the process filter to log raw output and catch filter errors
        (let ((orig-filter (process-filter process)))
          (set-process-filter
           process
           (lambda (proc output)
             (message "[acp-init] raw-filter: received %d bytes from %s" (length output) (process-name proc))
             ;; Log first 200 chars of each chunk
             (message "[acp-init] raw-filter: data=%.200s" output)
             (condition-case err
                 (funcall orig-filter proc output)
               (error
                (message "[acp-init] raw-filter: FILTER ERROR: %S" err)))))))))

  ;; This must run AFTER the stuck-busy-fixes sentinel advice, so we use :around
  ;; on the same function. Since stuck-busy-fixes also uses :around, our advice
  ;; wraps theirs (last added = outermost).
  (advice-add 'acp--start-client :around #'my/acp-init--log-sentinel)

  ;; ---------------------------------------------------------------------------
  ;; 4. acp--start-client filter — raw process output logging
  ;; ---------------------------------------------------------------------------
  ;; The filter wrapping above (in my/acp-init--log-sentinel) intercepts raw
  ;; process output BEFORE the internal filter lambda processes it. This lets us
  ;; see bytes that arrive but never reach acp--route-incoming-message, and catch
  ;; errors thrown by the filter (which would latch the message-queue-busy flag).
  ;; Additional: log when acp--start-client is called with client details.

  (defun my/acp-init--log-start-client (orig-fn &rest args)
    "Around advice on `acp--start-client': log the startup."
    (let* ((client (plist-get args :client))
           (cmd (map-elt client :command))
           (params (map-elt client :command-params))
           (env (map-elt client :environment-variables)))
      (message "[acp-init] start-client: cmd=%s params=%S" cmd params)
      (message "[acp-init] start-client: env-vars=%S"
               (mapcar (lambda (e)
                         (if (string-match "\\`\\([^=]+\\)=" e)
                             (concat (match-string 1 e) "=<redacted>")
                           e))
                       env))
      (apply orig-fn args)))

  (advice-add 'acp--start-client :around #'my/acp-init--log-start-client))

;; ---------------------------------------------------------------------------
;; 5. agent-shell--initiate-new-session — wrap on-session-init callback
;; ---------------------------------------------------------------------------

(after! agent-shell
  (defun my/acp-init--log-new-session (orig-fn &rest args)
    "Wrap on-session-init to log before/after."
    (let* ((orig-on-session-init (plist-get args :on-session-init))
           (logged-on-session-init
            (lambda ()
              (message "[acp-init] on-session-init: ENTERED")
              (condition-case err
                  (progn
                    (funcall orig-on-session-init)
                    (message "[acp-init] on-session-init: RETURNED OK"))
                (error
                 (message "[acp-init] on-session-init: ERROR: %S" err))))))
      (setq args (plist-put args :on-session-init logged-on-session-init))
      (apply orig-fn args)))
  (advice-add 'agent-shell--initiate-new-session :around #'my/acp-init--log-new-session))

;; ---------------------------------------------------------------------------
;; 6. agent-shell--emit-event — log event emissions during init
;; ---------------------------------------------------------------------------

(after! agent-shell
  (defun my/acp-init--log-emit-event (orig-fn &rest args)
    "Around advice on `agent-shell--emit-event': log event name and catch errors."
    (let ((event (plist-get args :event)))
      (message "[acp-init] emit-event: %s" event)
      (condition-case err
          (apply orig-fn args)
        (error
         (message "[acp-init] emit-event ERROR for %s: %S" event err)
         (signal (car err) (cdr err))))))
  (advice-add 'agent-shell--emit-event :around #'my/acp-init--log-emit-event))

;; ---------------------------------------------------------------------------
;; 7. session/new MCP payload — log mcp-servers, buffer, agent type
;; ---------------------------------------------------------------------------

(after! agent-shell
  (defun my/acp-debug-log-session-new-request (orig-fn &rest args)
    "Around advice on `agent-shell--initiate-new-session': log MCP payload."
    (let* ((buf-name (buffer-name))
           (state agent-shell--state)
           (agent-id (map-elt (map-elt state :agent-config) :identifier))
           (mcp-servers (agent-shell--mcp-servers))
           (server-count (if mcp-servers (length mcp-servers) 0))
           (server-names (when mcp-servers
                           (mapcar (lambda (s) (or (map-elt s 'name) "?"))
                                   (append mcp-servers nil)))))
      (message "[acp-debug] session/new: buf=%s agent=%s mcp-server-count=%d names=%S"
               buf-name agent-id server-count server-names)
      (when (and mcp-servers (> server-count 0))
        (message "[acp-debug] session/new: mcp-servers=%S"
                 (mapcar (lambda (s)
                           (let ((name (map-elt s 'name))
                                 (type (map-elt s 'type))
                                 (url (map-elt s 'url)))
                             (format "%s[%s]%s" (or name "?") (or type "?")
                                     (if url (format " url=%s" url) ""))))
                         (append mcp-servers nil))))
      (when (eq agent-id 'gemini-cli)
        (message "[acp-debug] session/new: GEMINI AGENT — full mcp-servers payload: %S"
                 mcp-servers)))
    (apply orig-fn args))
  (advice-add 'agent-shell--initiate-new-session :around #'my/acp-debug-log-session-new-request))

;; ---------------------------------------------------------------------------
;; 8. session/new response — log session ID on success
;; ---------------------------------------------------------------------------

(after! agent-shell
  (defun my/acp-debug-log-session-new-response (orig-fn &rest args)
    "Wrap on-success to log session/new response."
    (let* ((buf (current-buffer))
           (buf-name (buffer-name buf))
           (state agent-shell--state)
           (agent-id (map-elt (map-elt state :agent-config) :identifier))
           (orig-on-session-init (plist-get args :on-session-init))
           (logged-on-session-init
            (lambda ()
              (let ((session-id (map-nested-elt agent-shell--state '(:session :id))))
                (message "[acp-debug] session/new SUCCESS: buf=%s agent=%s session-id=%s"
                         buf-name agent-id session-id))
              (funcall orig-on-session-init))))
      (setq args (plist-put args :on-session-init logged-on-session-init))
      (apply orig-fn args)))
  (advice-add 'agent-shell--initiate-new-session :around #'my/acp-debug-log-session-new-response))

;; ---------------------------------------------------------------------------
;; 9. Error/abort capture — log ACP request failures with context
;; ---------------------------------------------------------------------------

(after! agent-shell
  (defun my/acp-debug-log-err-handler (orig-fn &rest args)
    "Wrap returned lambda to log ACP request failures."
    (let* ((_state (plist-get args :state))
           (shell-buffer (plist-get args :shell-buffer))
           (buf-name (when (buffer-live-p shell-buffer)
                       (buffer-name shell-buffer)))
           (agent-id (when (buffer-live-p shell-buffer)
                       (with-current-buffer shell-buffer
                         (map-elt (map-elt agent-shell--state :agent-config) :identifier))))
           (orig-handler (apply orig-fn args)))
      (lambda (acp-error raw-message)
        (let* ((err-msg (map-elt acp-error 'message))
               (err-code (map-elt acp-error 'code))
               (err-id (map-elt acp-error 'id))
               (raw-method (and raw-message (map-elt raw-message 'method))))
          (message "[acp-debug] REQUEST ERROR: buf=%s agent=%s code=%s id=%s method=%s msg=%s"
                   buf-name agent-id err-code err-id raw-method err-msg)
          (message "[acp-debug] REQUEST ERROR raw: %S" raw-message))
        (funcall orig-handler acp-error raw-message))))
  (advice-add 'agent-shell--make-error-handler :around #'my/acp-debug-log-err-handler))

;; ---------------------------------------------------------------------------
;; 10. Removal helper
;; ---------------------------------------------------------------------------

(defun my/acp-init-debug-logging-remove ()
  "Remove all debug logging advice. Call this when done debugging."
  (interactive)
  (advice-remove 'agent-shell--handle #'my/acp-init--log-handle-step)
  (advice-remove 'acp--route-incoming-message #'my/acp-init--log-route-message)
  (advice-remove 'acp--start-client #'my/acp-init--log-sentinel)
  (advice-remove 'acp--start-client #'my/acp-init--log-start-client)
  (advice-remove 'agent-shell--initiate-new-session #'my/acp-init--log-new-session)
  (advice-remove 'agent-shell--emit-event #'my/acp-init--log-emit-event)
  (advice-remove 'agent-shell--initiate-new-session #'my/acp-debug-log-session-new-request)
  (advice-remove 'agent-shell--initiate-new-session #'my/acp-debug-log-session-new-response)
  (advice-remove 'agent-shell--make-error-handler #'my/acp-debug-log-err-handler)
  (message "[acp-init] All debug logging advice removed"))

(message "[acp-init] Debug logging module loaded — all advice installed")

(provide 'my-agent-shell-debug-logging)
;;; my-agent-shell-debug-logging.el ends here
