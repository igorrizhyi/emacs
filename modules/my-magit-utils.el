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

(provide 'my-magit-utils)
;;; my-magit-utils.el ends here
