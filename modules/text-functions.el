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

(defun my/insert-date ()
  "Insert today's date in YYYY-MM-DD format."
  (interactive)
  (insert (format-time-string "%Y-%m-%d")))

(defun my/template-from-columns ()
  "Replace selected column-based text using a template.
Parses the selection as whitespace-delimited columns (skipping header line).
Prompts for a template where {1}, {2}, etc. reference columns.
Replaces the selection with the template applied to each row.

Example: with selection:
  NAME   AGE  CITY
  Alice  30   London
  Bob    25   Berlin

And template: INSERT INTO users VALUES ('{1}', {2}, '{3}');

Produces:
  INSERT INTO users VALUES ('Alice', 30, 'London');
  INSERT INTO users VALUES ('Bob', 25, 'Berlin');"
  (interactive)
  (if (use-region-p)
      (let* ((text (buffer-substring-no-properties (region-beginning) (region-end)))
             (lines (seq-filter (lambda (s) (not (string-empty-p (string-trim s))))
                                (split-string text "\n")))
             (skip-header (y-or-n-p "Skip first line (header)?"))
             (data-lines (if skip-header (cdr lines) lines))
             (template (read-string "Template ({1}, {2}, ...): "))
             (results nil))
        (dolist (line data-lines)
          (let* ((cols (split-string (string-trim line) "[ \t]+" t))
                 (result template))
            (dotimes (i (length cols))
              (setq result (string-replace (format "{%d}" (1+ i))
                                           (nth i cols)
                                           result)))
            (push result results)))
        (delete-region (region-beginning) (region-end))
        (insert (string-join (nreverse results) "\n")))
    (message "No region selected")))

;; Unbind flycheck-mode from SPC t f
(map! :leader "t f" nil)

;; Key bindings under leader t f (Text Format)
(map! :leader
      (:prefix-map ("t f" . "Text Format")
       :desc "To Python array [1, 2]"        "p" #'my/selection-to-python-array
       :desc "To Python strings ['a', 'b']"  "s" #'my/selection-to-python-string-array
       :desc "To SQL IN ('a', 'b')"          "q" #'my/selection-to-sql-in
       :desc "To comma-separated"            "c" #'my/selection-to-comma-separated
       :desc "Insert date (YYYY-MM-DD)"      "d" #'my/insert-date
       :desc "Template from columns"         "t" #'my/template-from-columns))

(provide 'text-functions)

;;; text-functions.el ends here
