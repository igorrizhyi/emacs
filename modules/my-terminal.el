;;; modules/my-terminal.el --- Terminal toggle functionality -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides terminal toggle functionality with C-j to show

;;; Code:

(require 'my-layout)

(defvar my/terminal-buffers (make-hash-table :test 'equal)
  "Hash table mapping workspace names to terminal buffers.")

(defvar my/terminal-windows (make-hash-table :test 'equal)
  "Hash table mapping workspace names to terminal windows.")

(defun my/get-workspace-key ()
  "Get a unique key for the current workspace."
  (cond
   ;; If in a project, use project root as key
   ((projectile-project-p)
    (projectile-project-root))
   ;; If using workspaces, use workspace name
   ((bound-and-true-p +workspaces-main)
    (+workspace-current-name))
   ;; Fallback to default
   (t "default")))

(defun my/is-claude-terminal-p (buffer)
  "Check if buffer is a Claude terminal buffer."
  (when (and buffer (buffer-live-p buffer))
    (let ((name (buffer-name buffer)))
      (or (string-match-p "^\\*claude-terminal:" name)
          (and (bound-and-true-p claude-code-terminal-id)
               (with-current-buffer buffer
                 (bound-and-true-p claude-code-terminal-id)))))))

(defun my/get-terminal-buffer (&optional workspace-key)
  "Get terminal buffer for current workspace, excluding Claude terminals."
  (let* ((key (or workspace-key (my/get-workspace-key)))
         (buffer (gethash key my/terminal-buffers)))
    ;; If the stored buffer is a Claude terminal, clear it and return nil
    (when (and buffer (my/is-claude-terminal-p buffer))
      (puthash key nil my/terminal-buffers)
      (setq buffer nil))
    buffer))

(defun my/set-terminal-buffer (buffer &optional workspace-key)
  "Set terminal buffer for current workspace, but refuse Claude terminals."
  (let ((key (or workspace-key (my/get-workspace-key))))
    ;; Only store non-Claude terminals
    (unless (my/is-claude-terminal-p buffer)
      (puthash key buffer my/terminal-buffers))))

(defun my/get-terminal-window (&optional workspace-key)
  "Get terminal window for current workspace."
  (let ((key (or workspace-key (my/get-workspace-key))))
    (gethash key my/terminal-windows)))

(defun my/set-terminal-window (window &optional workspace-key)
  "Set terminal window for current workspace."
  (let ((key (or workspace-key (my/get-workspace-key))))
    (puthash key window my/terminal-windows)))


(defun my/toggle-terminal-show ()
  "Show terminal in bottom bar using custom layout, workspace-aware."
  (interactive)
  (let ((terminal-buffer (my/get-terminal-buffer))
        (workspace-key (my/get-workspace-key))
        (project-root (when (projectile-project-p) (projectile-project-root))))
    
    (if (and terminal-buffer (buffer-live-p terminal-buffer))
        ;; Terminal buffer exists for this workspace, show it
        (progn
          (my-window-layout-show-with-layout 'bottom-bar terminal-buffer)
          (my/set-terminal-window (my-window-layout--get-window 'bottom-bar))
          ;; Focus the bottom bar window
          (select-window (my-window-layout--get-window 'bottom-bar)))
      ;; Create new terminal for this workspace with unique naming
      (let* ((default-directory (or project-root default-directory))
             (buffer-name (format "*my-terminal:%s*" 
                                (if project-root 
                                    (file-name-nondirectory (directory-file-name project-root))
                                  workspace-key)))
             (new-buffer nil))
        ;; Ensure we create a truly new buffer, not reuse existing ones
        (when (get-buffer buffer-name)
          (kill-buffer buffer-name))
        
        ;; Create terminal buffer 
        (if (featurep 'vterm)
            (setq new-buffer (vterm buffer-name))
          (setq new-buffer (ansi-term (getenv "SHELL") buffer-name)))
        
        ;; Store the buffer for this workspace
        (my/set-terminal-buffer new-buffer)
        
        ;; If terminal is currently displayed in main window, switch to previous buffer
        (when (eq (current-buffer) new-buffer)
          (switch-to-buffer (other-buffer new-buffer)))
        
        ;; Show in bottom bar only
        (my-window-layout-show-with-layout 'bottom-bar new-buffer)
        (my/set-terminal-window (my-window-layout--get-window 'bottom-bar))
        ;; Focus the bottom bar window
        (select-window (my-window-layout--get-window 'bottom-bar))))))

(defun my/toggle-terminal-hide ()
  "Hide the toggle terminal using custom layout."
  (interactive)
  (my-window-layout-hide-bottom-bar)
  (my/set-terminal-window nil))

(defun my/toggle-terminal ()
  "Toggle terminal visibility using custom layout, workspace-aware."
  (interactive)
  (let ((layout-state (my-window-layout--get-state 'bottom-bar))
        (terminal-window (my/get-terminal-window)))
    (message "DEBUG: layout-state=%s terminal-window=%s window-live=%s" 
             layout-state terminal-window (and terminal-window (window-live-p terminal-window)))
    (if (and (eq layout-state 'visible) 
             terminal-window 
             (window-live-p terminal-window))
        (my/toggle-terminal-hide)
      (my/toggle-terminal-show))))

(defun my/terminal-kill ()
  "Kill the terminal buffer for current workspace and close window."
  (interactive)
  (let ((terminal-buffer (my/get-terminal-buffer)))
    (when (and terminal-buffer (buffer-live-p terminal-buffer))
      (kill-buffer terminal-buffer)
      (my/set-terminal-buffer nil)))
  (my/toggle-terminal-hide))

(defun my/terminal-kill-all ()
  "Kill all terminal buffers across all workspaces."
  (interactive)
  (maphash (lambda (key buffer)
             (when (and buffer (buffer-live-p buffer))
               (kill-buffer buffer)))
           my/terminal-buffers)
  (clrhash my/terminal-buffers)
  (clrhash my/terminal-windows)
  (my/toggle-terminal-hide)
  (message "All terminal buffers killed"))

;; Hook to track when terminal window is deleted
(defun my/terminal-window-deletion-hook ()
  "Hook to track when windows are deleted and update terminal state."
  (let ((bottom-window (my/get-terminal-window)))
    ;; If we think we have a bottom window but it's not live, clear our state
    (when (and bottom-window (not (window-live-p bottom-window)))
      (my/set-terminal-window nil))))

;; Add the hook to track window changes
(add-hook 'window-configuration-change-hook #'my/terminal-window-deletion-hook)

;; Key bindings
(map! "C-j" #'my/toggle-terminal-show)

;; Force C-b to be terminal toggle - override all other bindings
(after! evil
  (define-key evil-insert-state-map (kbd "C-b") #'my/toggle-terminal)
  (define-key evil-normal-state-map (kbd "C-b") #'my/toggle-terminal)
  (define-key evil-visual-state-map (kbd "C-b") #'my/toggle-terminal))

(global-set-key (kbd "C-b") #'my/toggle-terminal)

;; Leader key bindings - integrate with existing bindings
(map! :leader
      :desc "Toggle terminal" "'" #'my/toggle-terminal
      :desc "Kill terminal" "\"" #'my/terminal-kill
      :desc "Kill all terminals" "M-\"" #'my/terminal-kill-all)

(provide 'my-terminal)

;;; my-terminal.el ends here
