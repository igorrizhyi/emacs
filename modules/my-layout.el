;;; modules/my-layout.el --- Window layout management -*- lexical-binding: t; -*-

;;; Commentary:
;; Window layout management for navigation between splits.
;; - Left sidebar: marks list or magit window
;; - Center window: main code window
;; - Right split: AI assistant chat
;; - Bottom bar: terminal

;;; Code:

(defvar my-layout--window-states (make-hash-table :test 'eq)
  "Hash table storing window layout states.")

(defvar my-layout--window-handles (make-hash-table :test 'eq)
  "Hash table storing window handles for each split.")

(defconst my-layout--splits
  '(left-sidebar main-center right-chat bottom-bar)
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

(defun my-layout-show-in-right-chat (buffer)
  "Show BUFFER in the right chat split."
  (interactive)
  (let ((existing-window (my-layout--get-window 'right-chat)))
    (if (and existing-window (window-live-p existing-window))
        ;; Right chat already exists, just switch buffer
        (progn
          (select-window existing-window)
          (switch-to-buffer buffer))
      ;; Create new right chat split
      (let ((main-window (selected-window))
            (chat-width 60))
        (select-window (split-window-horizontally (- chat-width)))
        (switch-to-buffer buffer)
        (my-layout--set-window 'right-chat (selected-window))
        (my-layout--set-state 'right-chat 'visible)
        ;; Set fixed width and prevent resizing
        (window-preserve-size (selected-window) t nil)
        (select-window main-window)
        ;; Also preserve main window size
        (window-preserve-size (selected-window) t nil)))))

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

(defun my-layout-hide-right-chat ()
  "Hide the right chat split."
  (interactive)
  (let ((window (my-layout--get-window 'right-chat)))
    (when (and window (window-live-p window))
      (delete-window window)
      (my-layout--set-state 'right-chat 'hidden)
      (my-layout--set-window 'right-chat nil))))

(defun my-layout-hide-bottom-bar ()
  "Hide the bottom bar."
  (interactive)
  (let ((window (my-layout--get-window 'bottom-bar)))
    (when (and window (window-live-p window))
      (delete-window window)
      (my-layout--set-state 'bottom-bar 'hidden)
      (my-layout--set-window 'bottom-bar nil))))

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

(defun my-layout-toggle-right-sidebar ()
  "Toggle the right sidebar visibility."
  (interactive)
  (if (eq (my-layout--get-state 'right-chat) 'visible)
      (my-layout-hide-right-chat)
    (let ((chat-buffer (or (get-buffer "*claude-chat*")
                          (get-buffer "*AI Chat*")
                          (get-buffer "*GPT*"))))
      (if chat-buffer
          (my-layout-show-in-right-chat chat-buffer)
        (message "No AI chat buffer available")))))

(defun my-layout-navigate-left ()
  "Navigate to the window on the left."
  (interactive)
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
      (error 
       (when (my-layout--get-window 'right-chat)
         (select-window (my-layout--get-window 'right-chat)))))))

(defun my-layout-navigate-up ()
  "Navigate to the window above."
  (interactive)
  (condition-case nil
      (windmove-up)
    (error (message "No window above"))))

(defun my-layout-navigate-down ()
  "Navigate to the window below."
  (interactive)
  (condition-case nil
      (windmove-down)
    (error 
     (when (my-layout--get-window 'bottom-bar)
       (select-window (my-layout--get-window 'bottom-bar))))))

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

(defun my-layout-smart-claude-code ()
  "Smart Claude Code handler: start, show, or focus based on current state."
  (interactive)
  (let* ((right-chat-window (my-layout--get-window 'right-chat))
         (right-chat-visible (and right-chat-window (window-live-p right-chat-window))))
    
    (cond
     ;; Case 1: Claude never started - start it
     ((not my-layout--claude-started)
      (claude-code)
      (setq my-layout--claude-started t)
      (message "Started Claude Code"))
     
     ;; Case 2: Claude started but right split is closed - open split and focus it
     ((and my-layout--claude-started (not right-chat-visible))
      (let ((claude-buffer (seq-find (lambda (buf)
                                       (string-match-p "claude\\|Claude" (buffer-name buf)))
                                     (buffer-list))))
        (if claude-buffer
            (progn
              (my-layout-show-in-right-chat claude-buffer)
              (select-window (my-layout--get-window 'right-chat))
              (message "Opened Claude Code in right sidebar"))
          (progn
            (claude-code)
            (message "Restarted Claude Code")))))
     
     ;; Case 3: Claude started and split is open - just focus it
     ((and my-layout--claude-started right-chat-visible)
      (select-window right-chat-window)
      (message "Focused Claude Code"))
     
     ;; Fallback: start Claude Code
     (t
      (claude-code)
      (setq my-layout--claude-started t)))))

(defun my-layout-show-file-main-center (file-path &optional line-num)
  "Show FILE-PATH in main center window, optionally go to LINE-NUM."
  (let ((buffer (find-file-noselect file-path)))
    (my-layout-show-in-main-center buffer)
    (when line-num
      (with-current-buffer buffer
        (goto-line line-num)
        (recenter)))))

(defun my-layout-show-file-main-right (file-path &optional line-num)
  "Show FILE-PATH in right chat window, optionally go to LINE-NUM."
  (let ((buffer (find-file-noselect file-path)))
    (my-layout-show-in-right-chat buffer)
    (when line-num
      (with-current-buffer buffer
        (goto-line line-num)
        (recenter)))))

(defun my-layout-show-buffer-main-center (buffer)
  "Show BUFFER in main center window."
  (my-layout-show-in-main-center buffer))

(defun my-layout-show-buffer-main-right (buffer)
  "Show BUFFER in right chat window."
  (my-layout-show-in-right-chat buffer))

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
  
  (when-let ((right-window (my-layout--get-window 'right-chat)))
    (when (window-live-p right-window)
      (with-selected-window right-window
        (window-resize right-window (- 60 (window-width)) t))))
  
  (when-let ((bottom-window (my-layout--get-window 'bottom-bar)))
    (when (window-live-p bottom-window)
      (with-selected-window bottom-window
        (let ((target-height (/ (frame-height) 4)))
          (window-resize bottom-window (- target-height (window-height)) nil))))))

(defun my-layout--window-deleted-hook (window)
  "Hook function called when a window is deleted."
  (when (or (eq window (my-layout--get-window 'left-sidebar))
            (eq window (my-layout--get-window 'right-chat))
            (eq window (my-layout--get-window 'bottom-bar)))
    ;; One of our layout windows was deleted, update state
    (cond
     ((eq window (my-layout--get-window 'left-sidebar))
      (my-layout--set-state 'left-sidebar 'hidden)
      (my-layout--set-window 'left-sidebar nil))
     ((eq window (my-layout--get-window 'right-chat))
      (my-layout--set-state 'right-chat 'hidden)
      (my-layout--set-window 'right-chat nil))
     ((eq window (my-layout--get-window 'bottom-bar))
      (my-layout--set-state 'bottom-bar 'hidden)
      (my-layout--set-window 'bottom-bar nil)))
    ;; Restore sizes of remaining windows after a short delay
    (run-with-idle-timer 0.1 nil #'my-layout--restore-window-sizes)))

;; Install the window deletion hook
(add-hook 'window-selection-change-functions 
          (lambda (frame) 
            (my-layout--restore-window-sizes)))

(defun my-layout-reset ()
  "Reset the layout to a clean state."
  (interactive)
  (delete-other-windows)
  (my-layout--init-state)
  (clrhash my-layout--window-handles)
  (message "Layout reset"))

;; Compatibility aliases for existing code
(defalias 'my/show-file-main-right 'my-layout-show-file-main-right)
(defalias 'my-window-layout-show-with-layout 
  (lambda (split buffer)
    (pcase split
      ('bottom-bar (my-layout-show-in-bottom-bar buffer))
      ('left-sidebar (my-layout-show-in-left-sidebar buffer))
      ('right-chat (my-layout-show-in-right-chat buffer))
      ('main-center (my-layout-show-in-main-center buffer))
      (_ (switch-to-buffer buffer)))))

(defalias 'my-window-layout--get-window 'my-layout--get-window)
(defalias 'my-window-layout--get-state 'my-layout--get-state)
(defalias 'my-window-layout-hide-bottom-bar 'my-layout-hide-bottom-bar)

;; Key bindings for navigation
(map! :n "C-h" #'my-layout-navigate-left
      :n "C-l" #'my-layout-navigate-right
      :n "C-j" #'my-layout-navigate-down)

;; Leader key bindings for layout management
(map! :leader
      (:prefix ("w" . "window/layout")
       :desc "Show marks in sidebar" "m" #'my-layout-show-marks-in-sidebar
       :desc "Show magit in sidebar" "g" #'my-layout-show-magit-in-sidebar
       :desc "Toggle left sidebar" "l" #'my-layout-toggle-left-sidebar
       :desc "Toggle right sidebar" "r" #'my-layout-toggle-right-sidebar
       :desc "Hide left sidebar" "h" #'my-layout-hide-left-sidebar
       :desc "Hide right chat" "H" #'my-layout-hide-right-chat
       :desc "Toggle bottom bar" "b" #'my-layout-toggle-bottom-bar
       :desc "Reset layout" "R" #'my-layout-reset))

(provide 'my-layout)

;;; my-layout.el ends here
