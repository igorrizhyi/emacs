;;; my-agent-shell-tables.el --- Markdown table alignment for agent-shell -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'map)

(defun my/agent-shell--parse-table-row (line)
  "Parse a markdown table LINE into a list of cell strings.
Returns nil if LINE is not a table row."
  (when (string-match "^|\\(.*\\)|[ \t]*$" line)
    (mapcar #'string-trim (split-string (match-string 1 line) "|"))))

(defun my/agent-shell--separator-row-p (cells)
  "Return non-nil if CELLS represent a separator row (all cells match [-:]+)."
  (and cells
       (cl-every (lambda (c) (string-match-p "^[-:]+$" c)) cells)))

(defun my/agent-shell--table-complete-p (body-text table-end-offset)
  "Return non-nil if table ending at TABLE-END-OFFSET in BODY-TEXT looks complete.
Complete means the table is followed by a non-table line or end of text."
  (let ((rest (substring body-text table-end-offset)))
    (or (string-match-p "\\`[ \t]*\\'" rest)
        (string-match-p "\\`[ \t]*\n\\([^|]\\|\\'\\)" rest))))

(defun my/agent-shell--rebuild-separator (widths)
  "Build a separator row string from column WIDTHS list."
  (format "| %s |"
          (mapconcat (lambda (w) (make-string w ?-)) widths " | ")))

(defun my/agent-shell--rebuild-row (cells widths)
  "Build an aligned table row from CELLS padded to WIDTHS."
  (format "| %s |"
          (mapconcat
           (lambda (pair)
             (let ((cell (car pair))
                   (width (cdr pair)))
               (format (format "%%-%ds" width) cell)))
           (cl-mapcar #'cons cells widths)
           " | ")))

(defun my/agent-shell--align-table-string (table-text)
  "Align a markdown TABLE-TEXT string. Returns aligned text or nil if invalid."
  (let* ((lines (split-string table-text "\n" t "[ \t]*"))
         (parsed (mapcar #'my/agent-shell--parse-table-row lines))
         (has-sep nil)
         (ncols nil))
    ;; Validate: all lines parse, consistent column count, has separator
    (when (and (>= (length parsed) 3)
               (cl-every #'identity parsed))
      (setq ncols (length (car parsed)))
      (dolist (row parsed)
        (when (my/agent-shell--separator-row-p row)
          (setq has-sep t))
        (unless (= (length row) ncols)
          (setq ncols nil)))
      (when (and ncols has-sep)
        ;; Compute max widths (skip separator rows)
        (let ((widths (make-list ncols 0)))
          (dolist (row parsed)
            (unless (my/agent-shell--separator-row-p row)
              (setq widths
                    (cl-mapcar (lambda (w cell) (max w (length cell)))
                               widths row))))
          ;; Enforce minimum width of 3 for separator dashes
          (setq widths (mapcar (lambda (w) (max w 3)) widths))
          ;; Rebuild
          (mapconcat
           (lambda (row)
             (if (my/agent-shell--separator-row-p row)
                 (my/agent-shell--rebuild-separator widths)
               (my/agent-shell--rebuild-row row widths)))
           parsed
           "\n"))))))

(defun my/agent-shell--find-table-regions (text)
  "Find markdown table regions in TEXT.
Returns list of (START . END) character offsets into TEXT."
  (let ((regions nil)
        (pos 0)
        (len (length text)))
    (while (< pos len)
      ;; Find next line starting with |
      (if (and (or (= pos 0) (eq (aref text (1- pos)) ?\n))
               (< pos len)
               (eq (aref text pos) ?|))
          ;; Scan consecutive | lines
          (let ((region-start pos)
                (line-end pos))
            (while (and (< line-end len)
                        (eq (aref text line-end) ?|))
              ;; Find end of this line
              (let ((eol (or (cl-position ?\n text :start line-end) len)))
                ;; Check line ends with | (possibly trailing whitespace)
                (let ((trimmed-end eol))
                  (while (and (> trimmed-end line-end)
                              (memq (aref text (1- trimmed-end)) '(?\s ?\t)))
                    (cl-decf trimmed-end))
                  (if (and (> trimmed-end line-end)
                           (eq (aref text (1- trimmed-end)) ?|))
                      ;; Valid table line
                      (setq line-end (min (1+ eol) len))
                    ;; Not a valid table line, stop
                    (setq line-end len
                          region-start nil)))))
            (when region-start
              (let ((region-end (min line-end len)))
                ;; Trim trailing newline from region
                (when (and (> region-end region-start)
                           (eq (aref text (1- region-end)) ?\n))
                  (cl-decf region-end))
                (push (cons region-start region-end) regions)))
            (setq pos line-end))
        ;; Skip to next line
        (let ((eol (cl-position ?\n text :start pos)))
          (setq pos (if eol (1+ eol) len)))))
    (nreverse regions)))

(defun my/agent-shell--apply-table-faces (start parsed-rows)
  "Apply faces to table rows starting at buffer position START.
PARSED-ROWS is list of (LINE-TEXT . CELLS)."
  (save-excursion
    (goto-char start)
    (let ((first t))
      (dolist (row parsed-rows)
        (let ((line-start (line-beginning-position))
              (line-end (line-end-position)))
          (cond
           ;; Header row (first row)
           (first
            (let ((ov (make-overlay line-start line-end)))
              (overlay-put ov 'face 'bold)
              (overlay-put ov 'category 'my-agent-shell-table)
              (overlay-put ov 'my-agent-shell-table t))
            (setq first nil))
           ;; Separator row
           ((my/agent-shell--separator-row-p (cdr row))
            (let ((ov (make-overlay line-start line-end)))
              (overlay-put ov 'face 'shadow)
              (overlay-put ov 'category 'my-agent-shell-table)
              (overlay-put ov 'my-agent-shell-table t)))))
        (forward-line 1)))))

(defun my/agent-shell-align-tables (range)
  "Align markdown tables in the body region of RANGE.
Intended for use in `agent-shell-section-functions'."
  (unless (and (boundp 'shell-maker--busy) shell-maker--busy)
    (let ((body-start (map-nested-elt range '(:body :start)))
          (body-end (map-nested-elt range '(:body :end))))
      (when (and body-start body-end (< body-start body-end))
        (let* ((body-text (buffer-substring-no-properties body-start body-end))
               (regions (my/agent-shell--find-table-regions body-text)))
          (when regions
            ;; Process regions in reverse order so offsets stay valid
            (let ((inhibit-read-only t))
              ;; First remove old table overlays in the body region
              (dolist (ov (overlays-in body-start body-end))
                (when (overlay-get ov 'my-agent-shell-table)
                  (delete-overlay ov)))
              (dolist (region (reverse regions))
                (let* ((rel-start (car region))
                       (rel-end (cdr region))
                       (table-text (substring body-text rel-start rel-end))
                       (abs-start (+ body-start rel-start))
                       (abs-end (+ body-start rel-end)))
                  ;; Only align complete tables
                  (when (my/agent-shell--table-complete-p body-text rel-end)
                    (let ((aligned (my/agent-shell--align-table-string table-text)))
                      (when (and aligned (not (string= aligned table-text)))
                        ;; Replace in buffer
                        (goto-char abs-start)
                        (delete-region abs-start abs-end)
                        (insert aligned)
                        ;; Update body-end for subsequent regions
                        (let ((delta (- (length aligned) (length table-text))))
                          (setq body-end (+ body-end delta))))
                      ;; Apply faces (use current position after potential replacement)
                      (let* ((final-text (or aligned table-text))
                             (final-lines (split-string final-text "\n" t))
                             (parsed-rows (mapcar (lambda (l)
                                                    (cons l (my/agent-shell--parse-table-row l)))
                                                  final-lines)))
                        (my/agent-shell--apply-table-faces
                         (+ body-start rel-start) parsed-rows)))))))))))))

(provide 'my-agent-shell-tables)
;;; my-agent-shell-tables.el ends here
