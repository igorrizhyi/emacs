;;; my-agent-shell-compose.el --- Posframe-based prompt composition for agent-shell -*- lexical-binding: t; -*-

(require 'posframe)

(defvar my/agent-shell-compose-buffer-name " *agent-shell-compose*"
  "Buffer name for the compose posframe.")

(defvar-local my/agent-shell-compose--target-buffer nil
  "The agent-shell buffer to submit the composed prompt to.")

(defvar my/agent-shell-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-<return>") #'my/agent-shell-compose-submit)
    (define-key map (kbd "C-c C-c") #'my/agent-shell-compose-submit)
    (define-key map (kbd "C-c C-k") #'my/agent-shell-compose-cancel)
    (define-key map (kbd "<escape>") #'my/agent-shell-compose-cancel)
    map)
  "Keymap for `my/agent-shell-compose-mode'.")

(define-minor-mode my/agent-shell-compose-mode
  "Minor mode for composing agent-shell prompts in a posframe."
  :lighter " Compose"
  :keymap my/agent-shell-compose-mode-map
  (when my/agent-shell-compose-mode
    (setq header-line-format " Compose prompt (C-RET send, ESC cancel) ")))

(defun my/agent-shell-compose-popup ()
  "Open a posframe for composing a prompt to submit to the current agent-shell buffer."
  (interactive)
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Not in an agent-shell buffer"))
  (let ((target (current-buffer))
        (buf (get-buffer-create my/agent-shell-compose-buffer-name)))
    (with-current-buffer buf
      (erase-buffer)
      (text-mode)
      (my/agent-shell-compose-mode 1)
      (setq my/agent-shell-compose--target-buffer target))
    ;; Hide context posframe if present
    (when (fboundp 'my/agent-shell--hide-context-posframe)
      (my/agent-shell--hide-context-posframe))
    (let ((frame (posframe-show buf
                                :position (point-max)
                                :poshandler #'posframe-poshandler-window-bottom-center
                                :accept-focus t
                                :font (format "%s-%d"
                                              (face-attribute 'default :family)
                                              (max 8 (/ (face-attribute 'default :height) 10 2)))
                                :border-width 1
                                :border-color "#3a7a9a"
                                :background-color "#1a2a37"
                                :foreground-color "#c0d0e0"
                                :min-width 80
                                :min-height 6
                                :internal-border-width 12
                                :respect-header-line t
                                :lines-truncate nil)))
      (select-frame-set-input-focus frame)
      (select-window (frame-root-window frame))
      (setq cursor-type 'box))))

(defun my/agent-shell-compose-submit ()
  "Submit the composed prompt to the target agent-shell buffer."
  (interactive)
  (let ((text (string-trim (buffer-string)))
        (target my/agent-shell-compose--target-buffer))
    (if (string-empty-p text)
        (my/agent-shell-compose-cancel)
      (unless (buffer-live-p target)
        (user-error "Target shell buffer no longer exists"))
      (when (with-current-buffer target (shell-maker-busy))
        (user-error "Shell is busy, try later"))
      (let ((parent (frame-parent (selected-frame))))
        (posframe-hide my/agent-shell-compose-buffer-name)
        (when parent
          (select-frame-set-input-focus parent)
          (if-let ((win (get-buffer-window target)))
              (select-window win)
            (select-window (frame-selected-window parent)))))
      ;; Restore context posframe if pending context exists
      (when (and (boundp 'my/agent-shell--pending-context)
                 (buffer-local-value 'my/agent-shell--pending-context target)
                 (fboundp 'my/agent-shell--show-context-posframe))
        (my/agent-shell--show-context-posframe
         (plist-get (buffer-local-value 'my/agent-shell--pending-context target) :text)
         target))
      (with-current-buffer target
        (shell-maker-submit :input text)))))

(defun my/agent-shell-compose-cancel ()
  "Cancel composition and return to the agent-shell buffer."
  (interactive)
  (let ((target my/agent-shell-compose--target-buffer)
        (parent (frame-parent (selected-frame))))
    (posframe-hide my/agent-shell-compose-buffer-name)
    (when parent
      (select-frame-set-input-focus parent)
      (if (and target (buffer-live-p target)
               (get-buffer-window target))
          (select-window (get-buffer-window target))
        (select-window (frame-selected-window parent))))
    ;; Restore context posframe if pending context exists
    (when (and target (buffer-live-p target)
               (boundp 'my/agent-shell--pending-context)
               (buffer-local-value 'my/agent-shell--pending-context target)
               (fboundp 'my/agent-shell--show-context-posframe))
      (my/agent-shell--show-context-posframe
       (plist-get (buffer-local-value 'my/agent-shell--pending-context target) :text)
       target))))

(with-eval-after-load 'agent-shell
  (define-key agent-shell-mode-map (kbd "C-<return>") #'my/agent-shell-compose-popup))

(provide 'my-agent-shell-compose)
;;; my-agent-shell-compose.el ends here
