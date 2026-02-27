;;; code-context.el --- Syntax-aware code context overlay -*- lexical-binding: t; -*-
;;
;; Author: Igor Rizhyi
;; Version: 0.1.0
;; Keywords: context overlay
;; Package-Requires: ((emacs "27.1"))
;;
;;; Commentary:
;; Shows enclosing code context (class, function, etc.) in a sticky overlay
;; at the top of the window. Uses `syntax-ppss' for reliable string/comment
;; detection, avoiding the multiline-string bugs of indentation-only approaches.
;;
;;; Code:

(require 'cl-lib)

;;; Customization

(defgroup code-context nil
  "Syntax-aware code context overlay."
  :group 'tools)

(defface code-context-face
  '((t (:inherit window-stool-face)))
  "Face for the code context overlay.
Inherits from `window-stool-face' to reuse existing theme settings."
  :group 'code-context)

(defcustom code-context-n-from-top 2
  "Maximum number of context lines to display."
  :type 'natnum
  :group 'code-context)

(defconst code-context--min-window-height 20
  "Minimum window height for displaying context.")

(defconst code-context--min-window-width 50
  "Minimum window width for displaying context.")

;;; Context extraction

(defun code-context--line-string ()
  "Return the current line as a fontified string with trailing newline."
  (let ((beg (line-beginning-position))
        (end (line-end-position)))
    (unless (text-property-not-all beg end 'fontified t)
      (font-lock-ensure beg end))
    (concat (buffer-substring beg end) "\n")))

(defun code-context--skip-to-code-line ()
  "Move backward to the nearest valid code line.
Skips strings, comments, empty lines, and continuation lines.
Uses a single `syntax-ppss' call per line.
Return non-nil if a valid line was found, nil if we hit `bobp'."
  (let ((found nil))
    (while (and (not found) (not (bobp)))
      (let* ((bol (line-beginning-position))
             (ppss (syntax-ppss bol)))
        (cond
         ;; Inside a string — jump to its start
         ((nth 3 ppss)
          (let ((str-start (nth 8 ppss)))
            (if str-start
                (progn (goto-char str-start) (beginning-of-line))
              (forward-line -1))))
         ;; Inside a comment — skip
         ((nth 4 ppss)
          (forward-line -1))
         ;; Empty/whitespace line
         ((progn (goto-char bol) (looking-at-p "^\\s-*$"))
          (forward-line -1))
         ;; Continuation line: starts with ) ] } or ->
         ((save-excursion
            (back-to-indentation)
            (looking-at-p "[])}]\\|->"))
          (forward-line -1))
         ;; Decorator line: starts with @
         ((save-excursion
            (back-to-indentation)
            (looking-at-p "@"))
          (forward-line -1))
         ;; Valid code line
         (t (goto-char bol) (setq found t)))))
    found))

