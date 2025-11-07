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

(defcustom my-super-jumps-reorder-delay 0.2
  "Delay in seconds before reordering jump after navigation."
  :type 'float
  :group 'my-super-jumps)

(defcustom my-super-jumps-async-settle-delay 1.5
  "Delay in seconds before registering async buffer jumps after they stop updating."
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

(defvar my-super-jumps--jump-intention nil
  "Flag indicating that we intend to perform a jump and should register current position.")

(defvar my-super-jumps--async-buffers (make-hash-table :test 'equal)
  "Hash table mapping buffer IDs to their tracking data.")

(defvar my-super-jumps--async-timers (make-hash-table :test 'equal)
  "Hash table mapping buffer IDs to their settle timers.")

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
  (when-let ((file (buffer-file-name)))
    (make-my-super-jumps-entry
     :file (expand-file-name file)  ; Use full absolute path
     :position (point-marker)
     :line (line-number-at-pos)
     :column (current-column)
     :timestamp (float-time))))

(defun my-super-jumps--entry-equal-p (entry1 entry2)
  "Check if two jump entries represent the same location."
  (and entry1 entry2
       (equal (my-super-jumps-entry-file entry1)
              (my-super-jumps-entry-file entry2))
       (= (my-super-jumps-entry-line entry1)
          (my-super-jumps-entry-line entry2))))

(defun my-super-jumps--should-register-jump-p ()
  "Determine if current position should be registered as a jump."
  (and my-super-jumps--jump-intention  ; Only register if we intended to jump
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
                  (last-line (my-super-jumps-entry-line last-entry))
                  (current-file-full (expand-file-name current-file)))
             
             (cond
              ;; Different file (using full paths) - always register
              ((not (equal current-file-full last-file)) t)
              
              ;; Same file - check line distance
              ((>= (abs (- current-line last-line)) 
                   my-super-jumps-line-threshold) t)
              
              ;; Too close - don't register
              (t nil))))))))

;;; Ring management

