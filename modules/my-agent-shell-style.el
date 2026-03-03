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
  (let ((block-start (or (map-nested-elt range '(:block :start))
                         (map-nested-elt range '(:label-left :start))
                         (map-nested-elt range '(:label-right :start))
                         (map-nested-elt range '(:body :start))))
        (block-end (or (map-nested-elt range '(:block :end))
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
          (overlay-put ov 'evaporate nil)
          (overlay-put ov 'my-agent-shell-output t)
          (setq my/agent-shell--last-overlay ov))))))

(provide 'my-agent-shell-style)
;;; my-agent-shell-style.el ends here
