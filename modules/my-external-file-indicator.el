;;; my-external-file-indicator.el --- Visual indicator for external package files -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides visual indication for files that come from external packages
;; (like venv, node_modules, .git, etc.) by changing their background color.
;; This helps distinguish between project files and external dependencies.

;;; Code:

(require 'cl-lib)

;;; Configuration Variables

(defgroup my-external-file-indicator nil
  "Visual indicator for external package files."
  :group 'files
  :prefix "my-external-file-indicator-")

(defcustom my-external-file-indicator-background "#2a1810"
  "Background color for external package files."
  :type 'string
  :group 'my-external-file-indicator)

(defcustom my-external-file-indicator-patterns
  '("/\\.venv/"
    "/venv/"
    "/node_modules/"
    "/\\.git/"
    "/\\.cache/"
    "/\\.npm/"
    "/\\.yarn/"
    "/site-packages/"
    "/dist-packages/"
    "/lib/python"
    "/\\.local/lib/"
    "/usr/lib/"
    "/usr/share/"
    "/opt/"
    "/\\.cargo/registry/"
    "/\\.rustup/"
    "/target/debug/"
    "/target/release/"
    "/vendor/"
    "/\\.gradle/"
    "/\\.m2/repository/"
    "/\\.nuget/")
  "List of regex patterns to match external package file paths."
  :type '(repeat string)
  :group 'my-external-file-indicator)

(defcustom my-external-file-indicator-enabled t
  "Whether to enable external file indication."
  :type 'boolean
  :group 'my-external-file-indicator)

;;; Internal Variables

(defvar my-external-file-indicator--overlays (make-hash-table :test 'equal)
  "Hash table mapping buffers to their background overlays.")

;;; Core Functions

(defun my-external-file-indicator--is-external-file-p (file-path)
  "Check if FILE-PATH is from an external package."
  (when (and file-path (stringp file-path))
    (cl-some (lambda (pattern)
               (string-match-p pattern file-path))
             my-external-file-indicator-patterns)))

(defun my-external-file-indicator--apply-background (buffer)
  "Apply external file background to BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      ;; Remove any existing background first
      (my-external-file-indicator--remove-background buffer)
      
      ;; Set buffer-local background face to cover entire window including empty space
      (face-remap-add-relative 'default :background my-external-file-indicator-background)
      
      ;; Mark buffer as having external background
      (puthash buffer t my-external-file-indicator--overlays))))

(defun my-external-file-indicator--remove-background (buffer)
  "Remove external file background from BUFFER."
  (when (buffer-live-p buffer)
    (let ((has-background (gethash buffer my-external-file-indicator--overlays)))
      (when has-background
        (with-current-buffer buffer
          ;; Reset face remapping to remove custom background
          (face-remap-reset-base 'default))
        (remhash buffer my-external-file-indicator--overlays)))))


(defun my-external-file-indicator--check-and-apply (buffer)
  "Check if BUFFER is an external file and apply background if needed."
  (when (and my-external-file-indicator-enabled
             (buffer-live-p buffer))
    (let ((file-path (buffer-file-name buffer)))
      (if (my-external-file-indicator--is-external-file-p file-path)
          (my-external-file-indicator--apply-background buffer)
        (my-external-file-indicator--remove-background buffer)))))

;;; Hook Functions

(defun my-external-file-indicator--on-find-file ()
  "Hook function for when a file is opened."
  (my-external-file-indicator--check-and-apply (current-buffer)))


(defun my-external-file-indicator--cleanup-dead-buffers ()
  "Clean up background settings for dead buffers."
  (maphash (lambda (buffer has-background)
             (unless (buffer-live-p buffer)
               (remhash buffer my-external-file-indicator--overlays)))
           my-external-file-indicator--overlays))

;;; Public API

;;;###autoload
(defun my-external-file-indicator-refresh ()
  "Refresh external file indication for all buffers."
  (interactive)
  (my-external-file-indicator--cleanup-dead-buffers)
  (dolist (buffer (buffer-list))
    (my-external-file-indicator--check-and-apply buffer))
  (message "External file indicators refreshed"))

;;;###autoload
(defun my-external-file-indicator-toggle ()
  "Toggle external file indication on/off."
  (interactive)
  (setq my-external-file-indicator-enabled 
        (not my-external-file-indicator-enabled))
  (if my-external-file-indicator-enabled
      (progn
        (my-external-file-indicator-refresh)
        (message "External file indication enabled"))
    (progn
      ;; Remove all overlays
      (maphash (lambda (buffer overlay)
                 (when overlay (delete-overlay overlay)))
               my-external-file-indicator--overlays)
      (clrhash my-external-file-indicator--overlays)
      (message "External file indication disabled"))))

;;;###autoload
(defun my-external-file-indicator-add-pattern (pattern)
  "Add a new PATTERN to detect external files."
  (interactive "sEnter pattern (regex): ")
  (unless (member pattern my-external-file-indicator-patterns)
    (push pattern my-external-file-indicator-patterns)
    (my-external-file-indicator-refresh)
    (message "Added pattern: %s" pattern)))

;;;###autoload
(defun my-external-file-indicator-set-background-color (color)
  "Set the background COLOR for external files."
  (interactive "sEnter background color (hex): ")
  (setq my-external-file-indicator-background color)
  (my-external-file-indicator-refresh)
  (message "Background color set to: %s" color))

;;; Mode Definition

;;;###autoload
(define-minor-mode my-external-file-indicator-mode
  "Minor mode for indicating external package files with background color."
  :global t
  :lighter " ExtFile"
  :group 'my-external-file-indicator
  (if my-external-file-indicator-mode
      (progn
        ;; Enable hooks
        (add-hook 'find-file-hook #'my-external-file-indicator--on-find-file)
        (add-hook 'kill-buffer-hook #'my-external-file-indicator--cleanup-dead-buffers)
        
        ;; Apply to existing buffers
        (my-external-file-indicator-refresh)
        
        (message "External file indicator mode enabled"))
    (progn
      ;; Disable hooks
      (remove-hook 'find-file-hook #'my-external-file-indicator--on-find-file)
      (remove-hook 'kill-buffer-hook #'my-external-file-indicator--cleanup-dead-buffers)
      
      ;; Clean up all face remappings
      (maphash (lambda (buffer has-background)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (face-remap-reset-base 'default))))
               my-external-file-indicator--overlays)
      (clrhash my-external-file-indicator--overlays)
      
      (message "External file indicator mode disabled"))))

(provide 'my-external-file-indicator)

;;; my-external-file-indicator.el ends here