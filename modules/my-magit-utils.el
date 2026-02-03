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

;; Global pristine copy of magit-mode-map (saved once at load time)
(defvar my-magit-pristine-keymap nil
  "Pristine copy of magit-mode-map for recovery.")

;; Global state tracker (keymap is global, so state must be too)
(defvar my-magit-in-pure-normal nil
  "Non-nil when magit is in pure normal mode.")

(defun my/magit-save-pristine-keymap ()
  "Save pristine magit-mode-map once."
  (unless my-magit-pristine-keymap
    (setq my-magit-pristine-keymap (copy-keymap magit-mode-map))))

(defun my/magit-enter-pure-normal ()
  "Enter pure evil-normal mode, suppressing magit keybindings."
  (interactive)
  (unless my-magit-in-pure-normal
    (my/magit-save-pristine-keymap)
    (setcdr magit-mode-map nil)
    (setq my-magit-in-pure-normal t)
    (message "Pure normal mode - ESC to return to magit")))

(defun my/magit-exit-pure-normal ()
  "Restore magit keybindings and return to magit mode."
  (interactive)
  (when (and my-magit-in-pure-normal my-magit-pristine-keymap)
    (setcdr magit-mode-map (cdr my-magit-pristine-keymap))
    (setq my-magit-in-pure-normal nil)
    (message "Magit mode restored")))

(defun my/magit-ensure-normal-state ()
  "Ensure magit is in normal state (not pure-normal). Called on buffer entry."
  (when my-magit-in-pure-normal
    (my/magit-exit-pure-normal)))

(defun my/magit-setup-normal-mode-toggle ()
  "Set up keybindings for toggling pure normal mode in magit."
  ;; Restore normal state when entering any magit buffer
  (my/magit-ensure-normal-state)
  ;; Save pristine keymap if not yet saved
  (my/magit-save-pristine-keymap)
  ;; Set up keybindings
  (evil-local-set-key 'normal (kbd "n") #'my/magit-enter-pure-normal)
  (evil-local-set-key 'normal (kbd "<escape>") #'my/magit-exit-pure-normal)
  (evil-local-set-key 'normal (kbd "<right>") #'magit-section-toggle)
  (evil-local-set-key 'normal (kbd "C-<tab>") #'switch-to-buffer))

(add-hook 'magit-mode-hook #'my/magit-setup-normal-mode-toggle)

(provide 'my-magit-utils)
;;; my-magit-utils.el ends here
