;;; my-agent-shell-stuck-busy-fixes.el --- Prevent agent-shell from getting stuck busy -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Fixes to prevent agent-shell from getting permanently stuck in
;; a busy state.  These are applied as advice and redefinitions in
;; `after!' blocks so they survive `straight' package updates.
;;
;; Fix 1: agent-shell-interrupt clears busy state after cancel
;; Fix 2: ACP process sentinel resolves pending requests on exit
;; Fix 3: Watchdog timer for max response duration
;; Fix 4: agent-shell-force-reset escape hatch command
;; Fix 5: Guard shell-maker--set-pm against nil process

;;; Code:

(message "agent-shell-team: stuck-busy-fixes loading...")

;; ---------------------------------------------------------------------------
;; Fix 1: agent-shell-interrupt — clear busy + stop heartbeat after cancel
;; ---------------------------------------------------------------------------

(after! agent-shell
  (defun my/agent-shell--cancel-pending-acp-requests ()
    "Remove all pending ACP requests for the current session.
Prevents stale on-success callbacks from firing after interrupt."
    (when-let* ((state (agent-shell--state))
                (client (map-elt state :client))
                (pending (map-elt client :pending-requests)))
      (let ((count (length pending)))
        (map-put! client :pending-requests nil)
        (when (> count 0)
          (message "[agent-shell-fix] Cleared %d pending ACP request(s)" count)))))

  (defun my/agent-shell-interrupt-clear-busy-a (&optional _force)
    "After advice: clear busy state when interrupt sends a cancel notification.
Only acts when a session is active (the cancel-notification path)."
    (when (map-nested-elt (agent-shell--state) '(:session :id))
      ;; Clear stale ACP pending requests FIRST to prevent
      ;; old on-success callbacks from firing after interrupt
      (my/agent-shell--cancel-pending-acp-requests)
      (agent-shell-heartbeat-stop
       :heartbeat (map-elt (agent-shell--state) :heartbeat))
      (shell-maker-finish-output :config shell-maker--config
                                 :success nil)))

  (advice-add 'agent-shell-interrupt :after #'my/agent-shell-interrupt-clear-busy-a))

;; ---------------------------------------------------------------------------
;; Fix 2: ACP process sentinel resolves pending requests on exit
;; ---------------------------------------------------------------------------

(after! acp
  (defun acp--start-client-with-sentinel-fix (orig-fn &rest args)
    "Around advice for `acp--start-client'.
Wraps the process sentinel to resolve pending requests before cleanup."
    (apply orig-fn args)
    ;; After the original runs, the process is stored on the client.
    ;; We replace its sentinel with one that first drains pending requests.
    (let* ((client (plist-get args :client))
           (process (map-elt client :process))
           (orig-sentinel (process-sentinel process)))
      (set-process-sentinel
       process
       (lambda (proc event)
         ;; Resolve all pending requests with failure before cleanup
         (let ((pending (map-elt client :pending-requests)))
           (dolist (entry pending)
             (when-let ((on-failure (map-elt (cdr entry) :on-failure)))
               (ignore-errors
                 (if (>= (cdr (func-arity on-failure)) 2)
                     (funcall on-failure
                              '((code . -1) (message . "ACP process exited unexpectedly"))
                              nil)
                   (funcall on-failure
                            '((code . -1) (message . "ACP process exited unexpectedly")))))))
           (map-put! client :pending-requests nil))
         ;; Call original sentinel
         (when orig-sentinel
           (funcall orig-sentinel proc event))))))

  (advice-add 'acp--start-client :around #'acp--start-client-with-sentinel-fix))

;; ---------------------------------------------------------------------------
;; Fix 3: Watchdog timer for max response duration
;; ---------------------------------------------------------------------------

(after! agent-shell
  (defcustom agent-shell-response-timeout 90
    "Maximum seconds to wait for an ACP response before timing out.
When non-nil, a watchdog timer is started when a prompt is sent.
If the response has not arrived within this many seconds the heartbeat
is stopped, the busy state is cleared, and an error message is inserted.
Set to nil to disable."
    :type '(choice (integer :tag "Timeout in seconds")
                   (const :tag "No timeout" nil))
    :group 'agent-shell)

  (defvar-local agent-shell--watchdog-timer nil
    "Timer that fires when `agent-shell-response-timeout' elapses.")

  (defun agent-shell--watchdog-cancel ()
    "Cancel the watchdog timer if it is running."
    (when (timerp agent-shell--watchdog-timer)
      (cancel-timer agent-shell--watchdog-timer))
    (setq agent-shell--watchdog-timer nil))

  (defun agent-shell--watchdog-start (shell-buffer)
    "Start the watchdog timer for SHELL-BUFFER.
The timer fires after `agent-shell-response-timeout' seconds."
    (agent-shell--watchdog-cancel)
    (when (and agent-shell-response-timeout
               (> agent-shell-response-timeout 0))
      (setq agent-shell--watchdog-timer
            (run-at-time agent-shell-response-timeout nil
                         #'agent-shell--watchdog-fire shell-buffer))))

  (defun agent-shell--watchdog-fire (shell-buffer)
    "Called when the watchdog timer expires for SHELL-BUFFER.
Stops the heartbeat, clears the busy state, and inserts an error message."
    (when (buffer-live-p shell-buffer)
      (with-current-buffer shell-buffer
        (setq agent-shell--watchdog-timer nil)
        (agent-shell-heartbeat-stop
         :heartbeat (map-elt agent-shell--state :heartbeat))
        (shell-maker-finish-output :config shell-maker--config
                                   :success nil)
        (message "[agent-shell] Timed out waiting for response after %ds"
                 agent-shell-response-timeout))))

  ;; Advice: start watchdog when sending a command
  (defun my/agent-shell-watchdog-start-a (fn &rest args)
    "Around advice on `agent-shell--send-command' to start the watchdog."
    (let ((shell-buffer (plist-get (car args) :shell-buffer)))
      (prog1 (apply fn args)
        (when shell-buffer
          (with-current-buffer shell-buffer
            (agent-shell--watchdog-start shell-buffer))))))

  (advice-add 'agent-shell--send-command :around #'my/agent-shell-watchdog-start-a)

  ;; Advice: cancel watchdog on heartbeat-stop (covers success, failure, shutdown)
  (defun my/agent-shell-watchdog-cancel-a (&rest _args)
    "Before advice: cancel the watchdog whenever the heartbeat stops."
    (agent-shell--watchdog-cancel))

  (advice-add 'agent-shell-heartbeat-stop :before #'my/agent-shell-watchdog-cancel-a))

;; ---------------------------------------------------------------------------
;; Fix 4: agent-shell-force-reset escape hatch command
;; ---------------------------------------------------------------------------

(after! agent-shell
  (defun agent-shell-force-reset ()
    "Unconditionally reset the shell from a stuck state.
This is an escape hatch for when everything else fails.  It stops
the heartbeat and watchdog timers, kills the ACP subprocess, clears
the busy flag, and writes a fresh prompt so the user can continue."
    (interactive)
    (unless (derived-mode-p 'agent-shell-mode)
      (error "Not in a shell"))
    ;; 1. Cancel watchdog timer
    (agent-shell--watchdog-cancel)
    ;; 2. Stop the heartbeat
    (agent-shell-heartbeat-stop
     :heartbeat (map-elt (agent-shell--state) :heartbeat))
    ;; 3. Kill the ACP subprocess
    (when (map-elt (agent-shell--state) :client)
      (acp-shutdown :client (map-elt (agent-shell--state) :client))
      (map-put! (agent-shell--state) :client nil)
      (map-put! (agent-shell--state) :initialized nil)
      (map-put! (agent-shell--state) :authenticated nil)
      (map-put! (agent-shell--state) :set-model nil)
      (map-put! (agent-shell--state) :set-session-mode nil))
    ;; 4. Clear busy state
    (setq shell-maker--busy nil)
    ;; 5. Write a new prompt so the user can continue
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (insert (propertize "\n[Force reset — session terminated]\n"
                          'font-lock-face 'font-lock-warning-face)))
    (comint-send-input)
    (shell-maker--output-filter
     (shell-maker--process)
     (concat "\n" (shell-maker-prompt shell-maker--config)))
    (message "[agent-shell] Force reset complete")))

;; ---------------------------------------------------------------------------
;; Fix 5: Guard shell-maker--set-pm against nil process
;; ---------------------------------------------------------------------------
;; During team agent initialization, messages can arrive before comint's
;; process is attached.  shell-maker--set-pm calls (process-mark proc)
;; where proc is nil, causing a "Wrong type argument: processp, nil" error.

(after! shell-maker
  (defun shell-maker--set-pm (pos)
    "Set the process mark in the current buffer to POS.
Guarded against nil process during initialization."
    (let ((proc (get-buffer-process
                 (shell-maker-buffer shell-maker--config))))
      (unless proc
        (message "agent-shell-team: shell-maker--set-pm called with nil process in %s"
                 (current-buffer)))
      (when proc
        (set-marker (process-mark proc) pos))))

  (defun shell-maker--pm ()
    "Return the process mark of the current buffer.
Guarded against nil process during initialization."
    (let ((proc (get-buffer-process
                 (shell-maker-buffer shell-maker--config))))
      (unless proc
        (message "agent-shell-team: shell-maker--pm called with nil process in %s"
                 (current-buffer)))
      (when proc
        (process-mark proc))))

  (defun shell-maker--process ()
    "Get shell buffer process.
Guarded against nil process during initialization."
    (let* ((buf (shell-maker-buffer shell-maker--config))
           (proc (get-buffer-process buf)))
      (unless proc
        (message "agent-shell-team: shell-maker--process returned nil in %s (resolved-buf=%s, current-buf=%s, override=%s, buf-name=%s)"
                 (current-buffer) buf (buffer-name) shell-maker--buffer-name-override
                 (when shell-maker--config (shell-maker-buffer-name shell-maker--config))))
      proc))

  ;; Wrap shell-maker--initialize to guard against nil process after start-process
  (defun my/shell-maker--initialize-guard-a (orig-fn config)
    "Around advice: catch processp nil errors during shell initialization."
    (condition-case err
        (funcall orig-fn config)
      (wrong-type-argument
       (message "agent-shell-team: shell-maker--initialize caught error: %S in buffer %s (process=%s)"
                err (current-buffer) (get-buffer-process (current-buffer)))
       ;; Try to recover: if process exists in current buffer, set things up
       (when-let ((proc (get-buffer-process (current-buffer))))
         (set-process-query-on-exit-flag proc nil)
         (goto-char (point-max))
         (setq-local comint-inhibit-carriage-motion t)
         (shell-maker--set-pm (point-max))
         (shell-maker--output-filter proc (shell-maker-prompt config))
         (when (shell-maker--pm)
           (set-marker comint-last-input-start (shell-maker--pm)))
         (set-process-filter proc 'shell-maker--output-filter)
         (set-buffer-modified-p nil)))))

  (advice-add 'shell-maker--initialize :around #'my/shell-maker--initialize-guard-a)

  (message "agent-shell-team: shell-maker--set-pm, --pm, --process all guarded"))

(message "agent-shell-team: stuck-busy-fixes loaded")

(provide 'my-agent-shell-stuck-busy-fixes)
;;; my-agent-shell-stuck-busy-fixes.el ends here