(defun my-super-jumps--add-jump (entry)
  "Add ENTRY to the current project's jump ring."
  (let ((ring (my-super-jumps--get-project-ring)))
    ;; Remove any existing entry for the same location
    (let ((found nil)
          (i 0))
      (while (and (< i (ring-length ring)) (not found))
        (when (my-super-jumps--entry-equal-p entry (ring-ref ring i))
          (ring-remove ring i)
          (setq found t))
        (unless found
          (setq i (1+ i)))))
    
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
          (position (my-super-jumps-entry-position entry))
          (line (my-super-jumps-entry-line entry)))
      
      ;; Open file if different from current
      (unless (equal file (buffer-file-name))
        (find-file file))
      
      ;; Go to position - prefer marker, fallback to line number if position is just a line number
      (cond
       ((markerp position)
        (goto-char (marker-position position)))
       ((and (numberp position) (> position (point-max)))
        ;; Position seems invalid (larger than buffer), use line number
        (goto-line line))
       ((numberp position)
        (goto-char position))
       (t
        ;; Fallback to line number
        (goto-line line)))
      
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

;;; Async buffer tracking

(defun my-super-jumps--cancel-async-timer (buffer-id)
  "Cancel the async timer for BUFFER-ID if it exists."
  (when-let ((timer (gethash buffer-id my-super-jumps--async-timers)))
    (cancel-timer timer)
    (remhash buffer-id my-super-jumps--async-timers)))

(defun my-super-jumps--schedule-async-register (buffer-id)
  "Schedule async jump registration for BUFFER-ID after settle delay."
  ;; Cancel any existing timer for this buffer
  (my-super-jumps--cancel-async-timer buffer-id)
  
  ;; Create new timer
  (let ((timer (run-with-timer my-super-jumps-async-settle-delay nil
                               (lambda ()
                                 (my-super-jumps--process-async-buffer buffer-id)))))
    (puthash buffer-id timer my-super-jumps--async-timers)))

(defun my-super-jumps--process-async-buffer (buffer-id)
  "Process the async buffer for BUFFER-ID and register the jump.
Only registers if the async buffer file matches current file."
  (when-let ((buffer-data (gethash buffer-id my-super-jumps--async-buffers)))
    (let ((async-file (plist-get buffer-data :file))
          (line (plist-get buffer-data :line))
          (column (plist-get buffer-data :column))
          (current-file (buffer-file-name)))
      
      ;; Only register if current file matches the async buffer file
      (if (and current-file (string-equal async-file current-file))
          (progn
            ;; Set intention and register the jump with explicit position
            (setq my-super-jumps--jump-intention t)
            (my-super-jumps-register async-file line column)
            (message "Async jump registered: %s:%d (ID: %s)" 
                     (file-name-nondirectory async-file) line buffer-id))
        (message "Skipped async jump: file mismatch (current: %s, async: %s, ID: %s)"
                 (if current-file (file-name-nondirectory current-file) "none")
                 (file-name-nondirectory async-file) 
                 buffer-id))
      
      ;; Cleanup regardless of whether we registered
      (remhash buffer-id my-super-jumps--async-buffers)
      (remhash buffer-id my-super-jumps--async-timers))))

(defun my-super-jumps--update-async-buffer (buffer-id file line column)
  "Update the async buffer BUFFER-ID with current position data."
  (puthash buffer-id 
           (list :file file 
                 :line line 
                 :column column 
                 :timestamp (float-time))
           my-super-jumps--async-buffers)
  
  ;; Reschedule the timer
  (my-super-jumps--schedule-async-register buffer-id))

;;; Public API

;;;###autoload
(defun my-super-jumps-mark-intention ()
  "Mark that we intend to perform a jump, enabling jump registration."
  (interactive)
  (setq my-super-jumps--jump-intention t))

;;;###autoload
(defun my-super-jumps-clear-intention ()
  "Clear jump intention flag."
  (interactive)
  (setq my-super-jumps--jump-intention nil))

;;;###autoload
(defun my-super-jumps-register (&optional file line column)
  "Register position as a jump if it meets the criteria.
If FILE, LINE, and COLUMN are provided, register that position.
Otherwise, register current position."
  (interactive)
  (when (my-super-jumps--should-register-jump-p)
    (let ((entry (if file
                     ;; For remote positions, calculate actual buffer position
                     (let ((buffer (find-file-noselect file)))
                       (with-current-buffer buffer
                         (save-excursion
                           (goto-line line)
                           (when column (move-to-column column))
                           (make-my-super-jumps-entry
                            :file (expand-file-name file)
                            :position (point-marker)  ; Use actual position, not line number
                            :line line
                            :column (or column (current-column))
                            :timestamp (float-time)))))
                   (my-super-jumps--create-entry))))
      (when entry
        (my-super-jumps--add-jump entry)
        (message "Registered jump: %s:%d"
                 (file-name-nondirectory (my-super-jumps-entry-file entry))
                 (my-super-jumps-entry-line entry)))))
  ;; Clear intention after attempting to register
  (setq my-super-jumps--jump-intention nil))

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

;;;###autoload
(defun my-super-jumps-postpone-async (buffer-id)
  "Update async buffer BUFFER-ID with current position.
This will register a jump after 2 seconds of no updates to this buffer ID.
Perfect for rapid navigation where you want only the final position registered."
  (interactive "sBuffer ID: ")
  (when (buffer-file-name)
    ;; For async operations, we always set intention since they're deliberate
    (setq my-super-jumps--jump-intention t)
    (my-super-jumps--update-async-buffer buffer-id 
                                         (buffer-file-name)
                                         (line-number-at-pos)
                                         (current-column))))

;;;###autoload
(defun my-super-jumps-cancel-async (buffer-id)
  "Cancel async jump registration for BUFFER-ID."
  (interactive "sBuffer ID: ")
  (my-super-jumps--cancel-async-timer buffer-id)
  (remhash buffer-id my-super-jumps--async-buffers)
  (message "Cancelled async jump for buffer ID: %s" buffer-id))

;;;###autoload
(defun my-super-jumps-list-async ()
  "Show all pending async buffers."
  (interactive)
  (let ((buffers (hash-table-keys my-super-jumps--async-buffers)))
    (if buffers
        (message "Pending async buffers: %s" (string-join buffers ", "))
      (message "No pending async buffers"))))

;;; Mode definition

;;;###autoload
(define-minor-mode my-super-jumps-mode
  "Enable project-specific smart jump navigation."
  :global t
  :group 'my-super-jumps
  :lighter " SJumps"
  
  (if my-super-jumps-mode
      (progn
        ;; Only use command hooks (Evil-style approach)
        (my-super-jumps--setup-completion-hooks)
        (message "Super jumps mode enabled"))
    
    ;; Cleanup
    (my-super-jumps--remove-completion-hooks)
    (message "Super jumps mode disabled")))

;;; Selection-based jump registration

(defvar my-super-jumps--pre-selection-position nil
  "Store position before starting selection process.")

(defvar my-super-jumps--pre-selection-file nil
  "Store file before starting selection process.")

(defun my-super-jumps--store-pre-selection-position ()
  "Store current position before starting a selection process."
  (setq my-super-jumps--pre-selection-position (when (buffer-file-name) (point-marker)))
  (setq my-super-jumps--pre-selection-file (buffer-file-name)))

(defun my-super-jumps--register-on-selection ()
  "Register jump to current position when user makes a selection."
  (when (and my-super-jumps--pre-selection-position 
             my-super-jumps--pre-selection-file
             my-super-jumps-mode)
    (let ((current-file (buffer-file-name))
          (current-pos (point)))
      ;; Only register if we actually moved to a different location
      (when (or (not (equal current-file my-super-jumps--pre-selection-file))
                (and (equal current-file my-super-jumps--pre-selection-file)
                     (>= (abs (- (line-number-at-pos current-pos)
                                (line-number-at-pos my-super-jumps--pre-selection-position)))
                         my-super-jumps-line-threshold)))
        ;; Register the CURRENT position (where we landed) as a jump
        (setq my-super-jumps--jump-intention t)
        (my-super-jumps-register)))
    ;; Clear stored position
    (setq my-super-jumps--pre-selection-position nil)
    (setq my-super-jumps--pre-selection-file nil)))

;;; Simplified approach - just use manual registration

(defun my-super-jumps--before-find-file (&rest _args)
  "No-op."
  nil)

(defun my-super-jumps--after-find-file (&rest _args)
  "No-op."
  nil)

(defun my-super-jumps--before-switch-buffer (&rest _args)
  "No-op."
  nil)

(defun my-super-jumps--after-switch-buffer (&rest _args)
  "No-op."
  nil)

(defun my-super-jumps--before-goto-line (&rest _args)
  "Store position before goto-line."
  (when my-super-jumps-mode
    (my-super-jumps--store-pre-selection-position)))

(defun my-super-jumps--after-goto-line (&rest _args)
  "Register jump after goto-line."
  (when my-super-jumps-mode
    (my-super-jumps--register-on-selection)))

(defun my-super-jumps--before-lookup (&rest _args)
  "Store position before lookup commands."
  (when my-super-jumps-mode
    (my-super-jumps--store-pre-selection-position)))

;;; Enter key detection

(defvar my-super-jumps--enter-pressed nil
  "Flag to track if Enter was pressed in minibuffer.")

(defun my-super-jumps--track-enter-advice (&rest _)
  "Track when Enter is pressed in minibuffer."
  (when (and (minibufferp) my-super-jumps-mode)
    (setq my-super-jumps--enter-pressed t)))

(defun my-super-jumps--minibuffer-exit ()
  "Register jump only if Enter was pressed."
  (when (and my-super-jumps-mode my-super-jumps--enter-pressed)
    ;; Small delay to ensure the selection has taken effect
    (run-with-timer 0.1 nil #'my-super-jumps--register-on-selection))
  ;; Reset flag
  (setq my-super-jumps--enter-pressed nil))

;;;###autoload
(defun my-super-jumps-mark-and-register ()
  "Manually mark intention and register current position as jump."
  (interactive)
  (when my-super-jumps-mode
    (setq my-super-jumps--jump-intention t)
    (my-super-jumps-register)))

;;; Evil-style command tracking
(defvar my-super-jumps--last-command nil
  "Track the last command executed.")

(defvar my-super-jumps--pre-command-position nil
  "Position before the command.")

(defvar my-super-jumps--pre-command-file nil
  "File before the command.")

(defvar my-super-jumps--pre-command-line nil
  "Line number before the command.")

(defun my-super-jumps--pre-command-hook ()
  "Track commands and save position before navigation commands."
  (when my-super-jumps-mode
    (message (symbol-name this-command))
    (setq my-super-jumps--last-command this-command)
    ;; Save position if this is a navigation command
    (let ((cmd-name (symbol-name this-command))
          (prefix-arg (or current-prefix-arg 
                          (and (boundp 'evil-this-motion-count) evil-this-motion-count)
                          1)))
      (when (or (string-match-p "consult-buffer" cmd-name)
                (string-match-p "find-file" cmd-name)
                (string-match-p "evil-goto-first-line" cmd-name)
                (string-match-p "evil-goto-line" cmd-name)
                (string-match-p "smart-enter" cmd-name)
                (string-match-p "projectile" cmd-name)
                ;; Evil line movements with significant digit arguments
                (and (or (string-match-p "evil-next-line" cmd-name)
                         (string-match-p "evil-previous-line" cmd-name))
                     (>= prefix-arg my-super-jumps-line-threshold)))
        (message "LETS GO - saving prior position (prefix: %s)" prefix-arg)
        ;; Save current position before command executes
        (setq my-super-jumps--pre-command-position (point))
        (setq my-super-jumps--pre-command-file (buffer-file-name))
        (setq my-super-jumps--pre-command-line (line-number-at-pos))
        (setq my-super-jumps--jump-intention t)
        (my-super-jumps-register)))))

(defun my-super-jumps--post-command-hook ()
  "Register jump after certain commands complete, but only if movement is significant."
  (when (and my-super-jumps-mode 
             my-super-jumps--last-command)
    (let ((cmd-name (symbol-name my-super-jumps--last-command)))
      ;; Check for navigation commands that might need position validation
      (when (or (string-match-p "find-file\\|switch-to-buffer\\|projectile\\|evil-goto-first-line\\|evil-goto-line\\|evil-next-line\\|evil-previous-line" cmd-name)
                (string-match-p "consult\\|vertico\\|ivy" cmd-name)
                (get my-super-jumps--last-command :jump)) ; Use evil's jump property
        
        (let ((current-file (buffer-file-name))
              (current-line (line-number-at-pos)))
          
          ;; Only register if we have a valid movement
          (when (and current-file
                     (or 
                      ;; Different file - always register
                      (not (equal current-file my-super-jumps--pre-command-file))
                      ;; Same file but significant line difference
                      (and (equal current-file my-super-jumps--pre-command-file)
                           my-super-jumps--pre-command-line
                           (>= (abs (- current-line my-super-jumps--pre-command-line))
                               my-super-jumps-line-threshold))))
            (setq my-super-jumps--jump-intention t)
            (my-super-jumps-register)
            (message "Registered jump after command: %s (moved %d lines)" 
                     cmd-name 
                     (if my-super-jumps--pre-command-line
                         (abs (- current-line my-super-jumps--pre-command-line))
                       0))))))
    
    ;; Clear all tracking variables
    (setq my-super-jumps--last-command nil)
    (setq my-super-jumps--pre-command-position nil)
    (setq my-super-jumps--pre-command-file nil)
    (setq my-super-jumps--pre-command-line nil)))

;; Named advice functions
(defun my-super-jumps--on-vertico-exit (&rest _)
  "Register jump after vertico selection."
  (message "DEBUG: vertico-exit called!")
  (when my-super-jumps-mode
    (message "DEBUG: super-jumps-mode is active, registering jump")
    (run-with-timer 0.1 nil #'my-super-jumps-mark-and-register)))

(defun my-super-jumps--on-consult-read (&rest _)
  "Register jump after consult selection."
  (when my-super-jumps-mode
    (run-with-timer 0.1 nil #'my-super-jumps-mark-and-register)))

(defun my-super-jumps--on-ivy-done (&rest _)
  "Register jump after ivy selection."
  (when my-super-jumps-mode
    (run-with-timer 0.1 nil #'my-super-jumps-mark-and-register)))

(defun my-super-jumps--on-helm-exit (&rest _)
  "Register jump after helm selection."
  (when my-super-jumps-mode
    (run-with-timer 0.1 nil #'my-super-jumps-mark-and-register)))

;;; Evil-style command hooks setup
(defun my-super-jumps--setup-completion-hooks ()
  "Set up command hooks like Evil does."
  (add-hook 'pre-command-hook #'my-super-jumps--pre-command-hook)
  (add-hook 'post-command-hook #'my-super-jumps--post-command-hook)
  (message "DEBUG: Added command hooks for jump tracking"))

(defun my-super-jumps--remove-completion-hooks ()
  "Remove command hooks."
  (remove-hook 'pre-command-hook #'my-super-jumps--pre-command-hook)
  (remove-hook 'post-command-hook #'my-super-jumps--post-command-hook))

(provide 'my-super-jumps)
;;; my-super-jumps.el ends here
