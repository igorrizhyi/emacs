;;; my-agent-shell-keybindings.el --- Keybindings for agent-shell buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Custom keybindings for agent-shell (Claude Code Agent) buffers.
;; Also includes shared Evil fixes for eshell and shell-maker modes.

;;; Code:

(defun my/agent-shell-reset-prompt ()
  "Clear any pending context at the agent-shell prompt, leaving the input intact."
  (interactive)
  (when (and (derived-mode-p 'agent-shell-mode)
             my/agent-shell--pending-context)
    (setq my/agent-shell--pending-context nil)
    (my/agent-shell--hide-context-posframe)))

(defun my/agent-shell-insert-at-prompt ()
  "Jump to the end of the prompt and enter insert state."
  (interactive)
  (goto-char (point-max))
  (evil-insert-state))

;;; --- Evil clipboard fixes for eshell / shell-maker modes ---

(defun my/backward-kill-word-no-clipboard ()
  "Kill word backward without affecting system clipboard."
  (interactive)
  (let ((interprogram-cut-function nil))
    (backward-kill-word 1)))

(defun my/eshell-dd ()
  "Delete the editable portion of the current eshell line (dd equivalent).
Only deletes from the end of the prompt to end of line, respecting
read-only prompt regions."
  (interactive)
  (if (derived-mode-p 'eshell-mode)
      (save-excursion
        (let ((bol (progn (eshell-bol) (point)))
              (eol (progn (end-of-line) (point))))
          (when (> eol bol)
            (delete-region bol eol))))
    ;; Fallback for non-eshell: standard dd
    (evil-delete-whole-line)))

(defun my/shell-maker-dd ()
  "Delete the editable portion of the current shell-maker line (dd equivalent).
Deletes from after the prompt to end of line."
  (interactive)
  (save-excursion
    (let* ((eol (progn (end-of-line) (point)))
           (bol (progn (beginning-of-line)
                       ;; Skip past any read-only prompt text
                       (let ((p (point)))
                         (while (and (< p eol)
                                     (get-text-property p 'read-only))
                           (setq p (next-single-property-change p 'read-only nil eol)))
                         p))))
      (when (> eol bol)
        (delete-region bol eol)))))

(defun my/delete-selection-no-clipboard ()
  "Delete visual selection without affecting system clipboard."
  (interactive)
  (let ((interprogram-cut-function nil))
    (delete-region (region-beginning) (region-end)))
  (evil-normal-state))

;;; --- Apply keybindings ---

(with-eval-after-load 'agent-shell
  (define-key agent-shell-mode-map (kbd "C-c x") #'my/agent-shell-reset-prompt)
  (evil-define-key 'normal agent-shell-mode-map "i" #'my/agent-shell-insert-at-prompt))

;; Shell-maker mode bindings (covers agent-shell)
(with-eval-after-load 'shell-maker
  (evil-define-key 'insert shell-maker-mode-map (kbd "C-<backspace>") #'my/backward-kill-word-no-clipboard)
  (evil-define-key 'normal shell-maker-mode-map "dd" #'my/shell-maker-dd)
  (evil-define-key 'visual shell-maker-mode-map "x" #'my/delete-selection-no-clipboard))

;; Eshell mode bindings
(with-eval-after-load 'eshell
  (evil-define-key 'insert eshell-mode-map (kbd "C-<backspace>") #'my/backward-kill-word-no-clipboard)
  (evil-define-key 'normal eshell-mode-map "dd" #'my/eshell-dd)
  (evil-define-key 'visual eshell-mode-map "x" #'my/delete-selection-no-clipboard))

(provide 'my-agent-shell-keybindings)
;;; my-agent-shell-keybindings.el ends here
