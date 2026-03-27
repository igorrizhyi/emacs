;;; my-agent-shell-debug-logging.el --- Temporary debug logging for ACP init pipeline -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; TEMPORARY DEBUG LOGGING — remove this file when done diagnosing
;; the tester agent init hang.
;;
;; All log messages use the `[acp-init]' prefix for easy grepping
;; in *Messages*.
;;
;; What's logged:
;;   1. agent-shell--handle pipeline steps (via advice)
;;   2. acp--route-incoming-message callback errors (via advice)
;;   3. acp--start-client sentinel event + stderr preservation (via advice)
;;   4. acp--start-client filter message-queue state (via advice)

;;; Code:

(require 'map)

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
    "Around advice on `acp--route-incoming-message': log request routing and protect callbacks."
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

  (defun my/acp-init--log-sentinel (orig-fn &rest args)
    "Around advice on `acp--start-client': wrap sentinel to log exit events."
    (apply orig-fn args)
    ;; After orig-fn, the process is on the client. Wrap its sentinel.
    (let* ((client (plist-get args :client))
           (process (map-elt client :process))
           (orig-sentinel (and process (process-sentinel process))))
      (when process
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
                       (funcall orig-sentinel proc event))))
               (when orig-sentinel
                 (funcall orig-sentinel proc event)))))))))

  ;; This must run AFTER the stuck-busy-fixes sentinel advice, so we use :around
  ;; on the same function. Since stuck-busy-fixes also uses :around, our advice
  ;; wraps theirs (last added = outermost).
  (advice-add 'acp--start-client :around #'my/acp-init--log-sentinel)

  ;; ---------------------------------------------------------------------------
  ;; 4. acp--start-client filter — log message-queue-busy state
  ;; ---------------------------------------------------------------------------
  ;; We can't easily wrap the internal filter lambda, but we can advise
  ;; acp--route-incoming-message (done above in #2) to see each message processed.
  ;; For the message-queue-busy flag, we log indirectly via the route advice.
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
;; 7. Removal helper
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
  (message "[acp-init] All debug logging advice removed"))

(message "[acp-init] Debug logging module loaded — all advice installed")

(provide 'my-agent-shell-debug-logging)
;;; my-agent-shell-debug-logging.el ends here
