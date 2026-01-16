;;; modules/text-functions.el --- Text transformation utilities -*- lexical-binding: t; -*-

;;; Commentary:
;; Utility functions for transforming selected text into various formats.

;;; Code:

(defun my/selection-to-python-array ()
  "Convert selected lines to Python array format.
Takes selected text with items separated by newlines/spaces/tabs
and converts to [item1, item2, ...] format."
  (interactive)
  (if (use-region-p)
      (let* ((text (buffer-substring-no-properties (region-beginning) (region-end)))
             (items (split-string text "[\n\r\t ]+" t))
             (result (concat "[" (string-join items ", ") "]")))
        (delete-region (region-beginning) (region-end))
        (insert result))
    (message "No region selected")))

(defun my/selection-to-python-string-array ()
  "Convert selected lines to Python string array format.
Takes selected text with items separated by newlines/spaces/tabs
and converts to [\\='item1\\=', \\='item2\\=', ...] format."
  (interactive)
  (if (use-region-p)
      (let* ((text (buffer-substring-no-properties (region-beginning) (region-end)))
             (items (split-string text "[\n\r\t ]+" t))
             (quoted (mapcar (lambda (s) (concat "'" s "'")) items))
             (result (concat "[" (string-join quoted ", ") "]")))
        (delete-region (region-beginning) (region-end))
        (insert result))
    (message "No region selected")))

(defun my/selection-to-sql-in ()
  "Convert selected lines to SQL IN clause format.
Takes selected text and converts to (\\='item1\\=', \\='item2\\=', ...) format."
  (interactive)
  (if (use-region-p)
      (let* ((text (buffer-substring-no-properties (region-beginning) (region-end)))
             (items (split-string text "[\n\r\t ]+" t))
             (quoted (mapcar (lambda (s) (concat "'" s "'")) items))
             (result (concat "(" (string-join quoted ", ") ")")))
        (delete-region (region-beginning) (region-end))
        (insert result))
    (message "No region selected")))

(defun my/selection-to-comma-separated ()
  "Convert selected lines to comma-separated format.
Takes selected text and converts to item1, item2, ... format."
  (interactive)
  (if (use-region-p)
      (let* ((text (buffer-substring-no-properties (region-beginning) (region-end)))
             (items (split-string text "[\n\r\t ]+" t))
             (result (string-join items ", ")))
        (delete-region (region-beginning) (region-end))
        (insert result))
    (message "No region selected")))

;; Unbind flycheck-mode from SPC t f
(map! :leader "t f" nil)

;; Key bindings under leader t f (Text Format)
(map! :leader
      (:prefix-map ("t f" . "Text Format")
       :desc "To Python array [1, 2]"        "p" #'my/selection-to-python-array
       :desc "To Python strings ['a', 'b']"  "s" #'my/selection-to-python-string-array
       :desc "To SQL IN ('a', 'b')"          "q" #'my/selection-to-sql-in
       :desc "To comma-separated"            "c" #'my/selection-to-comma-separated))

(provide 'text-functions)

;;; text-functions.el ends here
