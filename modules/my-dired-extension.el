;;; my-dired-extension.el --- Dired customizations -*- lexical-binding: t; -*-

;;; Commentary:
;; Custom dired keybindings and extensions

;;; Code:

(require 'dired)

;;;###autoload
(defun my/dired-create-file (filename)
  "Create a new file FILENAME in current dired directory."
  (interactive
   (list (read-file-name "Create file: " (dired-current-directory))))
  (let ((file (expand-file-name filename)))
    (if (file-exists-p file)
        (user-error "File already exists: %s" file)
      (write-region "" nil file)
      (dired-add-file file)
      (revert-buffer)
      (dired-goto-file file))))

;; Bind 'c' to create file in dired (evil normal state)
(after! evil-collection
  (evil-define-key 'normal dired-mode-map "c" #'my/dired-create-file))

(provide 'my-dired-extension)
;;; my-dired-extension.el ends here
