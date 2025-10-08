;;; my-smart-splits.el --- Smart split management -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides smart split management for Doom Emacs.
;; Key features:
;; - Maintains maximum of 2 horizontal splits for code windows
;; - C-g duplicates current buffer in opposite split
;; - If only one window, creates a new split with same buffer
;; - Uses my/is-main-code-buffer-p from font management to identify code buffers

;;; Code:

;; Require font management module for the buffer detection function
(require 'my-font-management)

(defun my/get-code-windows ()
  "Get list of code windows using my/is-main-code-buffer-p."
  (seq-filter (lambda (window)
                (with-current-buffer (window-buffer window)
                  (my/is-main-code-buffer-p)))
              (window-list)))

(defun my/count-code-windows ()
  "Count the number of code windows using my/is-main-code-buffer-p."
  (length (my/get-code-windows)))

(defun my/is-leftmost-code-window-p (window)
  "Check if WINDOW is the leftmost code window."
  (let ((code-windows (my/get-code-windows))
        (window-left (window-left-column window)))
    (when code-windows
      (= window-left (apply #'min (mapcar #'window-left-column code-windows))))))

(defun my/smart-duplicate-buffer ()
  "Smart buffer duplication with split management.
- If only one code window: create horizontal split with same buffer
- If two code windows: duplicate current buffer in the opposite split
- Maintains maximum of 2 horizontal splits for code windows
- Only works with main code buffers (identified by my/is-main-code-buffer-p)"
  (interactive)
  (let* ((current-buffer (current-buffer))
         (current-window (selected-window))
         (current-line (line-number-at-pos))
         (current-column (current-column)))
    
    ;; Only proceed if current buffer is a main code buffer
    (unless (my/is-main-code-buffer-p)
      (user-error "Current buffer is not a main code buffer"))
    
    (let* ((code-windows (my/get-code-windows))
           (code-window-count (length code-windows)))
      
      (cond
       ;; Case 1: Only one code window - create new split
       ((= code-window-count 1)
        (split-window-right)
        (other-window 1)
        (switch-to-buffer current-buffer)
        (goto-line current-line)
        (move-to-column current-column)
        (message "Created new split with current buffer at line %d" current-line))
       
       ;; Case 2: Two code windows - duplicate in opposite split
       ((= code-window-count 2)
        (let* ((other-window (car (seq-remove (lambda (w) (eq w current-window)) code-windows))))
          (select-window other-window)
          (switch-to-buffer current-buffer)
          (goto-line current-line)
          (move-to-column current-column)
          (message "Duplicated buffer in opposite split at line %d" current-line)))
       
       ;; Case 3: More than two code windows - close extras and duplicate
       ((> code-window-count 2)
        ;; Keep only the current window and one other
        (let* ((windows-to-keep (list current-window 
                                     (car (seq-remove (lambda (w) (eq w current-window)) code-windows))))
               (windows-to-close (seq-remove (lambda (w) (member w windows-to-keep)) code-windows)))
          ;; Close extra windows
          (dolist (window windows-to-close)
            (delete-window window))
          ;; Now duplicate in the remaining window
          (let ((other-window (car (seq-remove (lambda (w) (eq w current-window)) 
                                              (my/get-code-windows)))))
            (when other-window
              (select-window other-window)
              (switch-to-buffer current-buffer)
              (goto-line current-line)
              (move-to-column current-column)
              (message "Closed extra splits and duplicated buffer at line %d" current-line)))))
       
       ;; Case 4: No code windows (shouldn't happen since we checked current buffer)
       (t
        (message "No code windows found"))))))

(defun my/smart-split-navigation ()
  "Navigate between code splits intelligently."
  (interactive)
  (let* ((code-windows (my/get-code-windows))
         (code-window-count (length code-windows))
         (current-window (selected-window)))
    
    (cond
     ((= code-window-count 1)
      (message "Only one code window available"))
     
     ((>= code-window-count 2)
      (let ((other-code-window (car (seq-remove (lambda (w) (eq w current-window)) code-windows))))
        (when other-code-window
          (select-window other-code-window)
          (message "Switched to other code window"))))
     
     (t
      (message "No code windows found")))))

(defun my/close-other-code-splits ()
  "Close all code splits except the current one."
  (interactive)
  (unless (my/is-main-code-buffer-p)
    (user-error "Current buffer is not a main code buffer"))
  
  (let* ((current-window (selected-window))
         (code-windows (my/get-code-windows))
         (other-code-windows (seq-remove (lambda (w) (eq w current-window)) code-windows)))
    
    (if other-code-windows
        (progn
          (dolist (window other-code-windows)
            (delete-window window))
          (message "Closed %d other code split(s)" (length other-code-windows)))
      (message "No other code splits to close"))))

;; Key bindings
;; C-c s for smart duplicate buffer (original binding)
(global-set-key (kbd "C-c s") #'my/smart-duplicate-buffer)

;; Force C-d to be smart duplicate buffer - override all other bindings
(after! evil
  (define-key evil-insert-state-map (kbd "C-d") #'my/smart-duplicate-buffer)
  (define-key evil-normal-state-map (kbd "C-d") #'my/smart-duplicate-buffer)
  (define-key evil-visual-state-map (kbd "C-d") #'my/smart-duplicate-buffer))

(global-set-key (kbd "C-d") #'my/smart-duplicate-buffer)

;; Optional additional bindings (uncomment if desired):
;; (global-set-key (kbd "C-x o") #'my/smart-split-navigation)
;; (global-set-key (kbd "C-x 1") #'my/close-other-code-splits)

(provide 'my-smart-splits)

;;; my-smart-splits.el ends here