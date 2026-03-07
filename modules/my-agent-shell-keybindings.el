;;; my-agent-shell-keybindings.el --- Keybindings for agent-shell buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Custom keybindings for agent-shell (Claude Code Agent) buffers.

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

(with-eval-after-load 'agent-shell
  (define-key agent-shell-mode-map (kbd "C-c x") #'my/agent-shell-reset-prompt)
  (evil-define-key 'normal agent-shell-mode-map "i" #'my/agent-shell-insert-at-prompt))

(provide 'my-agent-shell-keybindings)
;;; my-agent-shell-keybindings.el ends here
