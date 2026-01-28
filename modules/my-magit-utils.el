;;; my-magit-utils.el --- Magit utility functions -*- lexical-binding: t; -*-

;;; Commentary:
;; Custom magit utility functions for common git operations

;;; Code:

(require 'magit)

;;;###autoload
(defun my/magit-copy-branch-name ()
  "Copy the current git branch name to clipboard."
  (interactive)
  (if-let ((branch (magit-get-current-branch)))
      (progn
        (kill-new branch)
        (message "Copied branch name: %s" branch))
    (user-error "Not in a git repository or no branch checked out")))

;;;###autoload
(defun my/magit-copy-branch-name-at-point ()
  "Copy the branch name at point in magit buffers."
  (interactive)
  (if-let ((branch (magit-branch-at-point)))
      (progn
        (kill-new branch)
        (message "Copied branch name: %s" branch))
    (user-error "No branch at point")))

(defvar-local my-magit-saved-keymap nil
  "Saved magit-mode-map state for restoration.")

(defun my/magit-enter-pure-normal ()
  "Enter pure evil-normal mode, suppressing magit keybindings."
  (interactive)
  (unless my-magit-saved-keymap
    (setq my-magit-saved-keymap (copy-keymap magit-mode-map))
    ;; Suppress magit-mode-map by making it empty
    (setcdr magit-mode-map nil)
    (message "Pure normal mode - ESC to return to magit")))

(defun my/magit-exit-pure-normal ()
  "Restore magit keybindings and return to magit mode."
  (interactive)
  (when my-magit-saved-keymap
    ;; Restore magit-mode-map
    (setcdr magit-mode-map (cdr my-magit-saved-keymap))
    (setq my-magit-saved-keymap nil)
    (message "Magit mode restored")))

(defun my/magit-setup-normal-mode-toggle ()
  "Set up keybindings for toggling pure normal mode in magit."
  (evil-local-set-key 'normal (kbd "n") #'my/magit-enter-pure-normal)
  (evil-local-set-key 'normal (kbd "<escape>") #'my/magit-exit-pure-normal))

(add-hook 'magit-mode-hook #'my/magit-setup-normal-mode-toggle)

(provide 'my-magit-utils)
;;; my-magit-utils.el ends here
