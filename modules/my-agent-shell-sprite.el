;;; my-agent-shell-sprite.el --- Animated sprite icon for lead agent-shell header -*- lexical-binding: t; -*-

;; Replace the default AI logo with animated sprite frames in the lead
;; buffer's graphical header.  A single persistent timer (~300ms) drives
;; all animation states (idle, busy, pending) via a simple state machine.
;; Frames are pre-read at load time.

;;; Code:

(require 'cl-lib)

;;;; Configuration

(defvar my-agent-shell-sprite-dir
  (expand-file-name ".agent-shell/sprites/" doom-user-dir)
  "Directory containing sprite sub-directories (lead-idle/, lead-busy/).")

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

;;;; State machine

(defvar my-agent-shell-sprite--timer nil
  "Single persistent timer driving all sprite animation.")

(defvar my-agent-shell-sprite--frame-counter 0
  "Global frame counter incremented every tick.")

(defvar my-agent-shell-sprite--current-state 'idle
  "Current sprite state: idle, busy, or pending.")

(defun my-agent-shell-sprite--detect-state ()
  "Return current state: busy, pending, or idle.
During initialization, always return idle to avoid showing busy frames
before the agent is ready."
  (cond
   ((not (bound-and-true-p agent-shell-team--init-finished-p)) 'idle)
   ((my-agent-shell-sprite--busy-p) 'busy)
   ((my-agent-shell-sprite--pending-p) 'pending)
   (t 'idle)))

(defun my-agent-shell-sprite--tick ()
  "Main animation tick.  Runs every 300ms.
Iterates lead buffers, updates state, increments frame counter,
and refreshes the header.  Auto-stops when no lead buffer exists."
  (let ((found-lead nil))
    (dolist (buf (buffer-list))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (my-agent-shell-sprite--lead-buffer-p)
            (setq found-lead t)
            (setq my-agent-shell-sprite--current-state
                  (my-agent-shell-sprite--detect-state))
            (cl-incf my-agent-shell-sprite--frame-counter)
            (condition-case err
                (agent-shell--update-header-and-mode-line)
              (error
               (message "sprite tick: header update error: %S" err)))))))
    (unless found-lead
      (my-agent-shell-sprite--stop-timer))))

(defun my-agent-shell-sprite--ensure-timer ()
  "Start the animation timer if not already running."
  (unless my-agent-shell-sprite--timer
    (setq my-agent-shell-sprite--timer
          (run-with-timer 0.3 0.3 #'my-agent-shell-sprite--tick))))

(defun my-agent-shell-sprite--stop-timer ()
  "Stop the animation timer if running."
  (when my-agent-shell-sprite--timer
    (cancel-timer my-agent-shell-sprite--timer)
    (setq my-agent-shell-sprite--timer nil)))

;;;; Helpers

(defun my-agent-shell-sprite--lead-buffer-p ()
  "Return non-nil if the current buffer is a lead agent-shell buffer."
  (and (bound-and-true-p agent-shell-team--role)
       (equal agent-shell-team--role "lead")))

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
    (my-agent-shell-sprite--ensure-timer)
    (let* ((frames (pcase my-agent-shell-sprite--current-state
                     ('busy my-agent-shell-sprite--busy-frames)
                     ('pending my-agent-shell-sprite--pending-frames)
                     (_ my-agent-shell-sprite--idle-frames)))
           (n (length frames)))
      (when (> n 0)
        (aref frames (mod my-agent-shell-sprite--frame-counter n))))))

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
;; We add :sprite-frame and :sprite-state entries so the cache key
;; changes every tick for lead buffers.

(defun my-agent-shell-sprite--header-model-advice (orig-fn &rest args)
  "Around advice for `agent-shell--make-header-model'.
Appends :sprite-frame and :sprite-state entries to the model for lead
buffers so the header cache key changes on each animation frame."
  (let ((model (apply orig-fn args)))
    (when (my-agent-shell-sprite--lead-buffer-p)
      (setq model (append model
                          `((:sprite-frame . ,my-agent-shell-sprite--frame-counter)
                            (:sprite-state . ,my-agent-shell-sprite--current-state)))))
    model))

(advice-add 'agent-shell--make-header-model
            :around #'my-agent-shell-sprite--header-model-advice)

(provide 'my-agent-shell-sprite)
;;; my-agent-shell-sprite.el ends here
