;;; my-agent-shell-style.el --- Custom styling for agent-shell buffers -*- lexical-binding: t; -*-

(require 'map)

(defvar my/agent-shell-output-face
  (list :font (font-spec :family "SF Mono" :weight 'semibold)
        :height 0.75
        :inherit nil
        :background "#372413"
        :extend t)
  "Face for all agent-shell output (labels + body), matching eshell terminal style.")

(defvar-local my/agent-shell--last-overlay nil
  "Last output overlay created, for merging adjacent sections.")

(defun my/agent-shell-style-sections (range)
  "Apply custom styling to agent-shell sections, merging adjacent blocks."
  ;; Use :block range for full coverage, fall back to labels/body
  ;; Include :padding range to cover agent-shell's own spacing
  (let ((block-start (or (map-nested-elt range '(:block :start))
                         (map-nested-elt range '(:padding :start))
                         (map-nested-elt range '(:label-left :start))
                         (map-nested-elt range '(:label-right :start))
                         (map-nested-elt range '(:body :start))))
        (block-end (or (map-nested-elt range '(:padding :end))
                       (map-nested-elt range '(:block :end))
                       (map-nested-elt range '(:body :end))
                       (map-nested-elt range '(:label-right :end))
                       (map-nested-elt range '(:label-left :end)))))
    (when (and block-start block-end)
      ;; Check if we can extend the previous overlay
      ;; Use generous gap (padding/newlines between fragments can be large)
      (if (and my/agent-shell--last-overlay
               (overlay-buffer my/agent-shell--last-overlay)
               (<= block-start (+ (overlay-end my/agent-shell--last-overlay) 20)))
          ;; Extend existing overlay to cover the gap too
          (move-overlay my/agent-shell--last-overlay
                        (overlay-start my/agent-shell--last-overlay)
                        (max block-end (overlay-end my/agent-shell--last-overlay)))
        ;; Create new overlay
        (let* ((face my/agent-shell-output-face)
               (padding (propertize "  " 'face face))
               (ov (make-overlay block-start block-end nil nil nil)))
          (overlay-put ov 'face face)
          (overlay-put ov 'line-prefix padding)
          (overlay-put ov 'wrap-prefix padding)
          (overlay-put ov 'before-string (propertize "\n" 'face face))
          (overlay-put ov 'after-string "\n")
          (overlay-put ov 'evaporate nil)
          (overlay-put ov 'my-agent-shell-output t)
          (setq my/agent-shell--last-overlay ov))))))

(defvar my/agent-shell-context-face
  (list :font (font-spec :family "SF Mono" :weight 'semibold)
        :height 0.75
        :inherit nil
        :background "#1a2a37"
        :extend t)
  "Face for agent-shell context blocks (inserted when switching from a buffer).")

(defun my/agent-shell--apply-context-overlay (content-start content-end)
  "Create a context overlay from CONTENT-START to CONTENT-END."
  (let* ((face my/agent-shell-context-face)
         (padding (propertize "  " 'face face))
         (ov (make-overlay content-start content-end nil nil nil)))
    (overlay-put ov 'face face)
    (overlay-put ov 'line-prefix padding)
    (overlay-put ov 'wrap-prefix padding)
    (overlay-put ov 'before-string (propertize "\n" 'face face))
    (overlay-put ov 'after-string (propertize "\n" 'face face))
    (overlay-put ov 'evaporate nil)
    (overlay-put ov 'my-agent-shell-context t)))

(defun my/agent-shell-style-context (start end buffer)
  "Apply context styling overlay from START to END in BUFFER."
  (when (and start end buffer (buffer-live-p buffer))
    (with-current-buffer buffer
      (save-excursion
        ;; Skip leading whitespace/newlines to find actual content
        (goto-char start)
        (skip-chars-forward "\n\t " end)
        (let* ((content-start (line-beginning-position))
               (content-end (progn (goto-char end)
                                   (skip-chars-backward "\n\t " content-start)
                                   (line-end-position))))
          ;; Mark the text so we can restore overlays after submission
          (let ((inhibit-read-only t))
            (put-text-property content-start content-end
                               'my-agent-shell-context-region t))
          (my/agent-shell--apply-context-overlay content-start content-end))))))

(defun my/agent-shell-restore-context-overlays (&rest _args)
  "Restore context overlays on text marked with `my-agent-shell-context-region'."
  (when (derived-mode-p 'agent-shell-mode)
    (save-excursion
      (goto-char (point-min))
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (let ((next-change (next-single-property-change pos 'my-agent-shell-context-region nil (point-max))))
            (when (get-text-property pos 'my-agent-shell-context-region)
              ;; Check if there's already an overlay here
              (unless (cl-some (lambda (ov) (overlay-get ov 'my-agent-shell-context))
                               (overlays-at pos))
                (my/agent-shell--apply-context-overlay pos next-change)))
            (setq pos next-change)))))))

(defun my/agent-shell-style-context-advice (result)
  "After-advice for `agent-shell--insert-to-shell-buffer' to style context."
  (when result
    (let ((buffer (alist-get :buffer result))
          (start (alist-get :start result))
          (end (alist-get :end result)))
      (my/agent-shell-style-context start end buffer)))
  result)

(with-eval-after-load 'agent-shell
  (advice-add 'agent-shell--insert-to-shell-buffer
              :filter-return #'my/agent-shell-style-context-advice)
  (add-hook 'comint-output-filter-functions #'my/agent-shell-restore-context-overlays))

(provide 'my-agent-shell-style)
;;; my-agent-shell-style.el ends here
