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
        (select-window main-window)))))

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
        (select-window main-window)))))

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
    (let ((terminal-buffer (get-buffer "*my-terminal*")))
      (if terminal-buffer
          (my-layout-show-in-bottom-bar terminal-buffer)
        (message "No terminal buffer available")))))

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
      :n "C-j" #'my-layout-navigate-down
      :n "C-k" #'my-layout-navigate-up)

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
