;;; my-request-human.el --- Human interaction capture tool -*- lexical-binding: t; -*-

;; Interactive command: my/request-human-capture
;; MCP handler: claude-code-mcp-handle-requestHuman
;; Auto-discovered via (intern (format "claude-code-mcp-handle-%s" tool-name))
;; in mcp-stdio-server.el

;;; --- State Variables ---

(defvar my-request-human--done nil
  "Flag set when human interaction is complete.")

(defvar my-request-human--cancelled nil
  "Flag set when human cancels the interaction.")

(defvar my-request-human--selected-actions nil
  "List of selected action strings.")

(defvar my-request-human--processes nil
  "List of running capture processes.")

(defvar my-request-human--spinner-timer nil
  "Timer for spinner animation.")

(defvar my-request-human--spinner-index 0
  "Current spinner frame index.")

(defvar my-request-human--temp-dir nil
  "Temp directory for captured artifacts.")

(defvar my-request-human--phase nil
  "Current phase: `select' or `capture'.")

(defvar my-request-human--actions nil
  "Available actions for current request.")

(defvar my-request-human--message nil
  "Current request message from agent.")

(defconst my-request-human--spinner-frames
  '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  "Braille spinner animation frames.")

(defconst my-request-human--buffer-name " *request-human*"
  "Buffer name for the request-human side window.")

;;; --- Action Registry ---

(defvar my-request-human-action-registry
  '(("adb-logcat" . (:label "ADB Logcat"
                     :command (lambda (dir)
                                (start-process-shell-command
                                 "adb-logcat" nil
                                 (format "adb logcat -T 1 > %s"
                                         (shell-quote-argument
                                          (expand-file-name "logcat.txt" dir)))))))
    ("adb-screenshot" . (:label "ADB Screenshot"
                         :command (lambda (dir)
                                    (start-process-shell-command
                                     "adb-screenshot" nil
                                     (format "adb exec-out screencap -p > %s"
                                             (shell-quote-argument
                                              (expand-file-name "screenshot.png" dir))))))))
  "Registry of available capture actions.
Each entry is (ACTION-ID . PLIST) where PLIST has:
  :label   - Human-readable label for display
  :command - Function taking a directory, returning a process or nil.")

;;; --- Keymap & Major Mode ---

