;;; my-super-jumps.el --- Project-specific smart jump navigation with ring buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2024

;; Author: Your Name
;; Keywords: evil, jumps, navigation, project
;; Version: 1.0.0

;;; Commentary:

;; This module provides project-specific smart jump navigation with:
;; - Ring structure to keep max N jump points per project
;; - Ability to jump back and forward within project context
;; - Most recent usage order maintenance
;; - Async timer to reorder jumps after navigation settles
;; - Smart jump registration for file changes or significant line differences

;;; Code:

(require 'evil)
(require 'projectile)

;;; Customization

(defgroup my-super-jumps nil
  "Project-specific smart jump navigation."
  :group 'navigation
  :prefix "my-super-jumps-")

(defcustom my-super-jumps-max-length 20
  "Maximum number of jumps to keep in the ring per project."
  :type 'integer
  :group 'my-super-jumps)

(defcustom my-super-jumps-line-threshold 10
  "Minimum line difference to register a jump within the same file."
  :type 'integer
  :group 'my-super-jumps)

(defcustom my-super-jumps-reorder-delay 1.0
  "Delay in seconds before reordering jump after navigation."
  :type 'float
  :group 'my-super-jumps)

;;; Internal variables

(defvar my-super-jumps--project-rings (make-hash-table :test 'equal)
  "Hash table mapping project roots to jump rings.")

(defvar my-super-jumps--current-index nil
  "Current index in the jump ring for active project.")

(defvar my-super-jumps--reorder-timer nil
  "Timer for delayed jump reordering.")

(defvar my-super-jumps--last-jump-time nil
  "Time of last jump navigation.")

;;; Core data structures

(cl-defstruct my-super-jumps-entry
  "A single jump entry."
  file        ; File path
  position    ; Buffer position (marker or integer)
  line        ; Line number
  column      ; Column number
  timestamp)  ; When this jump was created/accessed

;;; Utility functions

(defun my-super-jumps--get-project-root ()
  "Get the current project root, or current directory if not in a project."
  (or (when (bound-and-true-p projectile-mode)
        (ignore-errors (projectile-project-root)))
      default-directory))

(defun my-super-jumps--get-project-ring ()
  "Get or create the jump ring for the current project."
  (let* ((project-root (my-super-jumps--get-project-root))
         (ring (gethash project-root my-super-jumps--project-rings)))
    (unless ring
      (setq ring (make-ring my-super-jumps-max-length))
      (puthash project-root ring my-super-jumps--project-rings))
    ring))

(defun my-super-jumps--create-entry ()
  "Create a jump entry for the current position."
  (make-my-super-jumps-entry
   :file (buffer-file-name)
   :position (point-marker)
   :line (line-number-at-pos)
   :column (current-column)
   :timestamp (float-time)))

(defun my-super-jumps--entry-equal-p (entry1 entry2)
  "Check if two jump entries represent the same location."
  (and entry1 entry2
       (equal (my-super-jumps-entry-file entry1)
              (my-super-jumps-entry-file entry2))
       (= (my-super-jumps-entry-line entry1)
          (my-super-jumps-entry-line entry2))))

(defun my-super-jumps--should-register-jump-p ()
  "Determine if current position should be registered as a jump."
  (let* ((ring (my-super-jumps--get-project-ring))
         (current-file (buffer-file-name))
         (current-line (line-number-at-pos)))
    
    (cond
     ;; Always register if ring is empty
     ((ring-empty-p ring) t)
     
     ;; Don't register if we're in a buffer without a file
     ((not current-file) nil)
     
     ;; Check against the most recent jump
     (t
      (let* ((last-entry (ring-ref ring 0))
             (last-file (my-super-jumps-entry-file last-entry))
             (last-line (my-super-jumps-entry-line last-entry)))
        
        (cond
         ;; Different file - always register
         ((not (equal current-file last-file)) t)
         
         ;; Same file - check line distance
         ((>= (abs (- current-line last-line)) 
              my-super-jumps-line-threshold) t)
         
         ;; Too close - don't register
         (t nil)))))))

;;; Ring management

(defun my-super-jumps--add-jump (entry)
  "Add ENTRY to the current project's jump ring."
  (let ((ring (my-super-jumps--get-project-ring)))
    ;; Remove any existing entry for the same location
    (dotimes (i (ring-length ring))
      (when (my-super-jumps--entry-equal-p entry (ring-ref ring i))
        (ring-remove ring i)
        (return)))
    
    ;; Add new entry at the front
    (ring-insert ring entry)
    (setq my-super-jumps--current-index 0)))

(defun my-super-jumps--move-to-front (index)
  "Move the jump at INDEX to the front of the ring."
  (let ((ring (my-super-jumps--get-project-ring)))
    (when (and (>= index 0) (< index (ring-length ring)))
      (let ((entry (ring-ref ring index)))
        ;; Remove from current position
        (ring-remove ring index)
        ;; Insert at front
        (ring-insert ring entry)
        (setq my-super-jumps--current-index 0)))))

;;; Navigation functions

(defun my-super-jumps--goto-entry (entry)
  "Navigate to the location specified by ENTRY."
  (when entry
    (let ((file (my-super-jumps-entry-file entry))
          (position (my-super-jumps-entry-position entry)))
      
      ;; Open file if different from current
      (unless (equal file (buffer-file-name))
        (find-file file))
      
      ;; Go to position
      (goto-char (if (markerp position)
                     (marker-position position)
                   position))
      
      ;; Update timestamp
      (setf (my-super-jumps-entry-timestamp entry) (float-time)))))

(defun my-super-jumps--schedule-reorder ()
  "Schedule reordering of jumps after navigation settles."
  (when my-super-jumps--reorder-timer
    (cancel-timer my-super-jumps--reorder-timer))
  
  (setq my-super-jumps--reorder-timer
        (run-with-timer my-super-jumps-reorder-delay nil
                        (lambda ()
                          (when my-super-jumps--current-index
                            (my-super-jumps--move-to-front my-super-jumps--current-index)
                            (message "Moved jump to front of ring"))
                          (setq my-super-jumps--reorder-timer nil)))))

;;; Public API

;;;###autoload
(defun my-super-jumps-register ()
  "Register current position as a jump if it meets the criteria."
  (interactive)
  (when (my-super-jumps--should-register-jump-p)
    (let ((entry (my-super-jumps--create-entry)))
      (my-super-jumps--add-jump entry)
      (message "Registered jump: %s:%d"
               (file-name-nondirectory (my-super-jumps-entry-file entry))
               (my-super-jumps-entry-line entry)))))

;;;###autoload
(defun my-super-jumps-backward ()
  "Jump backward in the project-specific jump ring."
  (interactive)
  (let* ((ring (my-super-jumps--get-project-ring))
         (ring-length (ring-length ring)))
    
    (cond
     ((ring-empty-p ring)
      (message "No jumps in ring for this project"))
     
     ((= ring-length 1)
      (message "Only one jump in ring"))
     
     (t
      ;; If we're not currently navigating, register current position first
      (unless my-super-jumps--current-index
        (my-super-jumps-register)
        (setq my-super-jumps--current-index 0))
      
      ;; Move to next jump (backward in time)
      (setq my-super-jumps--current-index
            (min (1+ my-super-jumps--current-index) (1- ring-length)))
      
      (let ((entry (ring-ref ring my-super-jumps--current-index)))
        (my-super-jumps--goto-entry entry)
        (message "Jump backward (%d/%d): %s:%d"
                 (1+ my-super-jumps--current-index)
                 ring-length
                 (file-name-nondirectory (my-super-jumps-entry-file entry))
                 (my-super-jumps-entry-line entry))
        
        (my-super-jumps--schedule-reorder))))))

;;;###autoload
(defun my-super-jumps-forward ()
  "Jump forward in the project-specific jump ring."
  (interactive)
  (let* ((ring (my-super-jumps--get-project-ring))
         (ring-length (ring-length ring)))
    
    (cond
     ((ring-empty-p ring)
      (message "No jumps in ring for this project"))
     
     ((not my-super-jumps--current-index)
      (message "Not currently navigating jumps"))
     
     ((= my-super-jumps--current-index 0)
      (message "Already at most recent jump"))
     
     (t
      ;; Move to previous jump (forward in time)
      (setq my-super-jumps--current-index
            (max (1- my-super-jumps--current-index) 0))
      
      (let ((entry (ring-ref ring my-super-jumps--current-index)))
        (my-super-jumps--goto-entry entry)
        (message "Jump forward (%d/%d): %s:%d"
                 (1+ my-super-jumps--current-index)
                 ring-length
                 (file-name-nondirectory (my-super-jumps-entry-file entry))
                 (my-super-jumps-entry-line entry))
        
        (my-super-jumps--schedule-reorder))))))

;;;###autoload
(defun my-super-jumps-list ()
  "Show all jumps for the current project."
  (interactive)
  (let* ((ring (my-super-jumps--get-project-ring))
         (project-root (my-super-jumps--get-project-root)))
    
    (if (ring-empty-p ring)
        (message "No jumps for project: %s" project-root)
      (with-output-to-temp-buffer "*Super Jumps*"
        (princ (format "Jumps for project: %s\n\n" project-root))
        (dotimes (i (ring-length ring))
          (let* ((entry (ring-ref ring i))
                 (file (my-super-jumps-entry-file entry))
                 (line (my-super-jumps-entry-line entry))
                 (current-p (eq i my-super-jumps--current-index)))
            (princ (format "%s%2d. %s:%d\n"
                           (if current-p "* " "  ")
                           (1+ i)
                           (file-name-nondirectory file)
                           line))))))))

;;;###autoload
(defun my-super-jumps-clear ()
  "Clear all jumps for the current project."
  (interactive)
  (let ((project-root (my-super-jumps--get-project-root)))
    (remhash project-root my-super-jumps--project-rings)
    (setq my-super-jumps--current-index nil)
    (message "Cleared jumps for project: %s" project-root)))

;;; Mode definition

;;;###autoload
(define-minor-mode my-super-jumps-mode
  "Enable project-specific smart jump navigation."
  :global t
  :group 'my-super-jumps
  :lighter " SJumps"
  
  (if my-super-jumps-mode
      (progn
        ;; Hook into various movement commands to register jumps
        (advice-add 'find-file :after #'my-super-jumps--after-find-file)
        (advice-add 'switch-to-buffer :after #'my-super-jumps--after-switch-buffer)
        (advice-add 'goto-line :after #'my-super-jumps--after-goto-line)
        (advice-add '+lookup/definition :before #'my-super-jumps-register)
        (advice-add '+lookup/references :before #'my-super-jumps-register)
        (message "Super jumps mode enabled"))
    
    ;; Cleanup
    (advice-remove 'find-file #'my-super-jumps--after-find-file)
    (advice-remove 'switch-to-buffer #'my-super-jumps--after-switch-buffer)
    (advice-remove 'goto-line #'my-super-jumps--after-goto-line)
    (advice-remove '+lookup/definition #'my-super-jumps-register)
    (advice-remove '+lookup/references #'my-super-jumps-register)
    (message "Super jumps mode disabled")))

;;; Advice functions

(defun my-super-jumps--after-find-file (&rest _args)
  "Register jump after opening a file."
  (when my-super-jumps-mode
    (my-super-jumps-register)))

(defun my-super-jumps--after-switch-buffer (&rest _args)
  "Register jump after switching to a buffer with a file."
  (when (and my-super-jumps-mode (buffer-file-name))
    (my-super-jumps-register)))

(defun my-super-jumps--after-goto-line (&rest _args)
  "Register jump after goto-line command."
  (when my-super-jumps-mode
    (my-super-jumps-register)))

(provide 'my-super-jumps)
;;; my-super-jumps.el ends here