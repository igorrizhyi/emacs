;;; my-agent-shell-gemini-retry.el --- Retry transient Gemini errors with backoff -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Advice-based retry logic for Gemini agent transient failures (HTTP 500,
;; 503, "no capacity", rate limits, etc.).  When a Gemini agent hits a
;; transient error, the module intercepts the error handler, delays, and
;; re-sends the last prompt instead of letting the agent die.
;;
;; Max 3 retries with exponential backoff: 2s, 5s, 15s (matching the
;; Python backend's retry config).
;;
;; Only applies to Gemini agents — Claude agents are unaffected.

;;; Code:

(require 'map)

;; Forward declarations to suppress byte-compiler warnings
(declare-function agent-shell--state "agent-shell")
(declare-function agent-shell--make-error-handler "agent-shell")
(declare-function agent-shell-heartbeat-stop "agent-shell")
(declare-function shell-maker-submit "shell-maker")
(defvar agent-shell--state)
(defvar agent-shell)

;; ---------------------------------------------------------------------------
;; Configuration
;; ---------------------------------------------------------------------------

(defvar my/gemini-retry-max-attempts 3
  "Maximum number of retry attempts for transient Gemini errors.")

(defvar my/gemini-retry-backoff-seconds '(2 5 15)
  "Backoff delays in seconds for each retry attempt.")

(defvar my/gemini-retry-patterns
  '("500" "503" "no capacity" "overloaded" "temporarily unavailable"
    "RESOURCE_EXHAUSTED" "rate limit" "rate_limit" "capacity" "Internal error")
  "Error message patterns that indicate a transient Gemini error.")

;; ---------------------------------------------------------------------------
;; Buffer-local retry state
;; ---------------------------------------------------------------------------

(defvar-local my/gemini-retry--count 0
  "Current retry count for the buffer.")

(defvar-local my/gemini-retry--last-prompt nil
  "The last prompt/task message sent to this buffer's agent.")

(defvar-local my/gemini-retry--timer nil
  "Active retry timer for this buffer.")

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defun my/gemini-retry--gemini-agent-p ()
  "Return non-nil if the current buffer's agent is a Gemini agent."
  (when (and (boundp 'agent-shell--state) agent-shell--state)
    (let ((identifier (map-elt (map-elt agent-shell--state :agent-config)
                               :identifier)))
      (equal identifier "gemini-cli"))))

(defun my/gemini-retry--transient-error-p (message)
  "Return non-nil if MESSAGE matches a known transient error pattern."
  (when (stringp message)
    (let ((msg-lower (downcase message)))
      (cl-some (lambda (pattern)
                 (string-match-p (regexp-quote (downcase pattern)) msg-lower))
               my/gemini-retry-patterns))))

(defun my/gemini-retry--reset ()
  "Reset retry state for the current buffer."
  (setq my/gemini-retry--count 0)
  (when (timerp my/gemini-retry--timer)
    (cancel-timer my/gemini-retry--timer)
    (setq my/gemini-retry--timer nil)))

;; ---------------------------------------------------------------------------
;; Capture last prompt (to replay on retry)
;; ---------------------------------------------------------------------------

(after! agent-shell
  (defun my/gemini-retry--capture-prompt-a (orig-fn &rest args)
    "Around advice on `shell-maker-submit': capture prompt for Gemini retry."
    (when (my/gemini-retry--gemini-agent-p)
      (let ((input (plist-get args :input)))
        (when input
          (setq my/gemini-retry--last-prompt input))))
    (apply orig-fn args))

  (advice-add 'shell-maker-submit :around #'my/gemini-retry--capture-prompt-a)

  ;; Reset retry counter on successful response
  (defun my/gemini-retry--on-success-a (orig-fn &rest args)
    "Around advice on `agent-shell--send-command': reset retry on success."
    (when (my/gemini-retry--gemini-agent-p)
      (my/gemini-retry--reset))
    (apply orig-fn args))

  ;; We don't advise send-command for reset — instead we reset in the
  ;; error-handler advice when we decide NOT to retry (exhausted or non-transient).
  ;; On successful prompt delivery, the prompt capture already sets up state.

  ;; ---------------------------------------------------------------------------
  ;; Core: intercept error handler to retry transient Gemini errors
  ;; ---------------------------------------------------------------------------

  (defun my/gemini-retry--wrap-error-handler-a (orig-fn &rest args)
    "Around advice on `agent-shell--make-error-handler'.
Wraps the returned error handler lambda to intercept transient Gemini errors
and retry with backoff instead of letting the agent die."
    (let ((original-handler (apply orig-fn args))
          (shell-buffer (plist-get args :shell-buffer)))
      (lambda (acp-error raw-message)
        (let ((should-retry nil))
          (when (buffer-live-p shell-buffer)
            (with-current-buffer shell-buffer
              (when (and (my/gemini-retry--gemini-agent-p)
                         (my/gemini-retry--transient-error-p
                          (or (map-elt acp-error 'message) ""))
                         (< my/gemini-retry--count my/gemini-retry-max-attempts)
                         my/gemini-retry--last-prompt)
                (setq should-retry t))))
          (if should-retry
              (with-current-buffer shell-buffer
                (let* ((attempt (1+ my/gemini-retry--count))
                       (delay (or (nth my/gemini-retry--count
                                       my/gemini-retry-backoff-seconds)
                                  15))
                       (err-msg (or (map-elt acp-error 'message) "unknown")))
                  (setq my/gemini-retry--count attempt)
                  (message "[gemini-retry] Transient error in %s: %s (attempt %d/%d, retrying in %ds)"
                           (buffer-name) err-msg attempt
                           my/gemini-retry-max-attempts delay)
                  ;; Stop heartbeat during wait
                  (agent-shell-heartbeat-stop
                   :heartbeat (map-elt (agent-shell--state) :heartbeat))
                  ;; Clear busy state so shell-maker-submit can proceed
                  (when (boundp 'shell-maker--busy)
                    (setq shell-maker--busy nil))
                  ;; Schedule retry
                  (let ((buf shell-buffer)
                        (prompt my/gemini-retry--last-prompt))
                    (setq my/gemini-retry--timer
                          (run-at-time
                           delay nil
                           (lambda ()
                             (when (buffer-live-p buf)
                               (with-current-buffer buf
                                 (setq my/gemini-retry--timer nil)
                                 (message "[gemini-retry] Retrying in %s (attempt %d/%d)"
                                          (buffer-name buf)
                                          my/gemini-retry--count
                                          my/gemini-retry-max-attempts)
                                 (shell-maker-submit :input prompt)))))))))
            ;; Not retrying — reset state and call original handler
            (when (buffer-live-p shell-buffer)
              (with-current-buffer shell-buffer
                (when (> my/gemini-retry--count 0)
                  (message "[gemini-retry] Exhausted retries in %s after %d attempts"
                           (buffer-name) my/gemini-retry--count))
                (my/gemini-retry--reset)))
            (funcall original-handler acp-error raw-message))))))

  (advice-add 'agent-shell--make-error-handler :around
              #'my/gemini-retry--wrap-error-handler-a))

(message "[gemini-retry] Loaded")

(provide 'my-agent-shell-gemini-retry)
;;; my-agent-shell-gemini-retry.el ends here
