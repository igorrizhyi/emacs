;;; my-agent-shell-sidebar.el --- Team sidebar for agent-shell lead buffer -*- lexical-binding: t; -*-

;; Author: Igor Rizhyi
;; Keywords: tools, ai, team

;;; Commentary:

;; Buffer-specific sidebar that auto-shows/hides when switching to/from
;; the lead agent shell buffer.  Displays team status with keyboard
;; navigation and an inline prompt mode.

;;; Code:

(require 'cl-lib)

(declare-function shell-maker-submit "shell-maker")
(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-emacs-state "evil-states")
(declare-function evil-normal-state "evil-states")
(defvar agent-shell-team--sessions)
(declare-function agent-shell-team--agent-status "agent-shell-team")
(declare-function agent-shell-team--short-session-id "agent-shell-team")
(declare-function my/agent-shell-compose-popup "my-agent-shell-compose")
(defvar agent-shell-team--task-queue)
(defvar agent-shell-team--message-queue)
(defvar agent-shell-team--request-to-buffer)
(defvar agent-shell-team--task-groups)
(defvar agent-shell-team--request-to-group)

;;; ---- Constants & Buffer Name ------------------------------------------------

(defconst my/team-sidebar-buffer-name " *team-sidebar*"
  "Space-prefixed to hide from ibuffer.")

(defconst my/team-sidebar-width 40
  "Width of the sidebar window in columns.")

;;; ---- Faces ------------------------------------------------------------------

(defface my/team-sidebar-session-face
  '((t :weight bold :height 1.05))
  "Face for session headers in the team sidebar.")

(defface my/team-sidebar-role-face
  '((t :weight bold))
  "Face for agent role labels.")

(defface my/team-sidebar-status-idle
  '((t :foreground "#6ae46a"))
  "Face for idle status.")

(defface my/team-sidebar-status-busy
  '((t :foreground "#e4c96a"))
  "Face for busy status.")

(defface my/team-sidebar-status-init
  '((t :foreground "#6ab0e4"))
  "Face for initializing status.")

(defface my/team-sidebar-status-dead
  '((t :foreground "#e46a6a"))
  "Face for dead status.")

;;; ---- Sidebar Buffer Local State ---------------------------------------------

(defvar-local my/team-sidebar--session-id nil
  "Session ID associated with this sidebar buffer.")

(defvar-local my/team-sidebar--refresh-timer nil
  "Timer for periodic refresh.")

;;; ---- Utility ----------------------------------------------------------------

(defun my/team-sidebar--lead-buffer-p (buf)
  "Return non-nil if BUF is a team lead buffer."
  (and (buffer-live-p buf)
       (string-match-p "\\*team:[a-z0-9]\\{4\\}:lead:" (buffer-name buf))))

(defun my/team-sidebar--any-lead-visible-p ()
  "Return the first visible lead buffer in the selected frame, or nil."
  (cl-loop for win in (window-list nil 'no-minibuf)
           for buf = (window-buffer win)
           when (my/team-sidebar--lead-buffer-p buf)
           return buf))

(defun my/team-sidebar--session-id-from-lead (buf)
  "Extract session-id from a lead BUF via `agent-shell-team--sessions'."
  (when (and (boundp 'agent-shell-team--sessions) (buffer-live-p buf))
    (catch 'found
      (maphash (lambda (sid agents)
                 (cl-loop for agent in agents
                          when (and (equal (alist-get 'role agent) "lead")
                                    (eq (alist-get 'buffer agent) buf))
                          do (throw 'found sid)))
               agent-shell-team--sessions)
      nil)))

(defun my/team-sidebar--find-lead-buffer (session-id)
  "Find the lead buffer for SESSION-ID."
  (when (and session-id (boundp 'agent-shell-team--sessions))
    (let ((agents (gethash session-id agent-shell-team--sessions)))
      (cl-loop for agent in agents
               when (equal (alist-get 'role agent) "lead")
               return (alist-get 'buffer agent)))))

;;; ---- Status Rendering -------------------------------------------------------

(defun my/team-sidebar--status-indicator (status)
  "Return a string indicator for agent STATUS symbol."
  (pcase status
    ('idle  (propertize "●" 'face 'my/team-sidebar-status-idle))
    ('busy  (propertize "◉" 'face 'my/team-sidebar-status-busy))
    ('initializing (propertize "○" 'face 'my/team-sidebar-status-init))
    ('dead  (propertize "✕" 'face 'my/team-sidebar-status-dead))
    (_      "?")))

(defun my/team-sidebar--render ()
  "Render team status into the sidebar buffer."
  (let ((buf (get-buffer my/team-sidebar-buffer-name)))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (pos (point)))
          ;; Preserve prompt block if present
          (let ((prompt-end (my/team-sidebar--prompt-region-end)))
            (goto-char (or prompt-end (point-min)))
            (delete-region (point) (point-max))
            (my/team-sidebar--insert-status)
            (goto-char (min pos (point-max)))))))))

(defun my/team-sidebar--prompt-region-end ()
  "Return end of the prompt region at top of buffer, or nil if none."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "```")
      ;; Find the closing ```
      (forward-line 1)
      (if (re-search-forward "^```$" nil t)
          (progn (forward-line 1) (point))
        ;; Unclosed block — include everything to end of buffer? No, return nil.
        nil))))

(defun my/team-sidebar--insert-status ()
  "Insert team status content at point."
  (let ((has-content nil))
    (when (boundp 'agent-shell-team--sessions)
      (maphash
       (lambda (sid agents)
         (let ((short (if (fboundp 'agent-shell-team--short-session-id)
                          (agent-shell-team--short-session-id sid)
                        (substring sid 0 4))))
           (insert (propertize (format " Session: %s" short)
                               'face 'my/team-sidebar-session-face)
                   "\n")
           (dolist (agent agents)
             (let* ((role (or (alist-get 'role agent) "?"))
                    (buffer (alist-get 'buffer agent))
                    (wt-name (or (alist-get 'worktree-name agent) "main"))
                    (status (if (fboundp 'agent-shell-team--agent-status)
                                (agent-shell-team--agent-status buffer)
                              'dead))
                    (indicator (my/team-sidebar--status-indicator status)))
               (insert (format "  %s %-10s %s  %s\n"
                               indicator
                               (propertize role 'face 'my/team-sidebar-role-face)
                               (propertize wt-name 'face 'font-lock-comment-face)
                               (propertize (symbol-name status)
                                           'face 'font-lock-type-face)))
               ;; Store agent data as text property for navigation
               (put-text-property (line-beginning-position 0)
                                  (line-end-position 0)
                                  'my/sidebar-agent agent)
               ;; Show current task for busy agents
               (when (and (eq status 'busy)
                          (boundp 'agent-shell-team--request-to-buffer))
                 (let ((req-id (cl-loop for k being the hash-keys of agent-shell-team--request-to-buffer
                                        using (hash-values v)
                                        when (eq v buffer) return k)))
                   (when req-id
                     (insert (format "    └ %s\n"
                                     (propertize req-id 'face 'font-lock-comment-face))))))))
           (insert "\n")
           (setq has-content t)))
       agent-shell-team--sessions))
    ;; Task queue
    (when (and (boundp 'agent-shell-team--task-queue)
               agent-shell-team--task-queue)
      (insert (propertize " Pending Tasks" 'face 'my/team-sidebar-session-face) "\n")
      (dolist (task agent-shell-team--task-queue)
        (insert (format "  ⏳ %s: %s\n"
                        (propertize (or (plist-get task :role) "?")
                                    'face 'my/team-sidebar-role-face)
                        (truncate-string-to-width
                         (or (plist-get task :message) "") 30 nil nil "…"))))
      (insert "\n")
      (setq has-content t))
    ;; Message queue for lead
    (when (and (boundp 'agent-shell-team--message-queue)
               (hash-table-p agent-shell-team--message-queue))
      (let ((lead-buf (my/team-sidebar--find-lead-buffer my/team-sidebar--session-id)))
        (when lead-buf
          (let ((msgs (gethash lead-buf agent-shell-team--message-queue)))
            (when msgs
              (insert (propertize (format " Queued Messages (%d)" (length msgs))
                                  'face 'my/team-sidebar-session-face) "\n")
              (dolist (msg msgs)
                (let* ((title (or (plist-get msg :title) "?"))
                       (body (or (plist-get msg :message) ""))
                       (first-line (car (split-string body "\n" t))))
                  (insert (format "  %s %s\n"
                                  (propertize title 'face 'my/team-sidebar-role-face)
                                  (truncate-string-to-width
                                   (or first-line "") 25 nil nil "…")))))
              (insert "\n")
              (setq has-content t))))))
    ;; Group progress
    (when (and (boundp 'agent-shell-team--task-groups)
               (hash-table-p agent-shell-team--task-groups)
               (> (hash-table-count agent-shell-team--task-groups) 0))
      (let ((group-content nil))
        (maphash (lambda (gid group)
                   (when (equal (plist-get group :session-id) my/team-sidebar--session-id)
                     (let ((pending (length (plist-get group :pending)))
                           (completed (length (plist-get group :completed))))
                       (push (format "  %s %d/%d\n"
                                     (propertize (truncate-string-to-width gid 20 nil nil "…")
                                                 'face 'font-lock-comment-face)
                                     completed (+ pending completed))
                             group-content))))
                 agent-shell-team--task-groups)
        (when group-content
          (insert (propertize " Groups" 'face 'my/team-sidebar-session-face) "\n")
          (dolist (line (nreverse group-content))
            (insert line))
          (insert "\n")
          (setq has-content t))))
    (unless has-content
      (insert "\n  No active sessions.\n"))))

;;; ---- Major Mode -------------------------------------------------------------

(defvar my/team-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" #'my/team-sidebar-next-agent)
    (define-key map "p" #'my/team-sidebar-prev-agent)
    (define-key map (kbd "RET") #'my/team-sidebar-switch-to-agent)
    (define-key map "k" #'my/team-sidebar-kill-agent)
    (define-key map "q" #'my/team-sidebar-quit)
    (define-key map "g" #'my/team-sidebar-refresh)
    (define-key map "i" #'my/team-sidebar-prompt)
    (define-key map (kbd "C-<return>") #'my/team-sidebar-compose)
    map)
  "Keymap for `my/team-sidebar-mode'.")

(define-derived-mode my/team-sidebar-mode special-mode "TeamSidebar"
  "Major mode for the team agent sidebar."
  :interactive nil
  (setq cursor-type 'bar
        truncate-lines t
        buffer-read-only t
        header-line-format (propertize " Team Dashboard" 'face 'bold)
        mode-line-format nil)
  (setq-local face-remapping-alist
              '((default (:background "#1a2232" :foreground "#a0b0c0"))
                (header-line (:background "#1a2232" :foreground "#c0d0e0"
                               :weight bold :box nil)))))

;; Evil-mode integration: bind keys in normal state so they take priority
(when (fboundp 'evil-define-key*)
  (evil-define-key* 'normal my/team-sidebar-mode-map
    "n" #'my/team-sidebar-next-agent
    "p" #'my/team-sidebar-prev-agent
    (kbd "RET") #'my/team-sidebar-switch-to-agent
    "k" #'my/team-sidebar-kill-agent
    "q" #'my/team-sidebar-quit
    "g" #'my/team-sidebar-refresh
    "i" #'my/team-sidebar-prompt
    (kbd "C-<return>") #'my/team-sidebar-compose))

;; Open sidebar in normal state (not motion state from special-mode parent)
(when (fboundp 'evil-set-initial-state)
  (evil-set-initial-state 'my/team-sidebar-mode 'normal))

;;; ---- Navigation Commands ----------------------------------------------------

(defun my/team-sidebar--agent-at-point ()
  "Return the agent alist at point, or nil."
  (get-text-property (line-beginning-position) 'my/sidebar-agent))

(defun my/team-sidebar--preview-agent ()
  "Display the agent buffer at point in a non-sidebar window without selecting it."
  (let ((agent (my/team-sidebar--agent-at-point)))
    (when agent
      (let ((buf (alist-get 'buffer agent)))
        (when (buffer-live-p buf)
          (let ((window-buffer-change-functions nil)
                (window-selection-change-functions nil))
            (display-buffer buf '(display-buffer-use-some-window
                                  (inhibit-same-window . t)))))))))

(defun my/team-sidebar-next-agent ()
  "Move to next agent line and preview its buffer."
  (interactive)
  (let ((start (point)))
    (forward-line 1)
    (while (and (not (eobp))
                (not (get-text-property (line-beginning-position) 'my/sidebar-agent)))
      (forward-line 1))
    (if (eobp)
        (goto-char start)
      (my/team-sidebar--preview-agent))))

(defun my/team-sidebar-prev-agent ()
  "Move to previous agent line and preview its buffer."
  (interactive)
  (let ((start (point)))
    (forward-line -1)
    (while (and (not (bobp))
                (not (get-text-property (line-beginning-position) 'my/sidebar-agent)))
      (forward-line -1))
    (if (and (bobp)
             (not (get-text-property (line-beginning-position) 'my/sidebar-agent)))
        (goto-char start)
      (my/team-sidebar--preview-agent))))

(defun my/team-sidebar-switch-to-agent ()
  "Switch to the agent buffer on the current line."
  (interactive)
  (let ((agent (my/team-sidebar--agent-at-point)))
    (if agent
        (let ((buf (alist-get 'buffer agent)))
          (if (buffer-live-p buf)
              (select-window
               (or (get-buffer-window buf)
                   (display-buffer buf '(display-buffer-use-some-window
                                         (inhibit-same-window . t)))))
            (message "Agent buffer is dead.")))
      (message "No agent on this line."))))

(defun my/team-sidebar-kill-agent ()
  "Kill/dismiss the agent under cursor."
  (interactive)
  (let ((agent (my/team-sidebar--agent-at-point)))
    (if agent
        (let ((buf (alist-get 'buffer agent))
              (role (alist-get 'role agent)))
          (when (yes-or-no-p (format "Kill %s agent? " role))
            (when (buffer-live-p buf)
              (kill-buffer buf))
            (my/team-sidebar-refresh)))
      (message "No agent on this line."))))

(defun my/team-sidebar-quit ()
  "Hide the sidebar without killing the buffer."
  (interactive)
  (let ((win (get-buffer-window my/team-sidebar-buffer-name)))
    (when win
      (delete-window win))))

(defun my/team-sidebar-refresh ()
  "Manually refresh the sidebar content."
  (interactive)
  (my/team-sidebar--render))

;;; ---- Inline Prompt Mode -----------------------------------------------------

(defvar my/team-sidebar-prompt-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-<return>") #'my/team-sidebar-prompt-submit)
    (define-key map (kbd "M-<return>") #'my/team-sidebar-compose)
    (define-key map (kbd "<escape>") #'my/team-sidebar-prompt-cancel)
    (define-key map (kbd "C-c C-k") #'my/team-sidebar-prompt-cancel)
    map)
  "Keymap for inline prompt editing in the team sidebar.")

(define-minor-mode my/team-sidebar-prompt-mode
  "Minor mode for inline prompt editing in team sidebar."
  :lighter " Prompt"
  :keymap my/team-sidebar-prompt-mode-map
  (if my/team-sidebar-prompt-mode
      (setq buffer-read-only nil)
    (setq buffer-read-only t)
    (when (fboundp 'evil-normal-state)
      (evil-normal-state))))

(defun my/team-sidebar-prompt ()
  "Enter inline prompt mode: insert a markdown code block at the top."
  (interactive)
  (let ((inhibit-read-only t))
    (goto-char (point-min))
    (insert "```\n\n```\n")
    ;; Make only the editable region modifiable
    (let ((block-end (save-excursion
                       (goto-char (point-min))
                       (forward-line 1)
                       (re-search-forward "^```$" nil t)
                       (line-beginning-position 2))))
      (put-text-property block-end (point-max) 'read-only t))
    ;; Position cursor inside the block
    (goto-char (point-min))
    (forward-line 1)
    (my/team-sidebar-prompt-mode 1)
    ;; Switch to emacs state AFTER minor mode is fully set up,
    ;; via run-at-time to ensure evil doesn't override it.
    (when (fboundp 'evil-emacs-state)
      (run-at-time 0 nil
                   (lambda (buf)
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (evil-emacs-state))))
                   (current-buffer)))))

(defun my/team-sidebar--extract-prompt-text ()
  "Extract text from between the ``` markers at top of buffer."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "```")
      (forward-line 1)
      (let ((start (point)))
        (when (re-search-forward "^```$" nil t)
          (string-trim (buffer-substring-no-properties start (line-beginning-position))))))))

(defun my/team-sidebar--erase-prompt-block ()
  "Remove the prompt block from the top of the buffer."
  (let ((inhibit-read-only t))
    ;; Remove read-only property first
    (remove-text-properties (point-min) (point-max) '(read-only nil))
    (save-excursion
      (goto-char (point-min))
      (when (looking-at "```")
        (let ((end (my/team-sidebar--prompt-region-end)))
          (when end
            (delete-region (point-min) end)))))))

(defun my/team-sidebar-prompt-submit ()
  "Submit the prompt text to the lead agent shell buffer."
  (interactive)
  (let ((text (my/team-sidebar--extract-prompt-text)))
    (if (or (null text) (string-empty-p text))
        (message "Empty prompt, nothing to submit.")
      (let* ((sid my/team-sidebar--session-id)
             (lead-buf (my/team-sidebar--find-lead-buffer sid)))
        (if (not (buffer-live-p lead-buf))
            (message "Lead buffer not found for session %s" sid)
          (my/team-sidebar-prompt-mode -1)
          (my/team-sidebar--erase-prompt-block)
          (with-current-buffer lead-buf
            (shell-maker-submit :input text))
          (message "Submitted to lead."))))))

(defun my/team-sidebar-prompt-cancel ()
  "Cancel prompt editing and restore read-only state."
  (interactive)
  (my/team-sidebar-prompt-mode -1)
  (my/team-sidebar--erase-prompt-block))

(defun my/team-sidebar-compose ()
  "Open the compose posframe targeting the lead buffer for this session."
  (interactive)
  (let* ((sid my/team-sidebar--session-id)
         (lead-buf (my/team-sidebar--find-lead-buffer sid)))
    (unless (buffer-live-p lead-buf)
      (user-error "Lead buffer not found for session %s" sid))
    (with-current-buffer lead-buf
      (my/agent-shell-compose-popup))))

;;; ---- Side Window Management -------------------------------------------------

(defun my/team-sidebar--get-or-create-buffer ()
  "Get or create the sidebar buffer."
  (or (get-buffer my/team-sidebar-buffer-name)
      (with-current-buffer (get-buffer-create my/team-sidebar-buffer-name)
        (my/team-sidebar-mode)
        (current-buffer))))

(defun my/team-sidebar--show ()
  "Display the sidebar in a side window on the right."
  (let ((buf (my/team-sidebar--get-or-create-buffer)))
    (unless (get-buffer-window buf)
      (let ((win (display-buffer-in-side-window
                  buf
                  `((side . right)
                    (slot . 0)
                    (window-width . ,my/team-sidebar-width)
                    (dedicated . t)))))
        (when win
          (my/team-sidebar--set-window-params win))))
    ;; Update session-id from visible lead
    (let ((lead (my/team-sidebar--any-lead-visible-p)))
      (when lead
        (let ((sid (my/team-sidebar--session-id-from-lead lead)))
          (when sid
            (with-current-buffer buf
              (setq my/team-sidebar--session-id sid))))))
    ;; Start refresh timer
    (my/team-sidebar--ensure-timer)
    ;; Initial render
    (my/team-sidebar--render)))

(defun my/team-sidebar--hide ()
  "Hide the sidebar window without killing the buffer."
  (let ((win (get-buffer-window my/team-sidebar-buffer-name t)))
    (when win
      (delete-window win)))
  (my/team-sidebar--stop-timer))

(defun my/team-sidebar--set-window-params (win)
  "Set protective window parameters on WIN."
  (when (window-live-p win)
    (set-window-parameter win 'no-delete-other-windows t)
    (set-window-parameter win 'no-other-window t)
    (set-window-parameter win 'dedicated t)
    (set-window-dedicated-p win t)))

(defun my/team-sidebar--reapply-window-params ()
  "Reapply window parameters on config change (treemacs defensive pattern)."
  (let ((win (get-buffer-window my/team-sidebar-buffer-name t)))
    (when win
      ;; Suppress hook locally to prevent feedback loops
      (let ((window-configuration-change-hook nil))
        (my/team-sidebar--set-window-params win)))))

;;; ---- Auto Show/Hide ---------------------------------------------------------

(defvar my/team-sidebar--toggling nil
  "Guard to prevent recursive toggling.")

(defun my/team-sidebar--auto-toggle (&rest _)
  "Show sidebar when lead buffer is visible, hide otherwise.
Registered on `window-buffer-change-functions' and
`window-selection-change-functions'."
  (when (and (not my/team-sidebar--toggling)
             (not (active-minibuffer-window)))
    (let ((my/team-sidebar--toggling t))
      (if (my/team-sidebar--any-lead-visible-p)
          (my/team-sidebar--show)
        (my/team-sidebar--hide)))))

;;; ---- Refresh Timer ----------------------------------------------------------

(defun my/team-sidebar--ensure-timer ()
  "Ensure the 2-second refresh timer is running."
  (let ((buf (get-buffer my/team-sidebar-buffer-name)))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (unless (and my/team-sidebar--refresh-timer
                     (timerp my/team-sidebar--refresh-timer)
                     (memq my/team-sidebar--refresh-timer timer-list))
          (setq my/team-sidebar--refresh-timer
                (run-with-timer 2 2 #'my/team-sidebar--timer-refresh)))))))

(defun my/team-sidebar--stop-timer ()
  "Stop the refresh timer."
  (let ((buf (get-buffer my/team-sidebar-buffer-name)))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (when (timerp my/team-sidebar--refresh-timer)
          (cancel-timer my/team-sidebar--refresh-timer)
          (setq my/team-sidebar--refresh-timer nil))))))

(defun my/team-sidebar--timer-refresh ()
  "Timer callback: refresh if sidebar is visible."
  (let ((win (get-buffer-window my/team-sidebar-buffer-name t)))
    (if win
        (my/team-sidebar--render)
      ;; Sidebar not visible — stop timer
      (my/team-sidebar--stop-timer))))

;;; ---- Integration / Hook Registration ----------------------------------------

(defun my/team-sidebar--setup-hooks ()
  "Register auto-toggle hooks and window-config protection."
  (add-hook 'window-buffer-change-functions #'my/team-sidebar--auto-toggle)
  (add-hook 'window-selection-change-functions #'my/team-sidebar--auto-toggle)
  (add-hook 'window-configuration-change-hook #'my/team-sidebar--reapply-window-params))

(with-eval-after-load 'agent-shell-team
  (my/team-sidebar--setup-hooks))

(provide 'my-agent-shell-sidebar)
;;; my-agent-shell-sidebar.el ends here