(defun code-context--get-context (pos n)
  "Extract up to N context lines for position POS.
Walks backward from POS collecting lines with strictly decreasing
indentation, skipping strings/comments.  Returns a list of fontified
strings (outermost first), truncated to N."
  (save-excursion
    (goto-char pos)
    ;; If inside a string, jump to its start
    (let ((ppss (syntax-ppss)))
      (when (nth 3 ppss)
        (goto-char (nth 8 ppss))
        (beginning-of-line)))
    ;; Start from line ABOVE display-start so we only collect
    ;; lines that are off-screen (not already visible)
    (forward-line -1)
    ;; Find the first valid code line above the visible area
    (code-context--skip-to-code-line)
    (let ((ctx '())
          (prev-indent (current-indentation)))
      (push (code-context--line-string) ctx)
      ;; Walk backward collecting lines with strictly less indentation
      (while (and (> prev-indent 0) (not (bobp)))
        (forward-line -1)
        (when (code-context--skip-to-code-line)
          (let ((ind (current-indentation)))
            (when (< ind prev-indent)
              (setq prev-indent ind)
              (push (code-context--line-string) ctx)))))
      ;; Truncate to N from outermost
      (if (> (length ctx) n)
          (cl-subseq ctx 0 n)
        ctx))))

;;; Overlay management

(defvar-local code-context--overlay nil
  "The overlay used to display context.")

(defvar-local code-context--prev-ctx nil
  "Previous context list, for scroll compensation.")

(defvar-local code-context--cached-context-str nil
  "Cached rendered context string (without covered line).")

(defvar-local code-context--cached-defun-pos nil
  "Buffer position from `beginning-of-defun' used as cache key.
Changes when crossing function/class boundaries.")

(defun code-context--defun-pos (pos)
  "Return `beginning-of-defun' position from POS, or nil."
  (save-excursion
    (goto-char pos)
    (when (ignore-errors (beginning-of-defun) t)
      (point))))

(defun code-context--build-context-str (ctx win-width)
  "Build the rendered context string from CTX lines for WIN-WIDTH."
  (when ctx
    (let ((str (cl-reduce
                (lambda (acc s)
                  (concat acc (truncate-string-to-width s win-width 0 nil "\n")))
                ctx)))
      (when (> (length str) 0)
        (add-face-text-property
         0 (length str) '(:inherit code-context-face) t str))
      str)))

(defun code-context--show-overlay (window display-start context-str)
  "Place the overlay for WINDOW at DISPLAY-START with CONTEXT-STR."
  (let* ((ol-beg display-start)
         (ol-end (save-excursion
                   (goto-char display-start)
                   (forward-visible-line 1)
                   (line-end-position)))
         (covered-line (save-excursion
                         (goto-char display-start)
                         (forward-visible-line 1)
                         (buffer-substring
                          (line-beginning-position)
                          (line-end-position))))
         (display-str (concat context-str covered-line)))
    (move-overlay code-context--overlay ol-beg ol-end)
    (overlay-put code-context--overlay 'type 'code-context--overlay)
    (overlay-put code-context--overlay 'priority 0)
    (overlay-put code-context--overlay 'display display-str)))

(defun code-context--update (window display-start)
  "Create or update the code context overlay for WINDOW at DISPLAY-START."
  (when (and (window-live-p window)
             (with-current-buffer (window-buffer window)
               code-context-mode))
    (with-current-buffer (window-buffer window)
      (unless code-context--overlay
        (setq-local code-context--overlay (make-overlay 1 1)))
      (if (or (<= (window-height window) code-context--min-window-height)
              (<= (window-width window) code-context--min-window-width)
              (eq display-start (point-min))
              (not (buffer-file-name)))
          (delete-overlay code-context--overlay)
        ;; Cache key: beginning-of-defun position (fast, mode-aware)
        (let ((defun-pos (code-context--defun-pos display-start)))
          (if (and defun-pos
                   (eql defun-pos code-context--cached-defun-pos)
                   code-context--prev-ctx
                   code-context--cached-context-str)
              ;; Cache hit: same enclosing defun, reuse context
              (code-context--show-overlay window display-start
                                          code-context--cached-context-str)
            ;; Cache miss: full recompute
            (let* ((ctx (code-context--get-context display-start
                                                   code-context-n-from-top))
                   (win-width (1- (window-width window)))
                   (context-str (code-context--build-context-str ctx win-width)))
              (when (and ctx context-str)
                (code-context--show-overlay window display-start context-str))
              (setq-local code-context--prev-ctx ctx)
              (setq-local code-context--cached-context-str context-str)
              (setq-local code-context--cached-defun-pos defun-pos))))))))

(defun code-context--remove ()
  "Remove the code context overlay from the current buffer."
  (when (overlayp code-context--overlay)
    (delete-overlay code-context--overlay)
    (setq-local code-context--overlay nil))
  (remove-overlays (point-min) (point-max) 'type 'code-context--overlay))

;;; Hook functions

(defun code-context--on-scroll (window display-start)
  "Handler for `window-scroll-functions'.
WINDOW and DISPLAY-START are provided by the hook."
  (when (and (buffer-file-name)
             (or (not (boundp 'git-commit-mode))
                 (not git-commit-mode)))
    (setq-local code-context--prev-ctx-len (length code-context--prev-ctx))
    (code-context--update
     window
     (save-excursion
       (goto-char display-start)
       (line-beginning-position)))))

(defun code-context--on-state-change (window)
  "Handler for `window-state-change-functions'."
  (when (and (buffer-file-name)
             (or (not (boundp 'git-commit-mode))
                 (not git-commit-mode)))
    (setq-local code-context--prev-ctx-len (length code-context--prev-ctx))
    (code-context--update window (window-start window))))

(defun code-context--pre-command-hook ()
  "Delete overlay before single-line scroll commands to avoid display glitches."
  (when (and (overlayp code-context--overlay)
             (memq this-command
                   '(evil-scroll-line-down
                     viper-scroll-up-one
                     scroll-up-line)))
    (delete-overlay code-context--overlay)))

(defvar-local code-context--prev-ctx-len 0
  "Length of the previous context, saved before scroll handler updates it.")

(defun code-context--post-command-hook ()
  "Compensate scroll position after scroll-up commands.
Uses cached context lengths — no recomputation."
  (when (and code-context--overlay
             (overlayp code-context--overlay)
             (overlay-buffer code-context--overlay)
             (buffer-file-name)
             (memq last-command
                   '(evil-scroll-line-up
                     viper-scroll-down-one
                     scroll-down-line)))
    (let ((cur-len (length code-context--prev-ctx)))
      (ignore-errors
        (when (> cur-len 0)
          (forward-visible-line
           (- (1+ (min (- cur-len code-context--prev-ctx-len) 0)))))))))

(defun code-context--window-resize-before (&rest _)
  "Delete overlays before window resize to prevent hangs."
  (dolist (win (window-list))
    (with-current-buffer (window-buffer win)
      (when (overlayp code-context--overlay)
        (ignore-errors (delete-overlay code-context--overlay))))))

(defun code-context--window-resize-after (&rest _)
  "Rebuild overlays after window resize."
  (dolist (window (window-list))
    (with-current-buffer (window-buffer window)
      (when (and (boundp 'code-context-mode) code-context-mode)
        (code-context--update
         window
         (save-excursion
           (goto-char (window-start window))
           (line-beginning-position)))))))

;;; Auto-enable for preview buffers

(defun code-context--maybe-enable ()
  "Auto-enable `code-context-mode' in visible prog-mode buffers.
For consult preview buffers, swap in the real file buffer so overlays work."
  (dolist (win (window-list))
    (when (window-live-p win)
      (let* ((buf (window-buffer win))
             (name (buffer-name buf)))
        ;; Swap preview buffers with the real file buffer
        (when (and (string-prefix-p " Preview:" name)
                   (buffer-file-name buf))
          (let* ((file (buffer-file-name buf))
                 (ws (window-start win)))
            ;; Dissociate file from preview buffer so find-file-noselect
            ;; creates a fresh, properly-named buffer
            (with-current-buffer buf
              (setq buffer-file-name nil
                    buffer-file-truename nil))
            (let ((real-buf (find-file-noselect file)))
              (when (and real-buf (not (eq real-buf buf)))
                (set-window-buffer win real-buf)
                (set-window-start win ws)))))
        ;; Enable mode if needed
        (with-current-buffer (window-buffer win)
          (when (and (not code-context-mode)
                     (buffer-file-name)
                     (derived-mode-p 'prog-mode))
            (code-context-mode 1)))))))

;;; Minor mode

;;;###autoload
(define-minor-mode code-context-mode
  "Show enclosing code context in a sticky overlay at window top.
Uses `syntax-ppss' to reliably skip strings and comments."
  :lighter " Ctx"
  :group 'code-context
  (if code-context-mode
      (progn
        (setq-local code-context--prev-ctx nil)
        (setq-local code-context--cached-defun-pos nil)
        (setq-local code-context--cached-context-str nil)
        (code-context--remove)

        (when (< scroll-margin (1+ code-context-n-from-top))
          (setq-local scroll-margin (1+ code-context-n-from-top)))

        (advice-add #'window-resize :before #'code-context--window-resize-before)
        (advice-add #'window-resize :after #'code-context--window-resize-after)

        (add-hook 'pre-command-hook #'code-context--pre-command-hook nil t)
        (add-hook 'post-command-hook #'code-context--post-command-hook nil t)
        (add-hook 'window-scroll-functions #'code-context--on-scroll nil t)
        (add-hook 'window-state-change-functions #'code-context--on-state-change nil t)
        ;; Global hook to auto-enable in preview windows
        (add-hook 'post-command-hook #'code-context--maybe-enable))

    ;; Disable
    (code-context--remove)
    (advice-remove #'window-resize #'code-context--window-resize-before)
    (advice-remove #'window-resize #'code-context--window-resize-after)
    (remove-hook 'pre-command-hook #'code-context--pre-command-hook t)
    (remove-hook 'post-command-hook #'code-context--post-command-hook t)
    (remove-hook 'window-scroll-functions #'code-context--on-scroll t)
    (remove-hook 'window-state-change-functions #'code-context--on-state-change t)
    (kill-local-variable 'scroll-margin)))

(provide 'code-context)
;;; code-context.el ends here
