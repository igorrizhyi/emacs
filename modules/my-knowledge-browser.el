;;; my-knowledge-browser.el --- Dynamic knowledge browser for markdown files -*- lexical-binding: t; -*-

;;; Commentary:
;; Browse markdown knowledge index files and fetch content from the knowledge
;; database. Press RET on a heading to execute the query defined in a
;; <!-- query: ... --> comment and inject the result into the buffer.

;;; Code:

(require 'markdown-mode)

(defvar doom-user-dir)

;;;; Minor mode

(defvar-local my/knowledge-browser--overlays nil
  "Active fetch indicator overlays.")

(defvar my/knowledge-browser-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'my/execute-knowledge-query)
    (define-key map (kbd "C-c C-k") #'my/knowledge-browser-clear-section)
    (define-key map (kbd "C-c C-K") #'my/knowledge-browser-clear-all)
    (define-key map (kbd "C-c C-r") #'my/knowledge-browser-refresh-all)
    map)
  "Keymap for `my/knowledge-browser-mode'.")

;;;###autoload
(define-minor-mode my/knowledge-browser-mode
  "Minor mode for browsing knowledge index markdown files.
When enabled, pressing RET on a heading fetches knowledge from the
database and injects it into the buffer."
  :lighter " KB"
  :keymap my/knowledge-browser-mode-map)

;;;; Parsing helpers

(defun my/--kb-heading-at-pos (pos)
  "Return (LEVEL . LINE-BEG) of the markdown heading at or before POS, or nil."
  (save-excursion
    (goto-char pos)
    (beginning-of-line)
    (if (looking-at "^\\(#+\\) ")
        (cons (length (match-string 1)) (line-beginning-position))
      (when (re-search-backward "^\\(#+\\) " nil t)
        (cons (length (match-string 1)) (line-beginning-position))))))

(defun my/--kb-section-end (heading-level heading-pos)
  "Return the end position of the section starting at HEADING-POS with HEADING-LEVEL.
This is the position just before the next heading of same or higher level, or `point-max'."
  (save-excursion
    (goto-char heading-pos)
    (forward-line 1)
    (let ((pattern (format "^\\(#\\{1,%d\\}\\) " heading-level)))
      (if (re-search-forward pattern nil t)
          (line-beginning-position)
        (point-max)))))

(defun my/--kb-extract-query (heading-pos section-end)
  "Extract the query string from <!-- query: ... --> between HEADING-POS and SECTION-END."
  (save-excursion
    (goto-char heading-pos)
    (when (re-search-forward "<!--\\s-*query:\\s-*\\(.+?\\)\\s-*-->" section-end t)
      (string-trim (match-string 1)))))

(defun my/--kb-extract-mode (heading-pos section-end)
  "Extract the mode from <!-- mode: ... --> between HEADING-POS and SECTION-END.
Returns \"technical\" if not found."
  (save-excursion
    (goto-char heading-pos)
    (if (re-search-forward "<!--\\s-*mode:\\s-*\\(summary\\|technical\\)\\s-*-->" section-end t)
        (match-string 1)
      "technical")))

(defun my/--kb-find-generated-markers (heading-pos section-end)
  "Find BEGIN/END GENERATED markers between HEADING-POS and SECTION-END.
Returns (BEGIN-START . END-END) positions, or nil if not found."
  (save-excursion
    (goto-char heading-pos)
    (when (re-search-forward "^<!-- BEGIN GENERATED -->$" section-end t)
      (let ((begin-start (line-beginning-position)))
        (when (re-search-forward "^<!-- END GENERATED -->$" section-end t)
          (cons begin-start (line-end-position)))))))

;;;; Predicate

(defun my/at-knowledge-query-block-p ()
  "Return non-nil if point is inside a knowledge query section.
A query section is the area between a heading that has a <!-- query: --> comment
and the next heading of the same or higher level."
  (let ((hd (my/--kb-heading-at-pos (point))))
    (when hd
      (let* ((level (car hd))
             (hpos (cdr hd))
             (sec-end (my/--kb-section-end level hpos)))
        (and (<= (point) sec-end)
             (my/--kb-extract-query hpos sec-end))))))

;;;; Visual feedback

(defun my/--kb-add-fetching-overlay (heading-pos)
  "Add a fetching indicator overlay at HEADING-POS. Returns the overlay."
  (save-excursion
    (goto-char heading-pos)
    (end-of-line)
    (let ((ov (make-overlay (point) (point))))
      (overlay-put ov 'after-string
                   (propertize " ⏳ Fetching..." 'face '(:foreground "#e0a030" :slant italic)))
      (overlay-put ov 'kb-fetching t)
      (push ov my/knowledge-browser--overlays)
      ov)))

(defun my/--kb-remove-overlay (ov)
  "Remove fetching overlay OV."
  (when (overlay-buffer ov)
    (delete-overlay ov))
  (setq my/knowledge-browser--overlays
        (delq ov my/knowledge-browser--overlays)))

;;;; Content injection

(defun my/--kb-inject-content (buf heading-pos _section-end content)
  "Inject CONTENT into BUF between generated markers near HEADING-POS.
_SECTION-END is ignored; section bounds are recalculated from the live buffer."
  (with-current-buffer buf
    (save-excursion
      ;; Re-calculate section-end in case buffer changed
      (let* ((hd (my/--kb-heading-at-pos heading-pos))
             (level (car hd))
             (sec-end (my/--kb-section-end level heading-pos))
             (markers (my/--kb-find-generated-markers heading-pos sec-end))
             (cleaned (string-trim content)))
        (if markers
            ;; Replace content between markers
            (let ((begin-end (save-excursion
                               (goto-char (car markers))
                               (end-of-line)
                               (1+ (point))))
                  (end-start (save-excursion
                               (goto-char (cdr markers))
                               (line-beginning-position))))
              (goto-char begin-end)
              (delete-region begin-end end-start)
              (insert cleaned "\n"))
          ;; Create markers after the query/mode comment block
          (goto-char heading-pos)
          (let ((insert-pos heading-pos))
            ;; Move past heading line
            (forward-line 1)
            (setq insert-pos (point))
            ;; Skip over comment lines (query, mode, blank lines between them)
            (while (and (< (point) sec-end)
                        (looking-at "^\\(<!--.*-->\\|\\s-*\\)$"))
              (forward-line 1)
              (setq insert-pos (point)))
            (goto-char insert-pos)
            (insert "\n<!-- BEGIN GENERATED -->\n"
                    cleaned
                    "\n<!-- END GENERATED -->\n")))
        (save-buffer)))))

;;;; Query execution

(defun my/--kb-execute-query-async (buf heading-pos query mode &optional callback)
  "Execute QUERY for the section at HEADING-POS in BUF asynchronously.
MODE is \"summary\" or \"technical\".  When the query completes (success
or failure), CALLBACK is called with no arguments if non-nil."
  (let* ((ov (with-current-buffer buf
               (my/--kb-add-fetching-overlay heading-pos)))
         (proc-buf (generate-new-buffer " *kb-query*"))
         (default-directory (expand-file-name "knowledge-mcp-server/" doom-user-dir))
         (sec-end (with-current-buffer buf
                    (let ((hd (my/--kb-heading-at-pos heading-pos)))
                      (my/--kb-section-end (car hd) heading-pos)))))
    (make-process
     :name "kb-query"
     :buffer proc-buf
     :command (list ".venv/bin/python" "query.py"
                    "--mode" mode
                    "--project-root" (expand-file-name doom-user-dir)
                    query)
     :sentinel
     (lambda (process _event)
       (when (memq (process-status process) '(exit signal))
         (unwind-protect
             (if (= (process-exit-status process) 0)
                 (let ((output (with-current-buffer proc-buf
                                 (buffer-string))))
                   (if (buffer-live-p buf)
                       (my/--kb-inject-content buf heading-pos sec-end output)
                     (message "Knowledge browser: target buffer was killed")))
               (message "Knowledge query failed (exit %d): %s"
                        (process-exit-status process)
                        (with-current-buffer proc-buf
                          (string-trim (buffer-string)))))
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (my/--kb-remove-overlay ov)))
           (kill-buffer proc-buf)
           (when callback
             (funcall callback))))))))

(defun my/execute-knowledge-query ()
  "Execute the knowledge query for the section at point.
Fetches content asynchronously and injects it into the buffer."
  (interactive)
  (let ((hd (my/--kb-heading-at-pos (point))))
    (unless hd
      (user-error "Not on or below a markdown heading"))
    (let* ((level (car hd))
           (hpos (cdr hd))
           (sec-end (my/--kb-section-end level hpos))
           (query (my/--kb-extract-query hpos sec-end))
           (mode (my/--kb-extract-mode hpos sec-end)))
      (unless query
        (user-error "No <!-- query: ... --> found in this section"))
      (my/--kb-execute-query-async (current-buffer) hpos query mode
                                   (lambda () (message "Knowledge query complete.")))
      (message "Querying knowledge: %s..."
               (truncate-string-to-width query 50 nil nil t)))))

;;;; Batch refresh

(defun my/--kb-collect-sections ()
  "Collect all query sections in the current buffer.
Returns a list of (HEADING-TEXT HEADING-POS QUERY MODE)."
  (save-excursion
    (goto-char (point-min))
    (let (sections)
      (while (re-search-forward "^\\(#+\\) \\(.+\\)$" nil t)
        (let* ((level (length (match-string 1)))
               (heading-text (match-string 2))
               (hpos (line-beginning-position))
               (sec-end (my/--kb-section-end level hpos))
               (query (my/--kb-extract-query hpos sec-end)))
          (when query
            (let ((mode (my/--kb-extract-mode hpos sec-end)))
              (push (list heading-text hpos query mode) sections)))))
      (nreverse sections))))

(defun my/--kb-refresh-chain (buf sections index total)
  "Refresh SECTIONS starting at INDEX in BUF.  TOTAL is for progress display."
  (if (>= index (length sections))
      (message "All %d sections refreshed." total)
    (let* ((section (nth index sections))
           (heading-text (nth 0 section))
           (hpos (nth 1 section))
           (query (nth 2 section))
           (mode (nth 3 section)))
      (message "Refreshing section %d/%d: %s..." (1+ index) total heading-text)
      (my/--kb-execute-query-async
       buf hpos query mode
       (lambda ()
         (my/--kb-refresh-chain buf sections (1+ index) total))))))

(defun my/knowledge-browser-refresh-all ()
  "Refresh all knowledge sections in the current buffer sequentially."
  (interactive)
  (let ((sections (my/--kb-collect-sections)))
    (if (null sections)
        (user-error "No query sections found in buffer")
      (message "Refreshing %d sections..." (length sections))
      (my/--kb-refresh-chain (current-buffer) sections 0 (length sections)))))

;;;; Clear functions

(defun my/knowledge-browser-clear-section ()
  "Clear generated content for the current section."
  (interactive)
  (let ((hd (my/--kb-heading-at-pos (point))))
    (unless hd
      (user-error "Not on or below a markdown heading"))
    (let* ((level (car hd))
           (hpos (cdr hd))
           (sec-end (my/--kb-section-end level hpos))
           (markers (my/--kb-find-generated-markers hpos sec-end)))
      (unless markers
        (user-error "No generated content markers in this section"))
      (let ((begin-end (save-excursion
                         (goto-char (car markers))
                         (end-of-line)
                         (1+ (point))))
            (end-start (save-excursion
                         (goto-char (cdr markers))
                         (line-beginning-position))))
        (when (< begin-end end-start)
          (delete-region begin-end end-start)
          (save-buffer)
          (message "Section cleared."))))))

(defun my/knowledge-browser-clear-all ()
  "Clear ALL generated sections in the buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (let ((count 0))
      (while (re-search-forward "^<!-- BEGIN GENERATED -->$" nil t)
        (let ((begin-end (1+ (line-end-position))))
          (when (re-search-forward "^<!-- END GENERATED -->$" nil t)
            (let ((end-start (line-beginning-position)))
              (when (< begin-end end-start)
                (delete-region begin-end end-start)
                (cl-incf count))))))
      (when (> count 0)
        (save-buffer)
        (message "Cleared %d section(s)." count)))))

(provide 'my-knowledge-browser)
;;; my-knowledge-browser.el ends here
