;;; my-window-layout.el --- Custom window layout management -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides a custom window layout system for Doom Emacs that creates
;; a predictable layout with designated areas for different types of content.
;; 
;; Layout structure:
;; - 2 main code splits (horizontal, always visible)
;; - Left sidebar (hidden by default)
;; - Bottom bar (hidden by default)  
;; - Right sidebar (hidden by default)
;; - Top bar (hidden by default)
;;
;; Each section provides toggle, show, hide, and display functions.

;;; Code:

(require 'cl-lib)

;;; Configuration Variables

(defgroup my-window-layout nil
  "Custom window layout management."
  :group 'windows
  :prefix "my-window-layout-")

(defcustom my-window-layout-left-sidebar-width 30
  "Width of the left sidebar in characters."
  :type 'integer
  :group 'my-window-layout)

(defcustom my-window-layout-right-sidebar-width 60
  "Width of the right sidebar in characters."
  :type 'integer
  :group 'my-window-layout)

(defcustom my-window-layout-bottom-bar-height 15
  "Height of the bottom bar in lines."
  :type 'integer
  :group 'my-window-layout)

(defcustom my-window-layout-top-bar-height 10
  "Height of the top bar in lines."
  :type 'integer
  :group 'my-window-layout)

(defcustom my-window-layout-auto-setup-on-project-switch t
  "Whether to automatically setup layout when switching projects."
  :type 'boolean
  :group 'my-window-layout)

;;; Layout State Management

(defvar my-window-layout--state
  '((left-sidebar . hidden)
    (right-sidebar . hidden)
    (bottom-bar . hidden)
    (top-bar . hidden)
    (main-splits . visible))
  "Current state of each layout section.")

(defvar my-window-layout--windows
  '((left-sidebar . nil)
    (right-sidebar . nil)
    (bottom-bar . nil)
    (top-bar . nil)
    (main-left . nil)
    (main-right . nil))
  "Window references for each layout section.")

;;; Utility Functions

(defun my-window-layout--set-state (section state)
  "Set the STATE for SECTION in the layout."
  (setf (alist-get section my-window-layout--state) state))

(defun my-window-layout--get-state (section)
  "Get the current state of SECTION."
  (alist-get section my-window-layout--state))

(defun my-window-layout--set-window (section window)
  "Set the WINDOW reference for SECTION."
  (setf (alist-get section my-window-layout--windows) window))

(defun my-window-layout--get-window (section)
  "Get the window reference for SECTION."
  (alist-get section my-window-layout--windows))

(defun my-window-layout--window-live-p (section)
  "Check if the window for SECTION is still live."
  (let ((window (my-window-layout--get-window section)))
    (and window (window-live-p window))))

;;; Core Layout Functions

(defun my-window-layout--create-main-splits ()
  "Create the two main horizontal code splits."
  (delete-other-windows)
  (let* ((main-window (selected-window))
         (right-window (split-window main-window nil 'right)))
    (my-window-layout--set-window 'main-left main-window)
    (my-window-layout--set-window 'main-right right-window)
    (my-window-layout--set-state 'main-splits 'visible)
    (select-window main-window)))

(defun my-window-layout--create-left-sidebar ()
  "Create the left sidebar window."
  (when (not (my-window-layout--window-live-p 'left-sidebar))
    (let* ((main-left (my-window-layout--get-window 'main-left))
           (sidebar-window (split-window main-left 
                                       my-window-layout-left-sidebar-width 
                                       'left)))
      (my-window-layout--set-window 'left-sidebar sidebar-window)
      (my-window-layout--set-state 'left-sidebar 'visible)
      sidebar-window)))

(defun my-window-layout--create-right-sidebar ()
  "Create the right sidebar window that takes space from both main splits."
  (when (not (my-window-layout--window-live-p 'right-sidebar))
    (let* ((sidebar-window (split-window (frame-root-window) 
                                       (- my-window-layout-right-sidebar-width) 
                                       'right)))
      (my-window-layout--set-window 'right-sidebar sidebar-window)
      (my-window-layout--set-state 'right-sidebar 'visible)
      sidebar-window)))

(defun my-window-layout--create-bottom-bar ()
  "Create the bottom bar window."
  (when (not (my-window-layout--window-live-p 'bottom-bar))
    (let* ((bottom-window (split-window (frame-root-window) 
                                      (- my-window-layout-bottom-bar-height) 
                                      'below)))
      (my-window-layout--set-window 'bottom-bar bottom-window)
      (my-window-layout--set-state 'bottom-bar 'visible)
      bottom-window)))

(defun my-window-layout--create-top-bar ()
  "Create the top bar window."
  (when (not (my-window-layout--window-live-p 'top-bar))
    (let* ((top-window (split-window (frame-root-window) 
                                   my-window-layout-top-bar-height 
                                   'above)))
      (my-window-layout--set-window 'top-bar top-window)
      (my-window-layout--set-state 'top-bar 'visible)
      top-window)))

(defun my-window-layout--delete-section-window (section)
  "Delete the window for SECTION and update state."
  (when (my-window-layout--window-live-p section)
    (delete-window (my-window-layout--get-window section))
    (my-window-layout--set-window section nil)
    (my-window-layout--set-state section 'hidden)))

;;; Public API Functions

;;;###autoload
(defun my-window-layout-setup ()
  "Initialize the basic layout with main splits."
  (interactive)
  (if (= (length (window-list)) 1)
      ;; Only one window, create the split
      (progn
        (my-window-layout--create-main-splits)
        (message "Window layout initialized with main splits"))
    ;; Multiple windows exist, try to use them as main splits
    (progn
      (my-window-layout--check-main-splits-exist)
      (message "Window layout setup - using existing windows as main splits"))))

;;;###autoload
(defun my-window-layout-reset ()
  "Reset the entire layout to initial state."
  (interactive)
  (delete-other-windows)
  (setq my-window-layout--state
        '((left-sidebar . hidden)
          (right-sidebar . hidden)
          (bottom-bar . hidden)
          (top-bar . hidden)
          (main-splits . visible)))
  (setq my-window-layout--windows
        '((left-sidebar . nil)
          (right-sidebar . nil)
          (bottom-bar . nil)
          (top-bar . nil)
          (main-left . nil)
          (main-right . nil)))
  (my-window-layout--create-main-splits)
  (message "Window layout reset to default"))

;;; Section Control Functions

;;;###autoload
(defun my-window-layout-toggle-left-sidebar ()
  "Toggle the left sidebar visibility."
  (interactive)
  (if (eq (my-window-layout--get-state 'left-sidebar) 'visible)
      (my-window-layout-hide-left-sidebar)
    (my-window-layout-show-left-sidebar)))

;;;###autoload
(defun my-window-layout-show-left-sidebar ()
  "Show the left sidebar."
  (interactive)
  (unless (eq (my-window-layout--get-state 'main-splits) 'visible)
    (my-window-layout-setup))
  (my-window-layout--create-left-sidebar)
  (message "Left sidebar shown"))

;;;###autoload
(defun my-window-layout-hide-left-sidebar ()
  "Hide the left sidebar."
  (interactive)
  (my-window-layout--delete-section-window 'left-sidebar)
  (message "Left sidebar hidden"))

;;;###autoload
(defun my-window-layout-toggle-right-sidebar ()
  "Toggle the right sidebar visibility."
  (interactive)
  (if (eq (my-window-layout--get-state 'right-sidebar) 'visible)
      (my-window-layout-hide-right-sidebar)
    (my-window-layout-show-right-sidebar)))

;;;###autoload
(defun my-window-layout-show-right-sidebar ()
  "Show the right sidebar."
  (interactive)
  (unless (eq (my-window-layout--get-state 'main-splits) 'visible)
    (my-window-layout-setup))
  (my-window-layout--create-right-sidebar)
  (message "Right sidebar shown"))

;;;###autoload
(defun my-window-layout-hide-right-sidebar ()
  "Hide the right sidebar."
  (interactive)
  (my-window-layout--delete-section-window 'right-sidebar)
  (message "Right sidebar hidden"))

;;;###autoload
(defun my-window-layout-toggle-bottom-bar ()
  "Toggle the bottom bar visibility."
  (interactive)
  (if (eq (my-window-layout--get-state 'bottom-bar) 'visible)
      (my-window-layout-hide-bottom-bar)
    (my-window-layout-show-bottom-bar)))

;;;###autoload
(defun my-window-layout-show-bottom-bar ()
  "Show the bottom bar."
  (interactive)
  (unless (eq (my-window-layout--get-state 'main-splits) 'visible)
    (my-window-layout-setup))
  (my-window-layout--create-bottom-bar)
  (message "Bottom bar shown"))

;;;###autoload
(defun my-window-layout-hide-bottom-bar ()
  "Hide the bottom bar."
  (interactive)
  (my-window-layout--delete-section-window 'bottom-bar)
  (message "Bottom bar hidden"))

;;;###autoload
(defun my-window-layout-toggle-top-bar ()
  "Toggle the top bar visibility."
  (interactive)
  (if (eq (my-window-layout--get-state 'top-bar) 'visible)
      (my-window-layout-hide-top-bar)
    (my-window-layout-show-top-bar)))

;;;###autoload
(defun my-window-layout-show-top-bar ()
  "Show the top bar."
  (interactive)
  (unless (eq (my-window-layout--get-state 'main-splits) 'visible)
    (my-window-layout-setup))
  (my-window-layout--create-top-bar)
  (message "Top bar shown"))

;;;###autoload
(defun my-window-layout-hide-top-bar ()
  "Hide the top bar."
  (interactive)
  (my-window-layout--delete-section-window 'top-bar)
  (message "Top bar hidden"))

;;; Display Content Functions

;;;###autoload
(defun my-window-layout-show-with-layout (section &optional buffer-or-function)
  "Show BUFFER-OR-FUNCTION in the specified SECTION.
SECTION can be: 'left-sidebar, 'right-sidebar, 'bottom-bar, 'top-bar, 'main-left, 'main-right.
BUFFER-OR-FUNCTION can be a buffer, buffer name, or a function to call."
  (interactive
   (list (intern (completing-read "Section: " 
                                 '("left-sidebar" "right-sidebar" "bottom-bar" 
                                   "top-bar" "main-left" "main-right")))
         (read-buffer "Buffer: " nil t)))
  
  (let ((section-window nil))
    ;; Ensure main layout exists
    (unless (eq (my-window-layout--get-state 'main-splits) 'visible)
      (my-window-layout-setup))
    
    ;; Show the section if it's a sidebar/bar
    (cl-case section
      ('left-sidebar 
       (my-window-layout-show-left-sidebar)
       (setq section-window (my-window-layout--get-window 'left-sidebar)))
      ('right-sidebar 
       (my-window-layout-show-right-sidebar)
       (setq section-window (my-window-layout--get-window 'right-sidebar)))
      ('bottom-bar 
       (my-window-layout-show-bottom-bar)
       (setq section-window (my-window-layout--get-window 'bottom-bar)))
      ('top-bar 
       (my-window-layout-show-top-bar)
       (setq section-window (my-window-layout--get-window 'top-bar)))
      ('main-left 
       (setq section-window (my-window-layout--get-window 'main-left)))
      ('main-right 
       (setq section-window (my-window-layout--get-window 'main-right))))
    
    ;; Display content in the section window
    (when (and section-window (window-live-p section-window))
      (message "DEBUG: Selecting window for section %s, window: %s" section section-window)
      (select-window section-window)
      (cond
       ;; If it's a function, call it
       ((functionp buffer-or-function)
        (message "DEBUG: Calling function %s" buffer-or-function)
        (funcall buffer-or-function))
       ;; If it's a buffer or buffer name, switch to it
       ((or (bufferp buffer-or-function) (stringp buffer-or-function))
        (message "DEBUG: Switching to buffer %s" buffer-or-function)
        ;; First, ensure this buffer is not displayed in any other window
        (let ((target-buffer (if (stringp buffer-or-function) 
                               (get-buffer buffer-or-function) 
                               buffer-or-function)))
          (when target-buffer
            ;; Remove buffer from all other windows first
            (walk-windows (lambda (w)
                           (when (and (not (eq w section-window))
                                     (eq (window-buffer w) target-buffer))
                             (set-window-buffer w (other-buffer target-buffer)))))
            ;; Now set it in our target window
            (set-window-buffer section-window target-buffer))))
       ;; If no content specified, just select the window
       ((null buffer-or-function)
        (message "DEBUG: No content specified, just selecting window")
        nil)
       (t
        (error "Invalid buffer-or-function: %s" buffer-or-function))))
    
    (message "DEBUG: Displayed content in %s, total windows: %d" section (length (window-list)))))

;;; Convenience Functions for Common Use Cases

;;;###autoload
(defun my-window-layout-show-pytest-bottom ()
  "Show pytest output in the bottom bar."
  (interactive)
  (my-window-layout-show-with-layout 'bottom-bar "*Python*"))

;;;###autoload
(defun my-window-layout-show-treemacs-left ()
  "Show Treemacs in the left sidebar."
  (interactive)
  (my-window-layout-show-with-layout 'left-sidebar #'treemacs))

;;;###autoload
(defun my-window-layout-show-terminal-bottom ()
  "Show terminal in the bottom bar."
  (interactive)
  (my-window-layout-show-with-layout 'bottom-bar #'+vterm/here))

;;;###autoload
(defun my-window-layout-show-magit-right ()
  "Show Magit status in the right sidebar."
  (interactive)
  (my-window-layout-show-with-layout 'right-sidebar #'magit-status))

;;;###autoload
(defun my-window-layout-show-claude-code-right ()
  "Show Claude Code in the right sidebar, or focus it if already open there."
  (interactive)
  ;; Look for existing Claude Code buffer (pattern: *claude:...)
  (let ((claude-buffer (cl-find-if (lambda (buf)
                                    (string-match-p "^\\*claude:" (buffer-name buf)))
                                  (buffer-list))))
    
    (if claude-buffer
        ;; Existing Claude Code buffer found - show it in right sidebar
        (progn
          ;; Ensure we have the main layout
          (unless (eq (my-window-layout--get-state 'main-splits) 'visible)
            (my-window-layout-setup))
          ;; Show the right sidebar
          (my-window-layout-show-right-sidebar)
          ;; Display the existing Claude buffer in right sidebar
          (let ((right-sidebar-window (my-window-layout--get-window 'right-sidebar)))
            (when right-sidebar-window
              (set-window-buffer right-sidebar-window claude-buffer)
              (select-window right-sidebar-window)
              (when (bound-and-true-p evil-mode)
                (evil-insert-state))
              (message "Restored existing Claude Code session"))))
      ;; No Claude Code session exists - create new one
      (progn
        (claude-code)
        (message "Started new Claude Code session")))))

;;; Auto-setup Hooks

;;;###autoload
(defun my-window-layout--auto-setup-on-project-switch ()
  "Automatically setup layout when switching to a project."
  (when (and my-window-layout-auto-setup-on-project-switch
             (projectile-project-p))
    (my-window-layout-setup)))

;; Hook into project switching
(with-eval-after-load 'projectile
  (add-hook 'projectile-after-switch-project-hook 
            #'my-window-layout--auto-setup-on-project-switch))

;;; Window Cleanup Functions

;;;###autoload
(defun my-window-layout-close-auxiliary ()
  "Close all auxiliary windows, keeping only main left and right splits.
Special handling for right sidebar: if it contains Claude Code, hide instead of close."
  (interactive)
  (let ((closed-something nil))
    
    ;; Hide all our managed auxiliary sections
    (when (eq (my-window-layout--get-state 'left-sidebar) 'visible)
      (my-window-layout-hide-left-sidebar)
      (setq closed-something t))
    
    ;; Special handling for right sidebar with Claude Code
    (when (eq (my-window-layout--get-state 'right-sidebar) 'visible)
      (let* ((right-sidebar-window (my-window-layout--get-window 'right-sidebar))
             (right-sidebar-buffer (and right-sidebar-window 
                                      (window-buffer right-sidebar-window)))
             (is-claude-buffer (and right-sidebar-buffer
                                  (string-match-p "^\\*claude:" 
                                                (buffer-name right-sidebar-buffer)))))
        (if is-claude-buffer
            ;; If it's Claude Code, just hide the window but keep the buffer alive
            (progn
              (delete-window right-sidebar-window)
              (my-window-layout--set-window 'right-sidebar nil)
              (my-window-layout--set-state 'right-sidebar 'hidden)
              (message "Hidden Claude Code (kept session alive)")
              (setq closed-something t))
          ;; For other buffers, use normal hide
          (progn
            (my-window-layout-hide-right-sidebar)
            (setq closed-something t)))))
    
    (when (eq (my-window-layout--get-state 'bottom-bar) 'visible)
      (my-window-layout-hide-bottom-bar)
      (setq closed-something t))
    
    (when (eq (my-window-layout--get-state 'top-bar) 'visible)
      (my-window-layout-hide-top-bar)
      (setq closed-something t))
    
    ;; Close any Doom popup windows
    (when (and (fboundp '+popup/close-all)
               (+popup/close-all))
      (setq closed-something t))
    
    ;; Ensure we have main splits if we don't have any windows
    (unless (eq (my-window-layout--get-state 'main-splits) 'visible)
      (my-window-layout-setup))
    
    ;; Provide feedback
    (if closed-something
        (message "Closed auxiliary windows, kept main splits")
      (message "No auxiliary windows to close"))))

;;; Status and Debug Functions

(defun my-window-layout--check-main-splits-exist ()
  "Check if main splits actually exist and update state accordingly."
  (let ((windows (window-list))
        (has-splits (> (length (window-list)) 1)))
    (if has-splits
        ;; If we have multiple windows, try to identify main splits
        (let ((main-left (my-window-layout--get-window 'main-left))
              (main-right (my-window-layout--get-window 'main-right)))
          (when (or (not (window-live-p main-left)) 
                    (not (window-live-p main-right)))
            ;; Try to auto-detect main splits from current windows
            (let ((sorted-windows (sort (window-list) 
                                      (lambda (w1 w2) 
                                        (< (car (window-edges w1)) 
                                           (car (window-edges w2)))))))
              (when (>= (length sorted-windows) 2)
                (my-window-layout--set-window 'main-left (nth 0 sorted-windows))
                (my-window-layout--set-window 'main-right (nth 1 sorted-windows))
                (my-window-layout--set-state 'main-splits 'visible)))))
      ;; Only one window exists
      (my-window-layout--set-state 'main-splits 'hidden))))

;;;###autoload
(defun my-window-layout-status ()
  "Show current layout status."
  (interactive)
  ;; First, check and update main splits status
  (my-window-layout--check-main-splits-exist)
  
  (let ((status-lines 
         (mapcar (lambda (section-state)
                   (let ((section (car section-state))
                         (state (cdr section-state)))
                     (cond
                      ;; Special handling for main-splits
                      ((eq section 'main-splits)
                       (format "%s: %s (%d windows total)" 
                               section state (length (window-list))))
                      ;; Regular sections
                      (t
                       (format "%s: %s%s" 
                               section state
                               (if (my-window-layout--window-live-p section)
                                   " (live)"
                                 " (not created)"))))))
                 my-window-layout--state)))
    (message "Layout Status:\n%s" (string-join status-lines "\n"))))

(provide 'my-window-layout)

;;; my-window-layout.el ends here