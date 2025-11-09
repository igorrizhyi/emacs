;;; modules/my-search.el --- Advanced search functionality -*- lexical-binding: t; -*-

;;; Commentary:
;; Advanced search functions with previews using LSP:
;; - Class finder with live previews
;; - Function finder
;; - Symbol search

;;; Code:

(require 'lsp-mode nil t)

;;; Class Search using LSP

;;;###autoload
(defun my-search-find-class ()
  "Find and jump to class definitions using LSP workspace symbols."
  (interactive)
  ;; Register jump before navigation
  (when (fboundp 'my-super-jumps-mark-intention)
    (my-super-jumps-mark-intention)
    (my-super-jumps-register))
  
  ;; Use LSP workspace symbol search
  (call-interactively #'lsp-workspace-symbol))

;;;###autoload
(defun my-search-find-function ()
  "Find and jump to function definitions using LSP workspace symbols."
  (interactive)
  ;; Register jump before navigation
  (when (fboundp 'my-super-jumps-mark-intention)
    (my-super-jumps-mark-intention)
    (my-super-jumps-register))
  
  ;; Use LSP workspace symbol search
  (call-interactively #'lsp-workspace-symbol))

;;;###autoload
(defun my-search-find-symbol ()
  "Find and jump to any symbol using LSP workspace symbols."
  (interactive)
  ;; Register jump before navigation
  (when (fboundp 'my-super-jumps-mark-intention)
    (my-super-jumps-mark-intention)
    (my-super-jumps-register))
  
  ;; Use LSP workspace symbol search
  (call-interactively #'lsp-workspace-symbol))

(provide 'my-search)

;;; my-search.el ends here