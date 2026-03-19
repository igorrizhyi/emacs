;;; modules/my-layout.el --- Window layout management -*- lexical-binding: t; -*-

;;; Commentary:
;; Window layout management for navigation between splits.
;; - Top split: AI assistant chat (30% height)
;; - Left sidebar: marks list or magit window
;; - Center window: main code window
;; - Bottom bar: terminal

;;; Code:

(defvar my-layout--window-states (make-hash-table :test 'eq)
  "Hash table storing window layout states.")

(defvar my-layout--window-handles (make-hash-table :test 'eq)
  "Hash table storing window handles for each split.")

(defconst my-layout--splits
  '(left-sidebar main-center top-chat bottom-bar right-sidebar)
  "Available window splits in the layout.")

(defvar my-layout--claude-started nil
  "Track whether Claude Code has been started.")

(defun my-layout--init-state ()
  "Initialize window layout state tracking."
  (dolist (split my-layout--splits)
    (puthash split 'hidden my-layout--window-states)))

(my-layout--init-state)

(defun my-layout--get-state (split)
  "Get the current state of SPLIT."
  (gethash split my-layout--window-states 'hidden))

(defun my-layout--set-state (split state)
  "Set the STATE of SPLIT."
  (puthash split state my-layout--window-states))

(defun my-layout--get-window (split)
  "Get the window handle for SPLIT."
  (gethash split my-layout--window-handles))

(defun my-layout--set-window (split window)
  "Set the WINDOW handle for SPLIT."
  (puthash split window my-layout--window-handles))

(defun my-layout-show-in-left-sidebar (buffer)
  "Show BUFFER in the left sidebar split."
  (interactive)
  (let ((existing-window (my-layout--get-window 'left-sidebar)))
    (if (and existing-window (window-live-p existing-window))
        ;; Sidebar already exists, just switch buffer
        (progn
          (select-window existing-window)
          (switch-to-buffer buffer))
      ;; Create new sidebar
      (let ((original-buffer (current-buffer))
            (sidebar-width 60))
        (let ((sidebar-window (split-window-horizontally sidebar-width)))
          ;; Put the target buffer in the current (left) window
          (switch-to-buffer buffer)
          (my-layout--set-window 'left-sidebar (selected-window))
          (my-layout--set-state 'left-sidebar 'visible)
          ;; Set fixed width and prevent resizing
          (window-preserve-size (selected-window) t nil)
          ;; Move to right window and put original buffer there
          (select-window sidebar-window)
          (switch-to-buffer original-buffer)
          ;; Also preserve main window size
          (window-preserve-size (selected-window) t nil)
          (my-layout--set-window 'main-center (selected-window)))))))

(defun my-layout-show-in-main-center (buffer)
  "Show BUFFER in the main center window."
  (interactive)
  (let ((main-window (or (my-layout--get-window 'main-center)
                         (selected-window))))
    (select-window main-window)
    (switch-to-buffer buffer)
    (my-layout--set-window 'main-center (selected-window))
    (my-layout--set-state 'main-center 'visible)))

(defun my-layout-show-in-top-chat (buffer)
  "Show BUFFER in the top chat split (30% of frame height)."
  (interactive)
  (let ((existing-window (my-layout--get-window 'top-chat)))
    (if (and existing-window (window-live-p existing-window))
        ;; Top chat already exists, just switch buffer
        (progn
          (select-window existing-window)
          (switch-to-buffer buffer))
      ;; Create new top chat split
      (let* ((main-window (selected-window))
             (frame-height (frame-height))
             (chat-height (floor (* frame-height 0.3))))
        ;; Split and put chat in the top window (original window becomes top)
        (split-window-vertically chat-height)
        ;; Current window is now the top window (what we want for chat)
        (switch-to-buffer buffer)
        (my-layout--set-window 'top-chat (selected-window))
        (my-layout--set-state 'top-chat 'visible)
        ;; Set fixed height and prevent resizing
        (window-preserve-size (selected-window) nil t)
        ;; Move to the bottom window (main content area)
        (other-window 1)
        ;; Set this as the main-center window
        (my-layout--set-window 'main-center (selected-window))
        (my-layout--set-state 'main-center 'visible)
        ;; Also preserve main window size
        (window-preserve-size (selected-window) nil t)))))

(defun my-layout-show-in-bottom-bar (buffer)
  "Show BUFFER in the bottom bar."
  (interactive)
  (let ((existing-window (my-layout--get-window 'bottom-bar)))
    (if (and existing-window (window-live-p existing-window))
        ;; Bottom bar already exists, just switch buffer
        (progn
          (select-window existing-window)
          (switch-to-buffer buffer))
      ;; Create new bottom bar
      (let ((main-window (selected-window)))
        (select-window (split-window-vertically (- (/ (window-height) 4))))
        (switch-to-buffer buffer)
        (my-layout--set-window 'bottom-bar (selected-window))
        (my-layout--set-state 'bottom-bar 'visible)
        ;; Set fixed height and prevent resizing
        (window-preserve-size (selected-window) nil t)
        (select-window main-window)
        ;; Also preserve main window size
        (window-preserve-size (selected-window) nil t)))))

(defun my-layout-hide-left-sidebar ()
  "Hide the left sidebar."
  (interactive)
  (let ((window (my-layout--get-window 'left-sidebar)))
    (when (and window (window-live-p window))
      (delete-window window)
      (my-layout--set-state 'left-sidebar 'hidden)
      (my-layout--set-window 'left-sidebar nil))))

(defun my-layout-hide-top-chat ()
  "Hide the top chat split."
  (interactive)
  (let ((window (my-layout--get-window 'top-chat)))
    (when (and window (window-live-p window))
      (delete-window window)
      (my-layout--set-state 'top-chat 'hidden)
      (my-layout--set-window 'top-chat nil))))

(defun my-layout-hide-bottom-bar ()
  "Hide the bottom bar."
  (interactive)
  (let ((window (my-layout--get-window 'bottom-bar)))
    (when (and window (window-live-p window))
      (delete-window window)
      (my-layout--set-state 'bottom-bar 'hidden)
      (my-layout--set-window 'bottom-bar nil))))

(defun my-layout-show-in-right-sidebar (buffer)
  "Show BUFFER in the right sidebar split (50% of frame width)."
  (interactive)
  (let ((existing-window (my-layout--get-window 'right-sidebar)))
    ;; Clean up stale window handle
    (when (and existing-window (not (window-live-p existing-window)))
      (my-layout--set-window 'right-sidebar nil)
      (my-layout--set-state 'right-sidebar 'hidden)
      (setq existing-window nil))
    (if (and existing-window (window-live-p existing-window))
        ;; Right sidebar already exists, just switch buffer
        (progn
          (select-window existing-window)
          (switch-to-buffer buffer))
      ;; Create new right sidebar
      (let* ((main-window (selected-window))
             (sidebar-width (/ (window-width) 2)))
        ;; Split horizontally, new window appears on the right
        (let ((sidebar-window (split-window-horizontally (- sidebar-width))))
          ;; sidebar-window is now the right window, switch to it
          (select-window sidebar-window)
          (switch-to-buffer buffer)
          (my-layout--set-window 'right-sidebar (selected-window))
          (my-layout--set-state 'right-sidebar 'visible)
          ;; Return to main window
          (select-window main-window)
          (my-layout--set-window 'main-center main-window))))))

(defun my-layout-hide-right-sidebar ()
  "Hide the right sidebar."
  (interactive)
  (let ((window (my-layout--get-window 'right-sidebar)))
    (when (and window (window-live-p window))
      (delete-window window)
      (my-layout--set-state 'right-sidebar 'hidden)
      (my-layout--set-window 'right-sidebar nil))))

(defun my-layout-toggle-bottom-bar ()
  "Toggle the bottom bar visibility."
  (interactive)
  (if (eq (my-layout--get-state 'bottom-bar) 'visible)
      (my-layout-hide-bottom-bar)
    ;; Use my-terminal's function to get the right terminal buffer for this workspace
    (if (fboundp 'my/get-terminal-buffer)
        (let ((terminal-buffer (my/get-terminal-buffer)))
          (if terminal-buffer
              (my-layout-show-in-bottom-bar terminal-buffer)
            ;; No terminal exists, create one using my-terminal's show function
            (if (fboundp 'my/toggle-terminal-show)
                (my/toggle-terminal-show)
              (message "No terminal buffer available"))))
      ;; Fallback to looking for any my-terminal buffer
      (let ((terminal-buffer (cl-find-if (lambda (buf)
                                           (string-match-p "^\\*my-terminal:" (buffer-name buf)))
                                         (buffer-list))))
        (if terminal-buffer
            (my-layout-show-in-bottom-bar terminal-buffer)
          (message "No terminal buffer available"))))))

(defun my-layout-toggle-left-sidebar ()
  "Toggle the left sidebar visibility."
  (interactive)
  (if (eq (my-layout--get-state 'left-sidebar) 'visible)
      (my-layout-hide-left-sidebar)
    (let ((marks-buffer (get-buffer "*Global Marks*"))
          (magit-buffer (get-buffer (magit-get-mode-buffer 'magit-status-mode))))
      (cond
       (marks-buffer (my-layout-show-in-left-sidebar marks-buffer))
       (magit-buffer (my-layout-show-in-left-sidebar magit-buffer))
       (t (my-layout-show-marks-in-sidebar))))))

(defun my-layout-toggle-top-chat ()
  "Toggle the top chat split visibility."
  (interactive)
  (if (eq (my-layout--get-state 'top-chat) 'visible)
      (my-layout-hide-top-chat)
    (let ((chat-buffer (or (get-buffer "*claude-chat*")
                          (get-buffer "*AI Chat*")
                          (get-buffer "*GPT*"))))
      (if chat-buffer
          (my-layout-show-in-top-chat chat-buffer)
        (message "No AI chat buffer available")))))

(defun my-layout-navigate-left ()
  "Navigate to the window on the left."
  (interactive)
  (evil-set-jump)
  (let ((current-window (selected-window)))
    (condition-case nil
        (windmove-left)
      (error
       (when (my-layout--get-window 'left-sidebar)
         (select-window (my-layout--get-window 'left-sidebar)))))))

(defun my-layout-navigate-right ()
  "Navigate to the window on the right."
  (interactive)
  (let ((current-window (selected-window)))
    (condition-case nil
        (windmove-right)
      (error (message "No window to the right")))))

(defun my-layout-navigate-up ()
  "Navigate to the window above."
  (interactive)
  (condition-case nil
      (windmove-up)
    (error
     (when (my-layout--get-window 'top-chat)
       (select-window (my-layout--get-window 'top-chat))))))

(defun my-layout-navigate-down ()
  "Navigate to the window below."
  (interactive)
  (condition-case nil
      (windmove-down)
    (error
     (let ((approval-win (get-buffer-window " *approval-queue*" t))
           (bottom-win (my-layout--get-window 'bottom-bar)))
       (cond
        (approval-win (select-window approval-win))
        (bottom-win (select-window bottom-win)))))))

(defun my-layout-show-marks-in-sidebar ()
  "Show marks list in left sidebar."
  (interactive)
  (let ((marks-buffer (or (get-buffer "*Global Marks*")
                          (progn
                            (my/view-marks-markdown)
                            (current-buffer)))))
    (my-layout-show-in-left-sidebar marks-buffer)))

(defun my-layout-show-magit-in-sidebar ()
  "Show magit status in left sidebar."
  (interactive)
  (let ((magit-buffer (magit-status-setup-buffer)))
    (my-layout-show-in-left-sidebar magit-buffer)))

(defun my-layout-smart-agent-shell ()
  "Switch to the agent-shell team lead buffer, or start a new team session.
If already in the lead buffer, toggle back to the previous buffer."
  (interactive)
  (let ((lead-buffer
         (when (boundp 'agent-shell-team--sessions)
           (catch 'found
             (maphash (lambda (_sid agents)
                        (dolist (agent agents)
                          (when (and (equal (alist-get 'role agent) "lead")
                                     (buffer-live-p (alist-get 'buffer agent)))
                            (throw 'found (alist-get 'buffer agent)))))
                      agent-shell-team--sessions)
             nil))))
    (cond
     ;; Already in the lead buffer — toggle back
     ((and lead-buffer (eq (current-buffer) lead-buffer))
      (let ((prev (seq-find (lambda (buf)
                              (and (not (eq buf (current-buffer)))
                                   (buffer-live-p buf)
                                   (not (string-prefix-p " " (buffer-name buf)))))
                            (buffer-list))))
        (when prev (switch-to-buffer prev))))

     ;; Lead buffer exists — switch to it
     (lead-buffer
      (let ((text (unless (derived-mode-p 'agent-shell-mode)
                    (agent-shell--context :shell-buffer lead-buffer))))
        (switch-to-buffer lead-buffer)
        (when text
          (agent-shell--insert-to-shell-buffer :text text :shell-buffer lead-buffer))))

     ;; No lead session — start one
     (t
      (require 'agent-shell-team)
      (let* ((context-buffer (current-buffer))
             (session-id agent-shell-team--session-id)
             (buf (agent-shell-team--start-agent session-id "lead" "neighbor" default-directory nil nil)))
        (message "agent-shell-team: start called, session=%s role=lead mode=neighbor"
                 (agent-shell-team--short-session-id session-id))
        (switch-to-buffer buf)
        (agent-shell-team--start-drain-timer)
        (unless (with-current-buffer context-buffer (derived-mode-p 'agent-shell-mode))
          (when-let ((text (with-current-buffer context-buffer
                            (agent-shell--context :shell-buffer buf))))
            (agent-shell--insert-to-shell-buffer :text text :shell-buffer buf))))))))

(defun my-layout-show-file-main-center (file-path &optional line-num)
  "Show FILE-PATH in main center window, optionally go to LINE-NUM."
  (let ((buffer (find-file-noselect file-path)))
    (my-layout-show-in-main-center buffer)
    (when line-num
      (with-current-buffer buffer
        (goto-line line-num)
        (recenter)))))

(defun my-layout-show-file-top-chat (file-path &optional line-num)
  "Show FILE-PATH in top chat window, optionally go to LINE-NUM."
  (let ((buffer (find-file-noselect file-path)))
    (my-layout-show-in-top-chat buffer)
    (when line-num
      (with-current-buffer buffer
        (goto-line line-num)
        (recenter)))))

(defun my-layout-show-buffer-main-center (buffer)
  "Show BUFFER in main center window."
  (my-layout-show-in-main-center buffer))

(defun my-layout-show-buffer-top-chat (buffer)
  "Show BUFFER in top chat window."
  (my-layout-show-in-top-chat buffer))

(defun my-layout-show-buffer-left-sidebar (buffer)
  "Show BUFFER in left sidebar."
  (my-layout-show-in-left-sidebar buffer))

(defun my-layout-show-buffer-bottom-bar (buffer)
  "Show BUFFER in bottom bar."
  (my-layout-show-in-bottom-bar buffer))

(defun my-layout--restore-window-sizes ()
  "Restore fixed sizes for all layout windows after a window is deleted."
  (when-let ((left-window (my-layout--get-window 'left-sidebar)))
    (when (window-live-p left-window)
      (with-selected-window left-window
        (window-resize left-window (- 60 (window-width)) t))))

  (when-let ((top-window (my-layout--get-window 'top-chat)))
    (when (window-live-p top-window)
      (with-selected-window top-window
        (let ((target-height (floor (* (frame-height) 0.3))))
          (window-resize top-window (- target-height (window-height)) nil)))))

  (when-let ((bottom-window (my-layout--get-window 'bottom-bar)))
    (when (window-live-p bottom-window)
      (with-selected-window bottom-window
        (let ((target-height (/ (frame-height) 4)))
          (window-resize bottom-window (- target-height (window-height)) nil))))))

(defun my-layout--window-deleted-hook (window)
  "Hook function called when a window is deleted."
  (when (or (eq window (my-layout--get-window 'left-sidebar))
            (eq window (my-layout--get-window 'top-chat))
            (eq window (my-layout--get-window 'bottom-bar)))
    ;; One of our layout windows was deleted, update state
    (cond
     ((eq window (my-layout--get-window 'left-sidebar))
      (my-layout--set-state 'left-sidebar 'hidden)
      (my-layout--set-window 'left-sidebar nil))
     ((eq window (my-layout--get-window 'top-chat))
      (my-layout--set-state 'top-chat 'hidden)
      (my-layout--set-window 'top-chat nil))
     ((eq window (my-layout--get-window 'bottom-bar))
      (my-layout--set-state 'bottom-bar 'hidden)
      (my-layout--set-window 'bottom-bar nil)))
    ;; Restore sizes of remaining windows after a short delay
    (run-with-idle-timer 0.1 nil #'my-layout--restore-window-sizes)))

;; Install the window deletion hook
(add-hook 'window-selection-change-functions
          (lambda (frame)
            (my-layout--restore-window-sizes)))

;; Visual focus indication for top chat
(defface my-layout-focused-window-face
  '((t (:background "#361707" :extend t)))
  ;; '((t (:background "#261707" :extend t)))
  "Face for focused window indication.")

(defvar my-layout-focused-window-overlay nil
  "Overlay for focused window indication.")

(defun my-layout-highlight-top-chat ()
  "Add visual highlight to top chat when focused."
  (when (and (my-layout--get-window 'top-chat)
             (eq (selected-window) (my-layout--get-window 'top-chat)))
    (let ((window (my-layout--get-window 'top-chat)))
      (when (window-live-p window)
        (with-selected-window window
          (when my-layout-focused-window-overlay
            (delete-overlay my-layout-focused-window-overlay))
          (setq my-layout-focused-window-overlay
                (make-overlay (window-start) (window-end)))
          ;; (overlay-put my-layout-focused-window-overlay 'face 'my-layout-focused-window-face)
          (overlay-put my-layout-focused-window-overlay 'window window))))))

(defun my-layout-remove-chat-highlight ()
  "Remove visual highlight from chat."
  (when my-layout-focused-window-overlay
    (delete-overlay my-layout-focused-window-overlay)
    (setq my-layout-focused-window-overlay nil)))

(defun my-layout-update-chat-focus ()
  "Update chat focus indication."
  (my-layout-remove-chat-highlight)
  (my-layout-highlight-top-chat))

;; Hook to update focus indication
(add-hook 'window-selection-change-functions
          (lambda (frame) (my-layout-update-chat-focus)))
(add-hook 'buffer-list-update-hook #'my-layout-update-chat-focus)

(defun my-layout-reset ()
  "Reset the layout to a clean state."
  (interactive)
  (delete-other-windows)
  (my-layout--init-state)
  (clrhash my-layout--window-handles)
  (message "Layout reset"))

;; Compatibility aliases for existing code
(defalias 'my/show-file-main-right 'my-layout-show-file-top-chat)
(defalias 'my-window-layout-show-with-layout
  (lambda (split buffer)
    (pcase split
      ('bottom-bar (my-layout-show-in-bottom-bar buffer))
      ('left-sidebar (my-layout-show-in-left-sidebar buffer))
      ('top-chat (my-layout-show-in-top-chat buffer))
      ('main-center (my-layout-show-in-main-center buffer))
      ('right-sidebar (my-layout-show-in-right-sidebar buffer))
      ('right-chat (my-layout-show-in-right-sidebar buffer))
      (_ (switch-to-buffer buffer)))))

(defalias 'my-window-layout--get-window 'my-layout--get-window)
(defalias 'my-window-layout--get-state 'my-layout--get-state)
(defalias 'my-window-layout-hide-bottom-bar 'my-layout-hide-bottom-bar)

;; Key bindings for navigation
(map! :n "C-h" #'my-layout-navigate-left
      :n "C-l" #'my-layout-navigate-right
      :n "s-<right>" #'my-layout-navigate-right)

;; Specific eat terminal keybindings using s-arrow keys that work reliably
(after! eat
  (define-key eat-semi-char-mode-map (kbd "s-<left>") #'my-layout-navigate-left)
  (define-key eat-semi-char-mode-map (kbd "s-<right>") #'my-layout-navigate-right)
  (define-key eat-semi-char-mode-map (kbd "s-<down>") #'my-layout-navigate-down)
  (define-key eat-semi-char-mode-map (kbd "s-<up>") #'my-layout-navigate-up)
  (define-key eat-char-mode-map (kbd "s-<left>") #'my-layout-navigate-left)
  (define-key eat-char-mode-map (kbd "s-<right>") #'my-layout-navigate-right)
  (define-key eat-char-mode-map (kbd "s-<down>") #'my-layout-navigate-down)
  (define-key eat-char-mode-map (kbd "s-<up>") #'my-layout-navigate-up))

;; Leader key bindings for layout management
(map! :leader
      (:prefix ("w" . "window/layout")
       :desc "Show marks in sidebar" "m" #'my-layout-show-marks-in-sidebar
       :desc "Show magit in sidebar" "g" #'my-layout-show-magit-in-sidebar
       :desc "Toggle left sidebar" "l" #'my-layout-toggle-left-sidebar
       :desc "Toggle top chat" "t" #'my-layout-toggle-top-chat
       :desc "Hide left sidebar" "h" #'my-layout-hide-left-sidebar
       :desc "Hide top chat" "H" #'my-layout-hide-top-chat
       :desc "Toggle bottom bar" "b" #'my-layout-toggle-bottom-bar
       :desc "Reset layout" "R" #'my-layout-reset))

(provide 'my-layout)

;;; my-layout.el ends here
