;;; my-smart-autosave.el --- Smart auto-save that respects Evil mode -*- lexical-binding: t; -*-

;;; Commentary:
;; Smart auto-save module that:
;; - Only saves when NOT in insert mode (Evil)
;; - Has configurable delay after last change
;; - Respects buffer state and file permissions
;; - Can be easily enabled/disabled

;;; Code:

(defgroup my-smart-autosave nil
  "Smart auto-save configuration."
  :group 'files
  :prefix "my-smart-autosave-")

(defcustom my-smart-autosave-delay 3
  "Seconds to wait after last change before auto-saving."
  :type 'number
  :group 'my-smart-autosave)

(defcustom my-smart-autosave-enabled t
  "Whether smart auto-save is enabled."
  :type 'boolean
  :group 'my-smart-autosave)

(defcustom my-smart-autosave-exclude-modes '(minibuffer-mode)
  "Major modes to exclude from auto-saving."
  :type '(repeat symbol)
  :group 'my-smart-autosave)

(defvar my-smart-autosave--timer nil
  "Timer for delayed auto-save.")

(defvar my-smart-autosave--last-change-time nil
  "Time of last buffer change.")

(defun my-smart-autosave--should-save-p ()
  "Check if current buffer should be auto-saved."
  (and my-smart-autosave-enabled
       ;; Buffer is modified
       (buffer-modified-p)
       ;; Buffer is visiting a file
       (buffer-file-name)
       ;; File is writable
       (file-writable-p (buffer-file-name))
       ;; Not in excluded modes
       (not (apply #'derived-mode-p my-smart-autosave-exclude-modes))
       ;; Not in Evil insert mode (if Evil is available)
       (if (bound-and-true-p evil-mode)
           (not (eq evil-state 'insert))
         t)
       ;; Not currently in minibuffer
       (not (minibufferp))))

(defun my-smart-autosave--save-buffer ()
  "Save current buffer if conditions are met."
  (when (my-smart-autosave--should-save-p)
    (condition-case err
        (progn
          (save-buffer)
          (message "Smart auto-saved: %s" (buffer-name)))
      (error
       (message "Smart auto-save failed: %s" (error-message-string err))))))

(defun my-smart-autosave--schedule-save ()
  "Schedule an auto-save after the configured delay."
  (when my-smart-autosave--timer
    (cancel-timer my-smart-autosave--timer))
  
  (setq my-smart-autosave--last-change-time (current-time))
  
  (setq my-smart-autosave--timer
        (run-with-timer my-smart-autosave-delay nil
                        (lambda ()
                          ;; Double-check we should still save
                          (when (and (my-smart-autosave--should-save-p)
                                     ;; Ensure we're not in insert mode NOW
                                     (if (bound-and-true-p evil-mode)
                                         (not (eq evil-state 'insert))
                                       t))
                            (my-smart-autosave--save-buffer))))))

(defun my-smart-autosave--on-change (&rest _args)
  "Hook function called when buffer changes."
  (when (and my-smart-autosave-enabled
             (not (minibufferp)))
    (my-smart-autosave--schedule-save)))

(defun my-smart-autosave--cancel-timer ()
  "Cancel any pending auto-save timer."
  (when my-smart-autosave--timer
    (cancel-timer my-smart-autosave--timer)
    (setq my-smart-autosave--timer nil)))

(defun my-smart-autosave--schedule-on-normal ()
  "Schedule save when entering normal mode if buffer is modified."
  (when (and my-smart-autosave-enabled
             (buffer-modified-p)
             (buffer-file-name)
             (not (minibufferp)))
    (my-smart-autosave--schedule-save)))

(defun my-smart-autosave--check-after-command ()
  "Check if we should schedule a save after a command in normal mode."
  (when (and my-smart-autosave-enabled
             (bound-and-true-p evil-mode)
             (eq evil-state 'normal)
             (buffer-modified-p)
             (buffer-file-name)
             (not (minibufferp))
             ;; Only trigger for commands that likely changed the buffer
             (or (eq this-command 'evil-delete-line)
                 (eq this-command 'evil-delete)
                 (eq this-command 'evil-change)
                 (eq this-command 'evil-substitute)
                 (eq this-command 'evil-paste-after)
                 (eq this-command 'evil-paste-before)
                 (eq this-command 'evil-yank)
                 (and this-command
                      (string-match-p "^evil-\(delete\|change\|substitute\|paste\)" 
                                      (symbol-name this-command)))))
    (my-smart-autosave--schedule-save)))

(defvar my-smart-autosave--previous-buffer nil
  "Track the previous buffer to detect buffer switches.")

(defun my-smart-autosave--on-buffer-change ()
  "Save previous buffer when switching buffers."
  (when (and my-smart-autosave-enabled
             my-smart-autosave--previous-buffer
             (buffer-live-p my-smart-autosave--previous-buffer)
             (not (eq my-smart-autosave--previous-buffer (current-buffer))))
    (with-current-buffer my-smart-autosave--previous-buffer
      (when (and (buffer-modified-p)
                 (buffer-file-name)
                 (file-writable-p (buffer-file-name))
                 (not (minibufferp))
                 ;; Only save if not in insert mode
                 (if (bound-and-true-p evil-mode)
                     (not (eq evil-state 'insert))
                   t))
        (condition-case err
            (progn
              (save-buffer)
              (message "Auto-saved on buffer switch: %s" (buffer-name)))
          (error
           (message "Auto-save failed on buffer switch: %s" (error-message-string err)))))))
  ;; Update previous buffer
  (setq my-smart-autosave--previous-buffer (current-buffer)))

(defun my-smart-autosave--on-window-change (&optional frame)
  "Save buffer when window selection changes."
  (when my-smart-autosave-enabled
    (let ((current-buf (current-buffer)))
      (when (and current-buf
                 (buffer-live-p current-buf)
                 my-smart-autosave--previous-buffer
                 (not (eq current-buf my-smart-autosave--previous-buffer)))
        (my-smart-autosave--on-buffer-change)))))

;;;###autoload
(defun my-smart-autosave-toggle ()
  "Toggle smart auto-save on/off."
  (interactive)
  (setq my-smart-autosave-enabled (not my-smart-autosave-enabled))
  (if my-smart-autosave-enabled
      (message "Smart auto-save enabled")
    (progn
      (my-smart-autosave--cancel-timer)
      (message "Smart auto-save disabled"))))

;;;###autoload
(defun my-smart-autosave-save-now ()
  "Force save current buffer if conditions are met."
  (interactive)
  (if (my-smart-autosave--should-save-p)
      (my-smart-autosave--save-buffer)
    (message "Smart auto-save: conditions not met for saving")))

;;;###autoload
(define-minor-mode my-smart-autosave-mode
  "Smart auto-save mode that respects Evil states."
  :lighter " SmartSave"
  :global nil
  (if my-smart-autosave-mode
      (progn
        ;; Enable hooks
        (add-hook 'after-change-functions #'my-smart-autosave--on-change nil t)
        ;; Buffer focus change hooks
        (add-hook 'buffer-list-update-hook #'my-smart-autosave--on-buffer-change nil t)
        (add-hook 'window-selection-change-functions #'my-smart-autosave--on-window-change nil t)
        ;; Initialize buffer tracking
        (setq my-smart-autosave--previous-buffer (current-buffer))
        ;; Cancel timer when entering insert mode (if Evil is available)
        (when (bound-and-true-p evil-mode)
          (add-hook 'evil-insert-state-entry-hook #'my-smart-autosave--cancel-timer nil t)
          ;; Also hook into Evil normal state operations
          (add-hook 'evil-normal-state-entry-hook #'my-smart-autosave--schedule-on-normal nil t)
          (add-hook 'post-command-hook #'my-smart-autosave--check-after-command nil t))
        (message "Smart auto-save mode enabled in %s" (buffer-name)))
    (progn
      ;; Disable hooks
      (remove-hook 'after-change-functions #'my-smart-autosave--on-change t)
      ;; Remove buffer focus change hooks
      (remove-hook 'buffer-list-update-hook #'my-smart-autosave--on-buffer-change t)
      (remove-hook 'window-selection-change-functions #'my-smart-autosave--on-window-change t)
      (when (bound-and-true-p evil-mode)
        (remove-hook 'evil-insert-state-entry-hook #'my-smart-autosave--cancel-timer t)
        (remove-hook 'evil-normal-state-entry-hook #'my-smart-autosave--schedule-on-normal t)
        (remove-hook 'post-command-hook #'my-smart-autosave--check-after-command t))
      ;; Cancel any pending timer
      (my-smart-autosave--cancel-timer)
      (message "Smart auto-save mode disabled in %s" (buffer-name)))))

;;;###autoload
(define-globalized-minor-mode my-smart-autosave-global-mode
  my-smart-autosave-mode
  (lambda ()
    ;; Enable for file-visiting buffers only
    (when (and (buffer-file-name)
               (not (minibufferp)))
      (my-smart-autosave-mode 1)))
  :group 'my-smart-autosave)

;; Status function for debugging
;;;###autoload
(defun my-smart-autosave-status ()
  "Show current smart auto-save status."
  (interactive)
  (message "Smart auto-save: %s | Mode: %s | Evil state: %s | Timer: %s | Should save: %s"
           (if my-smart-autosave-enabled "enabled" "disabled")
           (if my-smart-autosave-mode "on" "off")
           (if (bound-and-true-p evil-mode) evil-state "N/A")
           (if my-smart-autosave--timer "active" "none")
           (if (my-smart-autosave--should-save-p) "yes" "no")))

(provide 'my-smart-autosave)
;;; my-smart-autosave.el ends here