(defvar my-request-human-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'my-request-human--toggle-checkbox)
    (define-key map (kbd "<C-return>") #'my-request-human--confirm)
    (define-key map (kbd "<escape>") #'my-request-human--cancel)
    (define-key map (kbd "q") #'my-request-human--cancel)
    map)
  "Keymap for `my-request-human-mode'.")

(define-derived-mode my-request-human-mode special-mode "ReqHuman"
  "Major mode for the request-human capture UI."
  :interactive nil
  (setq cursor-type 'bar
        truncate-lines t
        buffer-read-only t
        mode-line-format nil
        header-line-format (propertize " Request Human" 'face 'bold)))

(when (fboundp 'evil-define-key*)
  (evil-set-initial-state 'my-request-human-mode 'normal)
  (evil-define-key* 'normal my-request-human-mode-map
    "j" #'my-request-human--next-item
    "k" #'my-request-human--prev-item
    (kbd "RET") #'my-request-human--toggle-checkbox
    (kbd "<C-return>") #'my-request-human--confirm
    "q" #'my-request-human--cancel
    (kbd "ESC") #'my-request-human--cancel))

;;; --- Navigation ---

(defun my-request-human--next-item ()
  "Move to the next action item."
  (interactive)
  (forward-line 1)
  (while (and (not (eobp))
              (not (get-text-property (line-beginning-position) 'my-request-human-action)))
    (forward-line 1))
  (when (eobp)
    (forward-line -1)
    (while (and (not (bobp))
                (not (get-text-property (line-beginning-position) 'my-request-human-action)))
      (forward-line -1))))

(defun my-request-human--prev-item ()
  "Move to the previous action item."
  (interactive)
  (forward-line -1)
  (while (and (not (bobp))
              (not (get-text-property (line-beginning-position) 'my-request-human-action)))
    (forward-line -1)))

;;; --- Side Window Display ---

(defun my-request-human--get-or-create-buffer ()
  "Get or create the request-human buffer with the proper major mode."
  (or (get-buffer my-request-human--buffer-name)
      (with-current-buffer (get-buffer-create my-request-human--buffer-name)
        (my-request-human-mode)
        (current-buffer))))

(defun my-request-human--show ()
  "Display the request-human buffer in a bottom side window and select it."
  (let* ((buf (my-request-human--get-or-create-buffer))
         (win (or (get-buffer-window buf t)
                  (display-buffer-in-side-window
                   buf
                   '((side . bottom)
                     (slot . 0)
                     (window-height . 12)
                     (dedicated . t))))))
    (when win
      (set-window-parameter win 'no-delete-other-windows t)
      (set-window-parameter win 'no-other-window t)
      (select-window win))))

(defun my-request-human--cleanup ()
  "Delete the side window and kill the buffer."
  (let ((win (get-buffer-window my-request-human--buffer-name t)))
    (when (window-live-p win)
      (delete-window win)))
  (when-let ((buf (get-buffer my-request-human--buffer-name)))
    (kill-buffer buf)))

;;; --- Phase 1: Action Selection ---

(defun my-request-human--render-selection ()
  "Render the action selection phase in the buffer."
  (let ((buf (my-request-human--get-or-create-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize my-request-human--message
                            'face '(:foreground "#ffb000" :height 1.1))
                "\n\n")
        (when my-request-human--actions
          (dolist (action my-request-human--actions)
            (let ((checked (member action my-request-human--selected-actions)))
              (insert (propertize (concat (if checked "[x] " "[ ] ") action)
                                  'my-request-human-action action)
                      "\n")))
          (insert "\n"))
        (insert (propertize "[RET] toggle  [C-RET] confirm  [q/ESC] cancel"
                            'face '(:foreground "#666666")))))))

(defun my-request-human--toggle-checkbox ()
  "Toggle the checkbox at point."
  (interactive)
  (let ((action (get-text-property (line-beginning-position) 'my-request-human-action))
        (cur-line (line-number-at-pos)))
    (when action
      (if (member action my-request-human--selected-actions)
          (setq my-request-human--selected-actions
                (delete action my-request-human--selected-actions))
        (push action my-request-human--selected-actions))
      (my-request-human--render-selection)
      (goto-char (point-min))
      (forward-line (1- cur-line)))))

(defun my-request-human--confirm ()
  "Confirm selection and transition to capture phase or finish."
  (interactive)
  (if (eq my-request-human--phase 'select)
      (if my-request-human--selected-actions
          (my-request-human--start-capture)
        ;; No actions selected, just finish
        (setq my-request-human--done t)
        (exit-recursive-edit))
    ;; Phase 2: stop captures and finish
    (my-request-human--stop-captures)))

(defun my-request-human--cancel ()
  "Cancel the interaction."
  (interactive)
  (setq my-request-human--cancelled t
        my-request-human--done t)
  (exit-recursive-edit))

;;; --- Phase 2: Capture ---

(defun my-request-human--start-capture ()
  "Start background capture processes and show capture UI."
  (setq my-request-human--phase 'capture)
  (setq my-request-human--processes nil)
  ;; Start capture processes
  (dolist (action my-request-human--selected-actions)
    (let ((proc (my-request-human--start-action action)))
      (when proc
        (push proc my-request-human--processes))))
  ;; Start spinner
  (setq my-request-human--spinner-index 0)
  (my-request-human--render-capture)
  (setq my-request-human--spinner-timer
        (run-with-timer 0 0.1 #'my-request-human--update-spinner)))

(defun my-request-human--start-action (action)
  "Start capture process for ACTION using the action registry.
Return the process or nil."
  (let ((entry (assoc action my-request-human-action-registry)))
    (when entry
      (let ((command-fn (plist-get (cdr entry) :command)))
        (when command-fn
          (funcall command-fn my-request-human--temp-dir))))))

(defun my-request-human--render-capture ()
  "Render the capture phase UI."
  (let ((buf (get-buffer my-request-human--buffer-name)))
    (when buf
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize my-request-human--message
                              'face '(:foreground "#ffb000" :height 1.1))
                  "\n\n")
          (insert (propertize (nth my-request-human--spinner-index
                                   my-request-human--spinner-frames)
                              'face '(:foreground "#ffb000"))
                  " "
                  (propertize "Capturing... press RET when done"
                              'face '(:foreground "#ffb000"))
                  "\n\n")
          (insert (propertize "Active: " 'face '(:foreground "#666666"))
                  (propertize (string-join my-request-human--selected-actions ", ")
                              'face '(:foreground "#888888"))
                  "\n\n")
          (insert (propertize "[C-RET] stop & finish  [q/ESC] cancel"
                              'face '(:foreground "#666666"))))))))

(defun my-request-human--update-spinner ()
  "Update spinner animation frame."
  (setq my-request-human--spinner-index
        (mod (1+ my-request-human--spinner-index)
             (length my-request-human--spinner-frames)))
  (when (and (not my-request-human--done)
             (eq my-request-human--phase 'capture))
    (my-request-human--render-capture)))

(defun my-request-human--stop-captures ()
  "Stop all capture processes and finish."
  ;; Kill capture processes
  (dolist (proc my-request-human--processes)
    (when (process-live-p proc)
      (kill-process proc)))
  (setq my-request-human--processes nil)
  ;; Cancel spinner
  (when my-request-human--spinner-timer
    (cancel-timer my-request-human--spinner-timer)
    (setq my-request-human--spinner-timer nil))
  (setq my-request-human--done t)
  (exit-recursive-edit))

;;; --- Core Interactive Command ---

(defun my/request-human-capture (&optional message actions)
  "Show capture popup with checkbox selection and run selected captures.

When called interactively, uses default MESSAGE and shows all
registered actions from `my-request-human-action-registry'.

When called from Lisp, MESSAGE is the prompt string and ACTIONS
is a list of action ID strings (subset of registry keys).

Returns an alist with keys `success', `artifacts_dir', and `files'."
  (interactive)
  (let* ((message (or message "Select capture actions"))
         (actions (or actions (mapcar #'car my-request-human-action-registry)))
         (temp-dir (make-temp-file "request-human-" t))
         (prev-window (selected-window)))
    ;; Reset state
    (setq my-request-human--done nil
          my-request-human--cancelled nil
          my-request-human--selected-actions nil
          my-request-human--processes nil
          my-request-human--spinner-timer nil
          my-request-human--spinner-index 0
          my-request-human--temp-dir temp-dir
          my-request-human--phase 'select
          my-request-human--actions actions
          my-request-human--message message)
    ;; Render and show
    (my-request-human--render-selection)
    (my-request-human--show)
    ;; Block with recursive-edit so keymaps dispatch properly
    (unwind-protect
        (condition-case nil
            (recursive-edit)
          (quit (setq my-request-human--cancelled t
                      my-request-human--done t)))
      ;; Cleanup
      (when my-request-human--spinner-timer
        (cancel-timer my-request-human--spinner-timer)
        (setq my-request-human--spinner-timer nil))
      (dolist (proc my-request-human--processes)
        (when (process-live-p proc)
          (kill-process proc)))
      (my-request-human--cleanup)
      ;; Restore focus to previous window
      (when (window-live-p prev-window)
        (select-window prev-window)))
    ;; Return result
    (if my-request-human--cancelled
        '((success . nil) (message . "User cancelled"))
      ;; Open dired on temp dir if we captured anything
      (when my-request-human--selected-actions
        (dired temp-dir))
      `((success . t)
        (artifacts_dir . ,temp-dir)
        (files . ,(directory-files temp-dir nil "^[^.]"))))))

;;; --- MCP Handler (thin wrapper) ---

(defun claude-code-mcp-handle-requestHuman (params)
  "Handle requestHuman MCP tool call.
Parses MCP PARAMS and delegates to `my/request-human-capture'."
  (let* ((message (or (map-elt params 'message)
                      (map-elt params "message")
                      "Agent requests your attention"))
         (actions (or (map-elt params 'actions)
                      (map-elt params "actions")))
         ;; Coerce JSON vector to list of strings
         (actions (when actions
                    (if (vectorp actions) (append actions nil) actions))))
    (my/request-human-capture message actions)))

(provide 'my-request-human)
;;; my-request-human.el ends here
