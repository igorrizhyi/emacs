;;; my-jump-animation.el --- Jump animation for Emacs with overlay integration -*- lexical-binding: t; -*-

;; Author: Igor Rizhyi
;; Description: Detect cursor jumps within files and send WebSocket messages to overlay app
;; Based on VSCode jump animation extension

;;; Commentary:
;; This module detects significant cursor movements within a single file and sends
;; animation commands to an external overlay application via WebSocket.
;; Only triggers on jumps > 5 lines within the same file.

;;; Code:

(require 'websocket)

;;; Custom variables

(defgroup my-jump-animation nil
  "Jump animation settings."
  :group 'convenience
  :prefix "my-jump-animation-")

(defcustom my-jump-animation-websocket-port 8765
  "Port for WebSocket connection to overlay app."
  :type 'integer
  :group 'my-jump-animation)

(defcustom my-jump-animation-min-jump-lines 5
  "Minimum number of lines to trigger jump animation."
  :type 'integer
  :group 'my-jump-animation)

(defcustom my-jump-animation-color "#4ecdc4"
  "Color for jump animations."
  :type 'string
  :group 'my-jump-animation)

(defcustom my-jump-animation-debug nil
  "Enable debug logging."
  :type 'boolean
  :group 'my-jump-animation)

;;; Internal variables

(defvar my-jump-animation--last-line 0
  "Last recorded line number.")

(defvar my-jump-animation--last-file-path ""
  "Last recorded file path.")

(defvar my-jump-animation--ignore-next-jump nil
  "Flag to ignore the next jump (after file change).")

(defvar my-jump-animation--websocket nil
  "WebSocket connection to overlay app.")

(defvar my-jump-animation--connection-attempts 0
  "Number of connection attempts made.")

(defvar my-jump-animation--max-connection-attempts 3
  "Maximum number of connection attempts before giving up.")

(defvar my-jump-animation--reconnect-timer nil
  "Timer for reconnection attempts.")

;;; Logging

(defun my-jump-animation--log (message &rest args)
  "Log MESSAGE with ARGS if debug is enabled."
  (when my-jump-animation-debug
    (let ((timestamp (format-time-string "[%H:%M:%S]")))
      (message "%s [Jump Animation] %s" timestamp (apply #'format message args)))))

;;; WebSocket functions

(defun my-jump-animation--connect-websocket ()
  "Connect to the overlay WebSocket server."
  (when my-jump-animation--reconnect-timer
    (cancel-timer my-jump-animation--reconnect-timer)
    (setq my-jump-animation--reconnect-timer nil))
  
  (my-jump-animation--log "🔌 Connecting to overlay WebSocket on port %d..." my-jump-animation-websocket-port)
  
  (condition-case err
      (setq my-jump-animation--websocket
            (websocket-open
             (format "ws://localhost:%d" my-jump-animation-websocket-port)
             :on-open (lambda (_websocket)
                        (my-jump-animation--log "✅ Connected to overlay WebSocket!")
                        (setq my-jump-animation--connection-attempts 0)
                        (my-jump-animation--send-message '((type . "ping") 
                                                           (message . "Emacs extension connected"))))
             :on-message (lambda (_websocket frame)
                           (let ((message (json-parse-string (websocket-frame-text frame))))
                             (my-jump-animation--log "📨 Received: %s" message)))
             :on-close (lambda (_websocket)
                         (my-jump-animation--log "🔌 WebSocket connection closed")
                         (setq my-jump-animation--websocket nil)
                         (my-jump-animation--schedule-reconnect))
             :on-error (lambda (_websocket type error)
                         (my-jump-animation--log "❌ WebSocket error (%s): %s" type error)
                         (setq my-jump-animation--websocket nil)
                         (my-jump-animation--schedule-reconnect))))
    (error
     (my-jump-animation--log "❌ Failed to connect to WebSocket: %s" (error-message-string err))
     (my-jump-animation--schedule-reconnect))))

(defun my-jump-animation--schedule-reconnect ()
  "Schedule a reconnection attempt."
  (when (< my-jump-animation--connection-attempts my-jump-animation--max-connection-attempts)
    (cl-incf my-jump-animation--connection-attempts)
    (my-jump-animation--log "🔄 Scheduling reconnect attempt %d/%d in 5 seconds..."
                            my-jump-animation--connection-attempts
                            my-jump-animation--max-connection-attempts)
    (setq my-jump-animation--reconnect-timer
          (run-at-time 5 nil #'my-jump-animation--connect-websocket))))

(defun my-jump-animation--send-message (message)
  "Send MESSAGE to overlay via WebSocket asynchronously."
  (when (and my-jump-animation--websocket
             (websocket-openp my-jump-animation--websocket))
    ;; Use run-at-time with 0 delay to send message asynchronously
    (run-at-time 0 nil
                 (lambda ()
                   (condition-case err
                       (when (and my-jump-animation--websocket
                                  (websocket-openp my-jump-animation--websocket))
                         (websocket-send-text my-jump-animation--websocket (json-encode message))
                         (my-jump-animation--log "📤 Sent message asynchronously"))
                     (error
                      (my-jump-animation--log "❌ Failed to send message: %s" (error-message-string err))))))
    t))

;;; Jump detection functions

(defun my-jump-animation--update-tracker ()
  "Update the jump tracker with current position."
  (when (buffer-file-name)
    (setq my-jump-animation--last-line (line-number-at-pos)
          my-jump-animation--last-file-path (buffer-file-name))))

(defun my-jump-animation--handle-cursor-movement ()
  "Handle cursor movement and detect jumps."
  (when (and (buffer-file-name)
             (not (minibufferp)))
    (let ((current-line (line-number-at-pos))
          (current-file (buffer-file-name)))
      
      (my-jump-animation--log "📊 Cursor movement: %s line %d (last: %s line %d, ignore: %s)"
                              current-file current-line
                              my-jump-animation--last-file-path
                              my-jump-animation--last-line
                              my-jump-animation--ignore-next-jump)
      
      ;; Initialize on first run
      (cond
       ((and (= my-jump-animation--last-line 0)
             (string-empty-p my-jump-animation--last-file-path))
        (my-jump-animation--log "📍 First position - initializing tracker")
        (my-jump-animation--update-tracker))
       
       ;; Check if we should ignore this jump (after file change)
       (my-jump-animation--ignore-next-jump
        (my-jump-animation--log "🚫 Ignoring jump after file change")
        (setq my-jump-animation--ignore-next-jump nil)
        (my-jump-animation--update-tracker))
       
       ;; Check for file change
       ((not (string= current-file my-jump-animation--last-file-path))
        (my-jump-animation--log "🚫 File change detected: %s -> %s"
                                my-jump-animation--last-file-path current-file)
        (setq my-jump-animation--ignore-next-jump t)
        (my-jump-animation--update-tracker))
       
       ;; Calculate line difference for jumps within same file
       (t
        (let ((line-diff (- current-line my-jump-animation--last-line)))
          (if (> (abs line-diff) my-jump-animation-min-jump-lines)
              (let ((direction (if (> line-diff 0) "down" "up")))
                (my-jump-animation--log "✅ Jump detected: line %d -> %d (%s, %d lines)"
                                        my-jump-animation--last-line current-line
                                        direction (abs line-diff))
                (my-jump-animation--show-animation direction (abs line-diff)))
            (my-jump-animation--log "⚪ Small movement ignored: %d lines" (abs line-diff)))
          (my-jump-animation--update-tracker)))))))

(defun my-jump-animation--show-animation (direction lines)
  "Show jump animation in DIRECTION for LINES."
  (let* ((intensity (min (floor (/ lines 10.0)) 10))
         (msg `((type . "jump")
                (direction . ,direction)
                (intensity . ,intensity)
                (color . ,my-jump-animation-color)
                (lines . ,lines)
                (timestamp . ,(floor (* (float-time) 1000))))))
    
    (when (my-jump-animation--send-message msg)
      (my-jump-animation--log "🎬 Sent %s animation (%d lines) to overlay" direction lines))))

;;; Hook functions

(defun my-jump-animation--post-command-hook ()
  "Post-command hook to detect cursor movements."
  ;; Skip basic evil movements to avoid processing noise
  (unless (memq this-command '(evil-next-line evil-previous-line
                              evil-forward-char evil-backward-char
                              next-line previous-line
                              forward-char backward-char))
    ;; Only run for commands that can cause significant jumps
    (when (or (memq this-command '(goto-line
                                  evil-goto-line evil-goto-first-line
                                  evil-goto-last-line evil-jump-backward
                                  evil-jump-forward beginning-of-buffer
                                  end-of-buffer scroll-up-command
                                  scroll-down-command evil-scroll-up
                                  evil-scroll-down evil-scroll-page-up
                                  evil-scroll-page-down evil-goto-mark
                                  evil-goto-mark-line consult-line
                                  consult-goto-line swiper swiper-isearch
                                  isearch-forward isearch-backward
                                  evil-search-next evil-search-previous
                                  evil-ex-search-next evil-ex-search-previous))
              ;; Also trigger on significant point changes (for other navigation)
              (and my-jump-animation--last-line
                   (> (abs (- (line-number-at-pos) my-jump-animation--last-line)) 
                      my-jump-animation-min-jump-lines)))
      (my-jump-animation--handle-cursor-movement))))

;;; Public functions

(defun my-jump-animation-test-animation (&optional direction lines)
  "Test jump animation with optional DIRECTION and LINES."
  (interactive)
  (let ((test-direction (or direction (if (> (random 2) 0) "down" "up")))
        (test-lines (or lines (+ 5 (random 20)))))
    (my-jump-animation--show-animation test-direction test-lines)
    (message "🎨 Test %s animation (%d lines)" test-direction test-lines)))

(defun my-jump-animation-reconnect ()
  "Manually reconnect to overlay WebSocket."
  (interactive)
  (when my-jump-animation--websocket
    (websocket-close my-jump-animation--websocket))
  (setq my-jump-animation--websocket nil
        my-jump-animation--connection-attempts 0)
  (my-jump-animation--connect-websocket))

(defun my-jump-animation-status ()
  "Show current jump animation status."
  (interactive)
  (let ((connected (and my-jump-animation--websocket
                        (websocket-openp my-jump-animation--websocket))))
    (message "Jump Animation - WebSocket: %s, Last pos: %s:%d"
             (if connected "Connected" "Disconnected")
             (file-name-nondirectory my-jump-animation--last-file-path)
             my-jump-animation--last-line)))

;;; Minor mode definition

;;;###autoload
(define-minor-mode my-jump-animation-mode
  "Minor mode for jump animation with overlay integration."
  :global t
  :lighter " JumpAnim"
  :group 'my-jump-animation
  (if my-jump-animation-mode
      (progn
        (my-jump-animation--log "🚀 Jump Animation mode enabled!")
        (add-hook 'post-command-hook #'my-jump-animation--post-command-hook)
        (my-jump-animation--connect-websocket)
        ;; Initialize tracker with current position
        (my-jump-animation--update-tracker))
    (progn
      (my-jump-animation--log "🛑 Jump Animation mode disabled")
      (remove-hook 'post-command-hook #'my-jump-animation--post-command-hook)
      (when my-jump-animation--reconnect-timer
        (cancel-timer my-jump-animation--reconnect-timer)
        (setq my-jump-animation--reconnect-timer nil))
      (when my-jump-animation--websocket
        (websocket-close my-jump-animation--websocket)
        (setq my-jump-animation--websocket nil)))))

;;; Key bindings

(defvar my-jump-animation-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c j t") #'my-jump-animation-test-animation)
    (define-key map (kbd "C-c j r") #'my-jump-animation-reconnect)
    (define-key map (kbd "C-c j s") #'my-jump-animation-status)
    map)
  "Keymap for jump animation mode.")

(provide 'my-jump-animation)
;;; my-jump-animation.el ends here