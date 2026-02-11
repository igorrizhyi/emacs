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

;; Bind 'c' to create file/dir in dired (evil normal state)
(after! evil-collection
  (evil-define-key 'normal dired-mode-map "c" #'my/dired-create))

(provide 'my-dired-extension)
;;; my-dired-extension.el ends here
