;;; my-goto-last-change.el --- Enhanced goto-last-change with jump list integration -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides an enhanced version of goto-last-change that saves
;; the current position to Evil's jump list before jumping, allowing you
;; to return with C-o in normal mode.

;;; Code:

(defun my/goto-last-change-with-jump ()
  "Go to the last change, but first save current position to jump list."
  (interactive)
  (when (fboundp 'evil-set-jump)
    (evil-set-jump))
  (goto-last-change nil))

;; Key binding
(map! :n "gh" #'my/goto-last-change-with-jump)

(provide 'my-goto-last-change)
;;; my-goto-last-change.el ends here
