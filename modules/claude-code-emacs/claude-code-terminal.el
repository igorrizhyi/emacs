;;; claude-code-terminal.el --- Terminal buffer management for Claude Code -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Claude Code Team
;; Keywords: tools, convenience, terminal
;; Version: 0.1.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This module provides terminal buffer management for Claude Code integration.
;; Features:
;; - Create terminal buffers with unique IDs
;; - Track terminal sessions per project
;; - Enable Claude chat integration from terminal buffers
;; - MCP tools for terminal content reading and command execution

;;; Code:

(require 'claude-code-core)
(require 'projectile)
(require 'vterm)

;;; Variables

(defvar claude-code-terminal-sessions (make-hash-table :test 'equal)
  "Hash table tracking terminal sessions by project root.
Each value is a list of (buffer-name . terminal-id) pairs.")

(defvar claude-code-terminal-counter 0
  "Counter for generating unique terminal IDs.")

(defvar claude-code-terminal-current-context nil
  "Current terminal context for Claude Code session.
Set to terminal ID when starting Claude from a terminal buffer.")

(defvar claude-code-terminal-last-created nil
  "ID of the last created terminal.
Used as fallback when no specific terminal ID is provided.")

(defvar claude-code-terminal-last-focused nil
  "ID of the last focused terminal buffer.
Updated when a terminal buffer becomes active.")

;;; Terminal Buffer Management

(defun claude-code-terminal-generate-id ()
  "Generate a unique terminal ID."
  (setq claude-code-terminal-counter (1+ claude-code-terminal-counter))
  (format "term-%d" claude-code-terminal-counter))

(defun claude-code-terminal-buffer-name (project-root terminal-id)
  "Generate terminal buffer name for PROJECT-ROOT and TERMINAL-ID."
  (let ((project-name (file-name-nondirectory (directory-file-name project-root))))
    (format "*claude-terminal:%s:%s*" project-name terminal-id)))

(defun claude-code-terminal-create (&optional directory)
  "Create a new terminal buffer in DIRECTORY (defaults to project root).
Prompts user for terminal name when called interactively.
Returns the terminal ID."
  (interactive)
  (let* ((project-root (claude-code-normalize-project-root (projectile-project-root)))
         (terminal-id (if (called-interactively-p 'any)
                          (let ((name (read-string "Terminal name: ")))
                            (if (string-empty-p name)
                                (claude-code-terminal-generate-id)
                              name))
                        (claude-code-terminal-generate-id)))
         (buffer-name (claude-code-terminal-buffer-name project-root terminal-id))
         (default-directory (or directory project-root)))
    
    ;; Create vterm buffer
    (let ((buffer (vterm buffer-name)))
      ;; Store terminal ID as buffer-local variable
      (with-current-buffer buffer
        (setq-local claude-code-terminal-id terminal-id)
        (setq-local claude-code-terminal-project-root project-root)
        ;; Enable claude terminal mode and apply font scaling
        (claude-code-terminal-mode 1)
        (claude-code-terminal-apply-large-font))
      
      ;; Register terminal session
      (claude-code-terminal-register project-root buffer-name terminal-id)
      
      ;; Update last created terminal ID
      (setq claude-code-terminal-last-created terminal-id)
      
      ;; Switch to the buffer
      (switch-to-buffer buffer)
      
      terminal-id)))

(defun claude-code-terminal-register (project-root buffer-name terminal-id)
  "Register terminal session for PROJECT-ROOT with BUFFER-NAME and TERMINAL-ID."
  (let ((sessions (gethash project-root claude-code-terminal-sessions '())))
    (unless (assoc buffer-name sessions)
      (puthash project-root 
               (cons (cons buffer-name terminal-id) sessions)
               claude-code-terminal-sessions))))

(defun claude-code-terminal-unregister (project-root buffer-name)
  "Unregister terminal session for PROJECT-ROOT with BUFFER-NAME."
  (let ((sessions (gethash project-root claude-code-terminal-sessions '())))
    (puthash project-root 
             (assoc-delete-all buffer-name sessions)
             claude-code-terminal-sessions)))

(defun claude-code-terminal-get-sessions (&optional project-root)
  "Get terminal sessions for PROJECT-ROOT (defaults to current project)."
  (let ((root (or project-root (claude-code-normalize-project-root (projectile-project-root)))))
    (gethash root claude-code-terminal-sessions '())))

(defun claude-code-terminal-get-by-id (terminal-id &optional project-root)
  "Get terminal buffer by TERMINAL-ID in PROJECT-ROOT."
  (let* ((root (or project-root (claude-code-normalize-project-root (projectile-project-root))))
         (sessions (claude-code-terminal-get-sessions root)))
    (catch 'found
      (dolist (session sessions)
        (when (string= (cdr session) terminal-id)
          (let ((buffer (get-buffer (car session))))
            (when (and buffer (buffer-live-p buffer))
              (throw 'found buffer)))))
      nil)))

(defun claude-code-terminal-get-current-id ()
  "Get terminal ID of current buffer if it's a terminal buffer."
  (when (bound-and-true-p claude-code-terminal-id)
    claude-code-terminal-id))

(defun claude-code-terminal-update-last-focused ()
  "Update last focused terminal ID based on current buffer."
  (when-let ((terminal-id (claude-code-terminal-get-current-id)))
    (setq claude-code-terminal-last-focused terminal-id)))

(defun claude-code-terminal-get-last-focused ()
  "Get the ID of the last focused terminal.
Falls back to current context, last created, or any active terminal."
  (or claude-code-terminal-last-focused
      claude-code-terminal-current-context
      claude-code-terminal-last-created
      ;; Try to get the most recent active terminal
      (when-let ((active-terminals (claude-code-terminal-list-active)))
        (plist-get (car (last active-terminals)) :terminal-id))))

(defun claude-code-terminal-list-active ()
  "List all active terminal buffers with their IDs."
  (interactive)
  (let ((active-terminals '()))
    (maphash (lambda (project-root sessions)
               (dolist (session sessions)
                 (let ((buffer (get-buffer (car session))))
                   (when (and buffer (buffer-live-p buffer))
                     (push (list :project-root project-root
                                :buffer-name (car session)
                                :terminal-id (cdr session)
                                :buffer buffer)
                           active-terminals)))))
             claude-code-terminal-sessions)
    active-terminals))

;;; Terminal Content Access

(defun claude-code-terminal-get-content (terminal-id &optional project-root)
  "Get content of terminal buffer by TERMINAL-ID in PROJECT-ROOT."
  (let ((buffer (claude-code-terminal-get-by-id terminal-id project-root)))
    (when buffer
      (with-current-buffer buffer
        (buffer-substring-no-properties (point-min) (point-max))))))

(defun claude-code-terminal-execute-command (terminal-id command &optional project-root timeout)
  "Execute COMMAND in terminal buffer TERMINAL-ID in PROJECT-ROOT.
Returns a plist with :success, :stdout, :stderr, :exit-code, :timeout, :working-directory."
  (let ((buffer (claude-code-terminal-get-by-id terminal-id project-root))
        (timeout-seconds (or timeout 30)))
    (if (not buffer)
        (list :success nil 
              :stdout "" 
              :stderr "Terminal not found" 
              :exit-code 1 
              :timeout nil 
              :working-directory (or project-root default-directory))
      (with-current-buffer buffer
        (if (not (derived-mode-p 'vterm-mode))
            (list :success nil 
                  :stdout "" 
                  :stderr "Buffer is not in vterm-mode" 
                  :exit-code 1 
                  :timeout nil 
                  :working-directory (or project-root default-directory))
          ;; Get current working directory from terminal
          (let* ((working-dir (or project-root default-directory))
                 (start-marker (point-max))
                 (command-with-exit-code (format "%s; echo \"__EXIT_CODE__:$?\"" command))
                 (start-time (current-time))
                 (timed-out nil)
                 (output "")
                 (exit-code 0))
            
            ;; Send command with exit code capture
            (vterm-send-string command-with-exit-code)
            (vterm-send-return)
            
            ;; Wait for command completion with timeout
            (while (and (< (float-time (time-subtract (current-time) start-time)) timeout-seconds)
                       (not (string-match "__EXIT_CODE__:\\([0-9]+\\)" 
                                         (buffer-substring-no-properties start-marker (point-max))))
                       (not timed-out))
              (accept-process-output nil 0.1)
              (when (>= (float-time (time-subtract (current-time) start-time)) timeout-seconds)
                (setq timed-out t)))
            
            ;; Extract output and exit code
            (setq output (buffer-substring-no-properties start-marker (point-max)))
            
            (if timed-out
                (list :success nil 
                      :stdout output 
                      :stderr "Command timed out" 
                      :exit-code 124 
                      :timeout t 
                      :working-directory working-dir)
              (let ((exit-match (string-match "__EXIT_CODE__:\\([0-9]+\\)" output)))
                (when exit-match
                  (setq exit-code (string-to-number (match-string 1 output)))
                  ;; Remove the exit code marker from output
                  (setq output (replace-regexp-in-string "__EXIT_CODE__:[0-9]+\n?" "" output)))
                
                ;; Clean up the output (remove command echo and prompt)
                (setq output (replace-regexp-in-string 
                             (concat "^.*" (regexp-quote command-with-exit-code) "\r?\n") 
                             "" output))
                
                (list :success (= exit-code 0)
                      :stdout output 
                      :stderr "" 
                      :exit-code exit-code 
                      :timeout nil 
                      :working-directory working-dir)))))))))

(defun claude-code-terminal-execute-command-simple (terminal-id command &optional project-root)
  "Simple version of command execution for backward compatibility."
  (let ((result (claude-code-terminal-execute-command terminal-id command project-root)))
    (plist-get result :success)))

;;; Claude Integration

(defun claude-code-terminal-start-claude-chat ()
  "Start Claude chat session with current terminal context."
  (interactive)
  (let ((terminal-id (claude-code-terminal-get-current-id)))
    (if terminal-id
        (progn
          ;; Store terminal context for Claude
          (setq claude-code-terminal-current-context terminal-id)
          ;; Start Claude Code session
          (claude-code-run))
      (user-error "Not in a Claude terminal buffer"))))

;;; Cleanup

(defun claude-code-terminal-cleanup-dead-buffers ()
  "Remove dead terminal buffers from tracking."
  (maphash (lambda (project-root sessions)
             (let ((live-sessions '()))
               (dolist (session sessions)
                 (let ((buffer (get-buffer (car session))))
                   (when (and buffer (buffer-live-p buffer))
                     (push session live-sessions))))
               (puthash project-root live-sessions claude-code-terminal-sessions)))
           claude-code-terminal-sessions))

;; Add cleanup hook
(add-hook 'kill-buffer-hook 
          (lambda ()
            (when (bound-and-true-p claude-code-terminal-id)
              (claude-code-terminal-unregister 
               claude-code-terminal-project-root 
               (buffer-name)))))

;;; Interactive Commands

(defun claude-code-terminal-switch ()
  "Switch to a terminal buffer."
  (interactive)
  (claude-code-terminal-cleanup-dead-buffers)
  (let ((active-terminals (claude-code-terminal-list-active)))
    (if active-terminals
        (let* ((choices (mapcar (lambda (term)
                                  (cons (format "%s [%s]" 
                                               (plist-get term :buffer-name)
                                               (plist-get term :terminal-id))
                                        term))
                               active-terminals))
               (choice (completing-read "Switch to terminal: " choices nil t)))
          (when choice
            (let ((terminal (cdr (assoc choice choices))))
              (switch-to-buffer (plist-get terminal :buffer)))))
      (message "No active terminal buffers"))))

(defun claude-code-terminal-kill ()
  "Kill current terminal buffer."
  (interactive)
  (when (claude-code-terminal-get-current-id)
    (kill-buffer (current-buffer))))

(defun claude-code-terminal-rename (new-terminal-id)
  "Rename current terminal buffer to NEW-TERMINAL-ID."
  (interactive "sNew terminal ID: ")
  (let ((current-id (claude-code-terminal-get-current-id)))
    (unless current-id
      (user-error "Not in a Claude terminal buffer"))
    
    (when (string-empty-p new-terminal-id)
      (user-error "Terminal ID cannot be empty"))
    
    (let* ((project-root (bound-and-true-p claude-code-terminal-project-root))
           (old-buffer-name (buffer-name))
           (new-buffer-name (claude-code-terminal-buffer-name project-root new-terminal-id)))
      
      ;; Check if new name already exists
      (when (get-buffer new-buffer-name)
        (user-error "Terminal with ID '%s' already exists" new-terminal-id))
      
      ;; Update tracking
      (claude-code-terminal-unregister project-root old-buffer-name)
      (claude-code-terminal-register project-root new-buffer-name new-terminal-id)
      
      ;; Update buffer-local variables
      (setq-local claude-code-terminal-id new-terminal-id)
      
      ;; Update global tracking variables if they reference this terminal
      (when (string= claude-code-terminal-last-created current-id)
        (setq claude-code-terminal-last-created new-terminal-id))
      (when (string= claude-code-terminal-last-focused current-id)
        (setq claude-code-terminal-last-focused new-terminal-id))
      (when (string= claude-code-terminal-current-context current-id)
        (setq claude-code-terminal-current-context new-terminal-id))
      
      ;; Rename the buffer
      (rename-buffer new-buffer-name)
      
      (message "Terminal renamed from '%s' to '%s'" current-id new-terminal-id))))

;;; Mode Definition

(defvar claude-code-terminal-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") (lambda () (interactive) (vterm-send-C-c)))
    (define-key map (kbd "C-c C-k") #'claude-code-terminal-kill)
    (define-key map (kbd "C-c C-s") #'claude-code-terminal-switch)
    map)
  "Keymap for Claude Code terminal mode.")

(defun claude-code-terminal-mode-line-format ()
  "Generate mode line format showing terminal ID."
  (when (bound-and-true-p claude-code-terminal-id)
    (propertize (format " [Terminal: %s]" claude-code-terminal-id)
                'face 'mode-line-emphasis)))

(define-minor-mode claude-code-terminal-mode
  "Minor mode for Claude Code terminal buffers."
  :lighter " CC-Term"
  :keymap claude-code-terminal-mode-map
  (if claude-code-terminal-mode
      (progn
        ;; Ensure mode line is visible in terminal buffers
        ;; (setq-local mode-line-format mode-line-format)
        ;; (when (eq mode-line-format nil)
        ;;   (setq-local mode-line-format (default-value 'mode-line-format)))
        ;; Add terminal ID as centered header bar with bold font
        (setq-local header-line-format
                    '(:eval (when (bound-and-true-p claude-code-terminal-id)
                              (let* ((text claude-code-terminal-id)
                                     (width (window-width))
                                     (padding (max 0 (/ (- width (length text)) 2))))
                                (concat (make-string padding ?\s)
                                        (propertize text 'face '(:weight bold)))))))
        ;; Also set a custom face for the header line itself to ensure border wraps
        ;; (face-remap-add-relative 'header-line
        ;;                         '(:box (:line-width 2 :color "#666666" :style released-button)
        ;;                           :background "#2d2d2d"))
        ;; Force display update
        (force-mode-line-update))
    ;; Reset mode line when mode is disabled
    (setq-local header-line-format (default-value 'header-line-format))
    (force-mode-line-update)))

(defun claude-code-terminal-apply-large-font ()
  "Apply large font to Claude terminal buffers directly without scaling."
  (when (and (display-graphic-p)
             (bound-and-true-p claude-code-terminal-id))
    ;; Set font directly using face-remap-add-relative
    (let* ((font-family (if (boundp 'my/font-family) my/font-family "DejaVu Sans Mono"))
           (font-size (if (boundp 'my/small-font-size) 
                         (round (* my/small-font-size 0.9))
                       22)))  ; fallback size
      (face-remap-add-relative 'default 
                              :family font-family 
                              :height (* font-size 10)))))

;; Auto-enable mode for terminal buffers (backup for edge cases)
(add-hook 'vterm-mode-hook
          (lambda ()
            (when (bound-and-true-p claude-code-terminal-id)
              (claude-code-terminal-mode 1)
              (claude-code-terminal-apply-large-font))))

;; Track last focused terminal buffer
(add-hook 'buffer-list-update-hook 'claude-code-terminal-update-last-focused)
(add-hook 'window-configuration-change-hook 'claude-code-terminal-update-last-focused)

;; Configure vterm key bindings
(with-eval-after-load 'vterm
  (define-key vterm-mode-map (kbd "C-c i") 'claude-code-send-emacs-terminal)
  (define-key vterm-mode-map (kbd "C-c h") 'claude-code-send-emacs-terminal)
  ;; (define-key vterm-mode-map (kbd "C-y") 'claude-code-send-emacs-terminal)
  (define-key vterm-mode-map (kbd "C-c 1") 'claude-code-send-1)
  (define-key vterm-mode-map (kbd "C-c v") 'vterm-yank)
  (define-key vterm-mode-map (kbd "C-c k") 'my-window-layout-show-claude-code-right)
  (define-key vterm-mode-map (kbd "C-l") 'windmove-right))

(provide 'claude-code-terminal)
;;; claude-code-terminal.el ends here
