;;; my-dired-extension.el --- Dired customizations -*- lexical-binding: t; -*-

;;; Commentary:
;; Custom dired keybindings and extensions

;;; Code:

(require 'dired)

;;;###autoload
(defun my/dired-create (name)
  "Create a new file or directory NAME in current dired directory.
If NAME ends with /, create a directory. Otherwise create a file."
  (interactive
   (list (read-string "Create file/dir (end with / for directory): ")))
  (let* ((path (expand-file-name name (dired-current-directory)))
         (is-dir (string-suffix-p "/" name))
         (target (if is-dir (directory-file-name path) path)))
    (if (file-exists-p target)
        (user-error "Already exists: %s" target)
      (if is-dir
          (make-directory target t)
        (write-region "" nil target))
      (revert-buffer)
      (dired-goto-file target))))

;;;###autoload
(defun my/dired-open-right-pane ()
  "Open or focus a dired pane to the right of the current one.
If a window to the right already exists, just move focus there.
Otherwise, split right and open a dired buffer for the same directory."
  (interactive)
  (let ((dir (dired-current-directory)))
    (if (window-in-direction 'right)
        (windmove-right)
      (select-window (split-window-right))
      (dired dir))))

;; Bind 'c' to create file/dir in dired (evil normal state)
(after! evil-collection
  (evil-define-key 'normal dired-mode-map "c" #'my/dired-create)
  (evil-define-key 'normal dired-mode-map (kbd "C-l") #'my/dired-open-right-pane))

(provide 'my-dired-extension)
;;; my-dired-extension.el ends here
