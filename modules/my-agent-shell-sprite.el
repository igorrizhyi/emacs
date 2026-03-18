;;; my-agent-shell-sprite.el --- Animated sprite icon for lead agent-shell header -*- lexical-binding: t; -*-

;; Replace the default AI logo with animated sprite frames in the lead
;; buffer's graphical header.  Idle and busy states each have their own
;; sprite strip.  Frames are pre-read at load time; the existing 10 Hz
;; heartbeat drives busy animation, a lightweight idle timer handles
;; idle animation.

;;; Code:

(require 'cl-lib)

;;;; Configuration

(defvar my-agent-shell-sprite-dir
  (expand-file-name ".agent-shell/sprites/" doom-user-dir)
  "Directory containing sprite sub-directories (lead-idle/, lead-busy/).")

(defvar my-agent-shell-sprite-frame-divisor 3
  "How many heartbeat ticks to hold each busy frame.
With the 10 Hz heartbeat, divisor=3 means each frame shows for 300ms.")

;;;; Frame cache (populated once at load time)

(defvar my-agent-shell-sprite--idle-frames nil
  "Vector of file paths for lead-idle frames.")

(defvar my-agent-shell-sprite--busy-frames nil
  "Vector of file paths for lead-busy frames.")

(defvar my-agent-shell-sprite--pending-frames nil
  "Vector of file paths for lead-pending frames.")

(defun my-agent-shell-sprite--load-frames (subdir)
  "Load all frame-*.png paths from SUBDIR under `my-agent-shell-sprite-dir'.
Returns a vector of absolute file paths sorted by name."
  (let* ((dir (expand-file-name subdir my-agent-shell-sprite-dir))
         (files (and (file-directory-p dir)
                     (directory-files dir t "^frame-[0-9]+\\.png$" t))))
    (vconcat (sort files #'string<))))

(setq my-agent-shell-sprite--idle-frames
      (my-agent-shell-sprite--load-frames "lead-idle"))
(setq my-agent-shell-sprite--busy-frames
      (my-agent-shell-sprite--load-frames "lead-busy"))
(setq my-agent-shell-sprite--pending-frames
      (my-agent-shell-sprite--load-frames "lead-pending"))

;;;; Idle animation timer

(defvar my-agent-shell-sprite--idle-counter 0
  "Frame counter incremented by the idle animation timer.")

(defvar my-agent-shell-sprite--idle-timer nil
  "Repeating timer that drives idle sprite animation.")

(defun my-agent-shell-sprite--idle-tick ()
  "Increment idle counter and refresh header for lead buffers."
  (cl-incf my-agent-shell-sprite--idle-counter)
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (my-agent-shell-sprite--lead-buffer-p)
          (force-mode-line-update))))))

(defun my-agent-shell-sprite--ensure-idle-timer ()
  "Start the idle timer if not already running."
  (unless my-agent-shell-sprite--idle-timer
    (setq my-agent-shell-sprite--idle-timer
          (run-with-timer 0.3 0.3 #'my-agent-shell-sprite--idle-tick))))

(defun my-agent-shell-sprite--stop-idle-timer ()
  "Stop the idle timer if running."
  (when my-agent-shell-sprite--idle-timer
    (cancel-timer my-agent-shell-sprite--idle-timer)
    (setq my-agent-shell-sprite--idle-timer nil)))

;;;; Helpers

(defun my-agent-shell-sprite--lead-buffer-p ()
  "Return non-nil if the current buffer is a lead agent-shell buffer."
  (and (bound-and-true-p agent-shell-team--role)
       (equal agent-shell-team--role "lead")))

(defun my-agent-shell-sprite--heartbeat-value ()
  "Return the current heartbeat counter, or 0."
  (condition-case nil
      (or (map-nested-elt (agent-shell--state) '(:heartbeat :value)) 0)
    (error 0)))

(defun my-agent-shell-sprite--busy-p ()
  "Return non-nil if the current agent-shell is busy."
  (condition-case nil
      (eq 'busy (map-nested-elt (agent-shell--state) '(:heartbeat :status)))
    (error nil)))

(defun my-agent-shell-sprite--pending-p ()
  "Return non-nil if the current buffer has deferred messages waiting."
  (and (bound-and-true-p agent-shell-team--message-queue)
       (gethash (current-buffer) agent-shell-team--message-queue)))

(defun my-agent-shell-sprite--current-frame-path ()
  "Return the file path of the current sprite frame for a lead buffer, or nil."
  (when (my-agent-shell-sprite--lead-buffer-p)
    (let* ((busy (my-agent-shell-sprite--busy-p))
           (frames (cond (busy my-agent-shell-sprite--busy-frames)
                         ((my-agent-shell-sprite--pending-p)
                          my-agent-shell-sprite--pending-frames)
                         (t my-agent-shell-sprite--idle-frames)))
           (n (length frames)))
      ;; Manage idle timer: run when not busy (covers both pending and idle),
      ;; stop when busy (heartbeat takes over)
      (if busy
          (my-agent-shell-sprite--stop-idle-timer)
        (my-agent-shell-sprite--ensure-idle-timer))
      (when (> n 0)
        (let ((idx (if busy
                       (/ (my-agent-shell-sprite--heartbeat-value)
                          my-agent-shell-sprite-frame-divisor)
                     my-agent-shell-sprite--idle-counter)))
          (aref frames (mod idx n)))))))

;;;; Advice: replace icon for lead buffers

(defun my-agent-shell-sprite--icon-advice (orig-fn icon-name)
  "Around advice for `agent-shell--fetch-agent-icon'.
For lead buffers, return the current sprite frame path instead of
downloading the default AI logo.  For all other buffers, delegate
to ORIG-FN with ICON-NAME."
  (or (my-agent-shell-sprite--current-frame-path)
      (funcall orig-fn icon-name)))

(advice-add 'agent-shell--fetch-agent-icon
            :around #'my-agent-shell-sprite--icon-advice)

;;;; Advice: inject sprite frame index into header model for cache busting
;;
;; The header cache key is derived from all values in the header model.
;; The busy-indicator-frame is only non-nil when busy, so idle-state
;; animation would get a stale cached header.  We add a :sprite-frame
;; entry so the cache key changes every tick for lead buffers.

(defun my-agent-shell-sprite--header-model-advice (orig-fn &rest args)
  "Around advice for `agent-shell--make-header-model'.
Appends a :sprite-frame entry to the model for lead buffers so the
header cache key changes on each animation frame."
  (let ((model (apply orig-fn args)))
    (when (my-agent-shell-sprite--lead-buffer-p)
      (let* ((busy (my-agent-shell-sprite--busy-p))
             (pending (my-agent-shell-sprite--pending-p))
             (frame-idx (if busy
                            (/ (my-agent-shell-sprite--heartbeat-value)
                               my-agent-shell-sprite-frame-divisor)
                          my-agent-shell-sprite--idle-counter)))
        (setq model (append model
                            `((:sprite-frame . ,frame-idx)
                              (:sprite-pending . ,pending))))))
    model))

(advice-add 'agent-shell--make-header-model
            :around #'my-agent-shell-sprite--header-model-advice)

(provide 'my-agent-shell-sprite)
;;; my-agent-shell-sprite.el ends here
