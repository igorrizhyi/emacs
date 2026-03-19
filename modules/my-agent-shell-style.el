;;; my-agent-shell-style.el --- Custom styling for agent-shell buffers -*- lexical-binding: t; -*-

(require 'map)

;; --- Output section styling ---

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

;; --- Context posframe styling ---

(defvar my/agent-shell-context-face
  (list :font (font-spec :family "SF Mono" :weight 'semibold)
        :height 0.75
        :inherit nil
        :background "#1a2a37"
        :extend t)
  "Face for agent-shell context blocks.")

(defvar my/agent-shell--context-posframe-buffer " *agent-shell-context*"
  "Buffer name for the context posframe.")

(defvar-local my/agent-shell--pending-context nil
  "Plist (:text) of context awaiting submission.")

(defun my/agent-shell--show-context-posframe (text buffer)
  "Show TEXT in a posframe anchored to BUFFER's window."
  (if (or (null text) (string-blank-p text))
      (my/agent-shell--hide-context-posframe)
    (require 'posframe)
    (let ((posframe-buf (get-buffer-create my/agent-shell--context-posframe-buffer)))
      (with-current-buffer posframe-buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize " " 'face `(:height 0.3 :background "#1a2a37" :extend t))
                  "\n"
                  (propertize (replace-regexp-in-string "^" "  " text)
                              'face my/agent-shell-context-face)
                  "\n"
                  (propertize " " 'face `(:height 0.3 :background "#1a2a37" :extend t)))))
      (when-let ((win (get-buffer-window buffer)))
        (with-selected-window win
          (posframe-show posframe-buf
                         :position (point-max)
                         :poshandler #'posframe-poshandler-window-top-center
                         :border-width 1
                         :border-color "#3a5a6a"
                         :background-color "#1a2a37"
                         :min-width 60
                         :internal-border-width 12
                         :lines-truncate t
                         :accept-focus nil))))))

(defun my/agent-shell--hide-context-posframe ()
  "Hide the context posframe."
  (when (fboundp 'posframe-hide)
    (posframe-hide my/agent-shell--context-posframe-buffer)))

(defun my/agent-shell--apply-context-overlay (start end)
  "Apply context face overlay on text from START to END."
  (let* ((face my/agent-shell-context-face)
         (padding (propertize "  " 'face face))
         (ov (make-overlay start end nil t nil)))
    (overlay-put ov 'face face)
    (overlay-put ov 'line-prefix padding)
    (overlay-put ov 'wrap-prefix padding)
    (overlay-put ov 'after-string (propertize "\n" 'face face))
    (overlay-put ov 'evaporate nil)
    (overlay-put ov 'my-agent-shell-context t)))

(defun my/agent-shell-context-advice (result)
  "After-advice: intercept context, remove from buffer, show in posframe."
  (when (and result (listp result))
    (let* ((buffer (alist-get :buffer result))
           (start (alist-get :start result))
           (end (alist-get :end result)))
      (when (and buffer start end (buffer-live-p buffer))
        (with-current-buffer buffer
          ;; Extract clean context text (skip \n\n prefix)
          (let ((text (save-excursion
                        (goto-char start)
                        (skip-chars-forward "\n\t " end)
                        (string-trim
                         (buffer-substring-no-properties (point) end)))))
            ;; Delete the context from the buffer (keep prompt clean)
            (let ((inhibit-read-only t))
              ;; Remove ALL overlays in and around the region
              (dolist (ov (overlays-in (max (point-min) (1- start))
                                       (min (point-max) (1+ end))))
                (delete-overlay ov))
              (delete-region start end)
              ;; Nuclear cleanup: remove any overlays touching deletion point
              (let ((cleanup-pos (min start (point-max))))
                (dolist (ov (overlays-at cleanup-pos))
                  (delete-overlay ov))
                (when (> cleanup-pos (point-min))
                  (dolist (ov (overlays-at (1- cleanup-pos)))
                    (delete-overlay ov)))))
            ;; Store for submission
            (setq my/agent-shell--pending-context (list :text text))
            ;; Show posframe
            (my/agent-shell--show-context-posframe text buffer))))))
  result)

(defvar my/agent-shell--context-marker-start "«CTX»"
  "Start marker for context blocks in shell history.")

(defvar my/agent-shell--context-marker-end "«/CTX»"
  "End marker for context blocks in shell history.")

(defun my/agent-shell-on-submit (&rest _args)
  "On submission: hide posframe, append context with markers."
  (when (and (derived-mode-p 'agent-shell-mode)
             my/agent-shell--pending-context)
    (my/agent-shell--hide-context-posframe)
    (let* ((ctx my/agent-shell--pending-context)
           (text (plist-get ctx :text))
           (inhibit-read-only t))
      (when text
        (save-excursion
          (goto-char (point-max))
          (insert "\n\n" my/agent-shell--context-marker-start
                  "\n" text "\n\n"
                  my/agent-shell--context-marker-end))))
    (setq my/agent-shell--pending-context nil)))

(defun my/agent-shell--style-context-markers ()
  "Scan buffer for context markers and apply faces.
Skips regions already styled.  Safe to call repeatedly."
  (save-excursion
    (goto-char (point-min))
    (let ((marker-start my/agent-shell--context-marker-start)
          (marker-end my/agent-shell--context-marker-end))
      (while (search-forward marker-start nil t)
        (let ((m-start (match-beginning 0))
              (ctx-start (match-end 0)))
          (when (search-forward marker-end nil t)
            (let ((ctx-end (match-beginning 0))
                  (m-end (match-end 0)))
              ;; Only add overlays if not already styled
              (unless (cl-some (lambda (ov) (overlay-get ov 'my-agent-shell-context))
                               (overlays-in m-start m-end))
                ;; Hide start marker + its trailing newline
                (let ((ov-ms (make-overlay m-start ctx-start nil t nil)))
                  (overlay-put ov-ms 'invisible t)
                  (overlay-put ov-ms 'my-agent-shell-context t))
                ;; Hide end marker + trailing newlines (not the \n before it)
                (let* ((hide-start ctx-end)
                       (hide-end (save-excursion
                                   (goto-char m-end)
                                   (skip-chars-forward "\n")
                                   (point)))
                       (ov-me (make-overlay hide-start hide-end nil t nil)))
                  (overlay-put ov-me 'invisible t)
                  (overlay-put ov-me 'my-agent-shell-context t))
                ;; Style the context body (up to ctx-end so all \n get background)
                (my/agent-shell--apply-context-overlay ctx-start ctx-end)))))))))

;; --- Team message styling ---

(defvar my/agent-shell-team-message-face
  (list :font (font-spec :family "SF Mono" :weight 'semibold)
        :height 0.75
        :inherit nil
        :background "#2a1a37"
        :extend t)
  "Face for team-injected messages in agent-shell buffers (default/researcher).")

(defvar my/agent-shell-team-message-dev-face
  (list :font (font-spec :family "SF Mono" :weight 'semibold)
        :height 0.75
        :inherit nil
        :background "#371a2a"
        :extend t)
  "Face for dev role team messages in agent-shell buffers.")

(defvar my/agent-shell--team-msg-marker-start "«TEAM»"
  "Start marker for team messages in shell history.")

(defvar my/agent-shell--team-msg-marker-end "«/TEAM»"
  "End marker for team messages in shell history.")

(defun my/agent-shell--apply-team-message-overlay (start end &optional face)
  "Apply team message face overlay on text from START to END.
Optional FACE overrides the default team message face."
  (let* ((face (or face my/agent-shell-team-message-face))
         (padding (propertize "  " 'face face))
         (ov (make-overlay start end nil t nil)))
    (overlay-put ov 'face face)
    (overlay-put ov 'line-prefix padding)
    (overlay-put ov 'wrap-prefix padding)
    (overlay-put ov 'before-string "\n")
    (overlay-put ov 'after-string "\n")
    (overlay-put ov 'priority 100)
    (overlay-put ov 'evaporate nil)
    (overlay-put ov 'my-agent-shell-team-msg t)))

(defun my/agent-shell--style-team-message-markers ()
  "Scan buffer for team message markers and apply faces."
  (save-excursion
    (goto-char (point-min))
    (while (search-forward my/agent-shell--team-msg-marker-start nil t)
      (let ((m-start (match-beginning 0))
            (content-start (match-end 0)))
        (when (search-forward my/agent-shell--team-msg-marker-end nil t)
          (let ((content-end (match-beginning 0))
                (m-end (match-end 0)))
            (unless (cl-some (lambda (ov) (overlay-get ov 'my-agent-shell-team-msg))
                             (overlays-in m-start m-end))
              ;; Hide start marker AND the following newline so the
              ;; Claude> prompt line doesn't get the purple background.
              (let* ((hide-end (save-excursion
                                 (goto-char content-start)
                                 (skip-chars-forward "\n")
                                 (point)))
                     (ov-ms (make-overlay m-start hide-end nil t nil)))
                (overlay-put ov-ms 'invisible t)
                (overlay-put ov-ms 'my-agent-shell-team-msg t)
                ;; Detect role from content to pick per-role face
                (let* ((text (buffer-substring-no-properties hide-end content-end))
                       (role (when (string-match "\nRole: \\(\\w+\\)" text)
                               (match-string 1 text)))
                       (face (pcase role
                               ("dev" my/agent-shell-team-message-dev-face)
                               (_ my/agent-shell-team-message-face))))
                  ;; Style the content body (starting after the hidden newline)
                  (my/agent-shell--apply-team-message-overlay hide-end content-end face)))
              ;; Hide end marker + trailing newlines
              (let* ((hide-start content-end)
                     (hide-end (save-excursion
                                 (goto-char m-end)
                                 (skip-chars-forward "\n")
                                 (point)))
                     (ov-me (make-overlay hide-start hide-end nil t nil)))
                (overlay-put ov-me 'invisible t)
                (overlay-put ov-me 'my-agent-shell-team-msg t)))))))))

(defun my/agent-shell--maybe-style-context ()
  "Post-command hook: style markers in agent-shell buffers."
  (if (derived-mode-p 'agent-shell-mode)
      (progn
        (my/agent-shell--style-context-markers)
        (my/agent-shell--style-team-message-markers))
    (my/agent-shell--hide-context-posframe)))

(with-eval-after-load 'agent-shell
  ;; Intercept context insertion: remove from buffer, show in posframe
  (advice-add 'agent-shell--insert-to-shell-buffer
              :filter-return #'my/agent-shell-context-advice)
  ;; On submit: append context with markers
  (advice-add 'shell-maker-submit :before #'my/agent-shell-on-submit)
  ;; Style markers on every command loop iteration (cheap — skips if already styled)
  (add-hook 'post-command-hook #'my/agent-shell--maybe-style-context))

(provide 'my-agent-shell-style)
;;; my-agent-shell-style.el ends here
