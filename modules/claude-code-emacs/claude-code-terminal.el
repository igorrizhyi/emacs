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

(defvar claude-code-terminal-access-times (make-hash-table :test 'equal)
  "Hash table tracking last access time for each terminal ID.")

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
      
      ;; Update last created terminal ID and record access time
      (setq claude-code-terminal-last-created terminal-id)
      (puthash terminal-id (current-time) claude-code-terminal-access-times)
      
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
    (setq claude-code-terminal-last-focused terminal-id)
    ;; Record access time for this terminal
    (puthash terminal-id (current-time) claude-code-terminal-access-times)))

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
  (message "Executing command in terminal '%s' (%s): %s" terminal-id project-root command)
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

(defun claude-code-terminal-cycle-prefix ()
  "Cycle through terminals with the same prefix as the current terminal.
For example, if current terminal is 'my_prod', cycles through 'my_prod', 'my_prod_1', 'my_prod_2', etc."
  (interactive)
  (let ((current-id (claude-code-terminal-get-current-id)))
    (unless current-id
      (user-error "Not in a Claude terminal buffer"))
    
    (claude-code-terminal-cleanup-dead-buffers)
    (let* ((active-terminals (claude-code-terminal-list-active))
           ;; Extract prefix (everything before the last underscore and number)
           (prefix (if (string-match "^\\(.+\\)_[0-9]+$" current-id)
                       (match-string 1 current-id)
                     current-id))
           ;; Find all terminals with the same prefix
           (matching-terminals 
            (seq-filter (lambda (term)
                          (let ((term-id (plist-get term :terminal-id)))
                            (or (string= term-id prefix)
                                (string-match (concat "^" (regexp-quote prefix) "_[0-9]+$") term-id))))
                        active-terminals))
           ;; Sort terminals by ID for consistent cycling order
           (sorted-terminals 
            (sort matching-terminals 
                  (lambda (a b)
                    (let ((id-a (plist-get a :terminal-id))
                          (id-b (plist-get b :terminal-id)))
                      ;; Sort by name, treating numbers properly
                      (string< id-a id-b)))))
           ;; Find current terminal index
           (current-index 
            (seq-position sorted-terminals current-id 
                         (lambda (term id) (string= (plist-get term :terminal-id) id))))
           ;; Calculate next index (wrap around)
           (next-index (if current-index
                          (mod (1+ current-index) (length sorted-terminals))
                        0)))
      
      (if (< (length matching-terminals) 2)
          (message "Only one terminal with prefix '%s' found" prefix)
        (let ((next-terminal (nth next-index sorted-terminals)))
          (switch-to-buffer (plist-get next-terminal :buffer))
          (message "Switched to terminal: %s (%d/%d)" 
                   (plist-get next-terminal :terminal-id)
                   (1+ next-index) 
                   (length sorted-terminals)))))))

(defun claude-code-terminal-switch (&optional arg)
  "Switch to a terminal buffer, ordered by most recent usage.
With prefix argument ARG (C-u), switch to the most recent terminal directly."
  (interactive "P")
  (claude-code-terminal-cleanup-dead-buffers)
  ;; Update current terminal's access time before building the list
  (claude-code-terminal-update-last-focused)
  
  (let* ((current-buffer (current-buffer))
         (active-terminals (claude-code-terminal-list-active))
         ;; Exclude current terminal from the list
         (other-terminals (seq-filter (lambda (term)
                                        (not (eq (plist-get term :buffer) current-buffer)))
                                      active-terminals)))
    (if other-terminals
        ;; Sort terminals by access time (most recent first)
        (let* ((sorted-terminals 
                (sort other-terminals
                      (lambda (a b)
                        (let* ((id-a (plist-get a :terminal-id))
                               (id-b (plist-get b :terminal-id))
                               (time-a (gethash id-a claude-code-terminal-access-times nil))
                               (time-b (gethash id-b claude-code-terminal-access-times nil)))
                          ;; Sort by access time (most recent first)
                          ;; Terminals with access times come before those without
                          (cond
                           ((and time-a time-b) (time-less-p time-b time-a))
                           (time-a nil)  ; a has time, b doesn't -> a comes first
                           (time-b t)    ; b has time, a doesn't -> b comes first  
                           (t nil)))))) ; both nil -> preserve order
               (choices (mapcar (lambda (term)
                                  (let* ((id (plist-get term :terminal-id))
                                         (access-time (gethash id claude-code-terminal-access-times nil))
                                         (time-str (if access-time
                                                      (format-time-string "%H:%M:%S" access-time)
                                                    "never")))
                                    (cons (format "%s [%s] (%s)" 
                                                 (plist-get term :buffer-name)
                                                 (plist-get term :terminal-id)
                                                 time-str)
                                          term)))
                               sorted-terminals)))
          ;;
          ;; Debug: print the sorted order
          (message "Sorted terminal order:")
          (dolist (term sorted-terminals)
            (let* ((id (plist-get term :terminal-id))
                   (access-time (gethash id claude-code-terminal-access-times nil))
                   (time-str (if access-time
                                (format-time-string "%H:%M:%S" access-time)
                              "never")))
              (message "  %s (%s)" id time-str)))
          
          ;; Create completion choices and prompt user
          ;; Use completion system with proper ordering preservation
          (let ((choice (cond
                         ;; For ivy, disable sorting to preserve our order
                         ((and (boundp 'ivy-mode) ivy-mode)
                          (let ((ivy-sort-functions-alist nil))
                            (ivy-read "Switch to terminal (recent first): " choices)))
                         ;; For vertico, disable sorting
                         ((and (boundp 'vertico-mode) vertico-mode)
                          (let ((vertico-sort-function nil))
                            (completing-read "Switch to terminal (recent first): " choices nil t)))
                         ;; For helm, disable sorting
                         ((and (boundp 'helm-mode) helm-mode)
                          (let ((helm-candidate-sort-fn nil))
                            (completing-read "Switch to terminal (recent first): " choices nil t)))
                         ;; For default completing-read, try to preserve order
                         (t
                          (let ((completion-cycle-threshold nil)
                                (read-file-name-completion-ignore-case nil))
                            (completing-read "Switch to terminal (recent first): " choices nil t))))))
            (when choice
              (let ((terminal (cdr (assoc choice choices))))
                (switch-to-buffer (plist-get terminal :buffer))
                ;; Update access time for the terminal we just switched to
                (claude-code-terminal-update-last-focused))))

      (if active-terminals
          (message "No other terminal buffers (current terminal excluded)")
        (message "No active terminal buffers"))))))

(defun claude-code-terminal-kill ()
  "Kill current terminal buffer."
  (interactive)
  (when (claude-code-terminal-get-current-id)
    (kill-buffer (current-buffer))))

(defun claude-code-terminal-debug-access-times ()
  "Show all terminal access times for debugging."
  (interactive)
  (let ((times '()))
    (maphash (lambda (id time)
               (push (cons id (format-time-string "%H:%M:%S" time)) times))
             claude-code-terminal-access-times)
    (message "Access times: %s" times)))

(defun claude-code-terminal-debug-mode-line-faces ()
  "Debug current mode-line face properties."
  (interactive)
  (let ((faces '(mode-line mode-line-inactive mode-line-buffer-id 
                 mode-line-emphasis mode-line-highlight)))
    (with-output-to-temp-buffer "*Mode-Line Face Debug*"
      (princ "=== Current Mode-Line Face Properties ===\n\n")
      (dolist (face faces)
        (princ (format "Face: %s\n" face))
        (princ (format "  Defined: %s\n" (facep face)))
        (when (facep face)
          (let ((attrs (face-all-attributes face)))
            (dolist (attr attrs)
              (let ((key (car attr))
                    (val (cdr attr)))
                (unless (eq val 'unspecified)
                  (princ (format "  %s: %s\n" key val))))))
          ;; Also show effective face at point
          (when (eq face 'mode-line)
            (princ (format "  Effective at point: %s\n" 
                          (get-text-property (point-min) 'face))))
        (princ "\n")))
      
      ;; Show window properties
      (princ "=== Window Properties ===\n")
      (princ (format "Window divider mode: %s\n" 
                     (if (bound-and-true-p window-divider-mode) "enabled" "disabled")))
      (princ (format "Mode-line format: %s\n" mode-line-format))
      (princ (format "Header-line format: %s\n" header-line-format)))))

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
    (define-key map (kbd "C-c C-t") #'claude-code-terminal-cycle-prefix)
    ;; Override C-u for terminal switching (takes precedence over universal-argument)
    (define-key map (kbd "C-u") #'claude-code-terminal-switch)
    ;; Override C-f for terminal prefix cycling (only in terminal buffers)
    (define-key map (kbd "C-f") #'claude-code-terminal-cycle-prefix)
    map)
  "Keymap for Claude Code terminal mode.")

(defun claude-code-terminal-mode-line-format ()
  "Generate mode line format showing terminal ID."
  (when (bound-and-true-p claude-code-terminal-id)
    (propertize (format " [Terminal: %s]" claude-code-terminal-id)
                'face 'mode-line-emphasis)))

(defun claude-code-terminal-get-evil-state-background ()
  "Get background color for current evil state."
  (if (and (bound-and-true-p evil-mode) (bound-and-true-p evil-state))
      (cond
       ((eq evil-state 'normal) "#666666")
       ((eq evil-state 'visual) "#666666")
       ((eq evil-state 'insert) "#f5a623")
       ((eq evil-state 'emacs) "#7ed321")
       (t "#d0021b"))
    "#999999"))

(defun claude-code-terminal-get-evil-state-foreground ()
  "Get foreground color for current evil state."
  (if (and (bound-and-true-p evil-mode) (bound-and-true-p evil-state))
      (cond
       ((eq evil-state 'normal) "#ffffff")
       ((eq evil-state 'visual) "#ffffff")
       ((eq evil-state 'insert) "#000000")
       ((eq evil-state 'emacs) "#000000")
       (t "#ffffff"))
    "#ffffff"))

(defun claude-code-terminal-get-evil-state-name ()
  "Get current evil state name."
  (if (and (bound-and-true-p evil-mode) (bound-and-true-p evil-state))
      (upcase (symbol-name evil-state))
    "EMACS"))

(defun claude-code-terminal-header-line-with-state ()
  "Generate header line with terminal ID and current state background."
  (let* ((terminal-id claude-code-terminal-id)
         (state-name (claude-code-terminal-get-evil-state-name))
         (bg-color (claude-code-terminal-get-evil-state-background))
         (fg-color (claude-code-terminal-get-evil-state-foreground))
         (text (format " :: %s " terminal-id))
         (width (window-width))
         (remaining-width (max 0 (- width (length text))))
         (full-line (concat text (make-string remaining-width ?\s))))
    (propertize full-line 'face `(:background ,bg-color :foreground ,fg-color :weight bold :height 1.5))))

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
        ;;
        ;; Add terminal ID as centered header bar with bold font and state indicator
        ;; (setq-local header-line-format
        ;;             '(:eval (when (bound-and-true-p claude-code-terminal-id)
        ;;                       (claude-code-terminal-header-line-with-state))))
        ;; Add terminal ID as bottom bar (mode line) with same styling
        (setq-local mode-line-format
                    '(:eval (when (bound-and-true-p claude-code-terminal-id)
                              (claude-code-terminal-header-line-with-state))))
        ;; Remove default header line and mode line background to let our custom colors show cleanly
        ;; (face-remap-add-relative 'header-line '(:background unspecified :box nil))
        ;; Completely override mode-line faces to remove all styling
        (face-remap-add-relative 'mode-line '(:background nil :foreground nil :box nil :underline nil :overline nil :strike-through nil :inherit nil))
        (face-remap-add-relative 'mode-line-inactive '(:background nil :foreground nil :box nil :underline nil :overline nil :strike-through nil :inherit nil))
        (face-remap-add-relative 'mode-line-buffer-id '(:background nil :foreground nil :box nil :inherit nil))
        (face-remap-add-relative 'mode-line-emphasis '(:background nil :foreground nil :box nil :inherit nil))
        (face-remap-add-relative 'mode-line-highlight '(:background nil :foreground nil :box nil :inherit nil))
        ;; Also disable window dividers and borders
        (setq-local window-divider-mode nil)
        (setq-local mode-line-format-separator nil)
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

;; Update header line when evil state changes
(with-eval-after-load 'evil
  (defun claude-code-terminal-update-header-line ()
    "Update header line in terminal buffers when state changes."
    (when (and (bound-and-true-p claude-code-terminal-mode)
               (bound-and-true-p claude-code-terminal-id))
      (force-mode-line-update)))
  
  ;; Add hooks for evil state changes
  (add-hook 'evil-insert-state-entry-hook 'claude-code-terminal-update-header-line)
  (add-hook 'evil-insert-state-exit-hook 'claude-code-terminal-update-header-line)
  (add-hook 'evil-normal-state-entry-hook 'claude-code-terminal-update-header-line)
  (add-hook 'evil-visual-state-entry-hook 'claude-code-terminal-update-header-line)
  (add-hook 'evil-emacs-state-entry-hook 'claude-code-terminal-update-header-line))

;; Popup input for claude commands
(defun claude-code-send-emacs-terminal-popup ()
  "Show centered popup for claude command input with multi-line support."
  (interactive)
  (let* ((buffer-name "*Claude Command Input*")
         (existing-buffer (get-buffer buffer-name)))
    
    ;; Kill existing buffer if it exists
    (when existing-buffer
      (kill-buffer existing-buffer))
    
    ;; Create and configure popup buffer
    (with-current-buffer (get-buffer-create buffer-name)
      (erase-buffer)
      (insert "<!-- Enter Claude command (Enter to send, Shift+Enter for newlines, ESC to cancel) -->\n\n")
      
      ;; Set up the buffer
      (markdown-mode)
      (evil-insert-state)
      (goto-char (point-max))
      
      ;; Local keybindings - Enter to send, Shift+Enter for newlines
      (local-set-key (kbd "<return>") 
                     (lambda () 
                       (interactive)
                       (claude-code-send-command-from-popup)))
      (local-set-key (kbd "C-c C-c") 
                     (lambda () 
                       (interactive)
                       (claude-code-send-command-from-popup)))
      (local-set-key (kbd "S-<return>") 'newline)
      (local-set-key (kbd "C-c C-k") 
                     (lambda () 
                       (interactive)
                       (delete-frame)
                       (message "Claude command cancelled")))
      (local-set-key (kbd "<escape>") 
                     (lambda () 
                       (interactive)
                       (delete-frame)
                       (message "Claude command cancelled")))
      (local-set-key (kbd "C-g") 
                     (lambda () 
                       (interactive)
                       (delete-frame)
                       (message "Claude command cancelled")))
      
      ;; Evil mode keybindings if available
      (when (featurep 'evil)
        (evil-local-set-key 'normal (kbd "q") 
                           (lambda () 
                             (interactive)
                             (delete-frame))))
      
      ;; Show in centered popup
      (pop-to-buffer (current-buffer)
                     `((display-buffer-in-child-frame)
                       (child-frame-parameters
                        . ((width . 60)
                           (height . 12)
                           (left . 0.4)
                           (top . 0.4)
                           (tool-bar-lines . 0)
                           (menu-bar-lines . 0)
                           (tab-bar-lines . 0)
                           (left-fringe . 4)
                           (right-fringe . 4)
                           (border-width . 1)
                           (internal-border-width . 4)
                           (unsplittable . t)
                           (no-other-frame . t))))))))

(defun claude-code-send-command-from-popup ()
  "Send command from popup to claude and close popup."
  (interactive)
  (let ((content (buffer-string))
        (buffer-to-kill (current-buffer)))
    ;; Extract actual command (skip header lines)
    (let ((lines (split-string content "\n"))
          (command-lines '()))
      (dolist (line lines)
        (unless (or (string-prefix-p "#" line)
                   (string-empty-p (string-trim line)))
          (push line command-lines)))
      (let ((command (string-join (reverse command-lines) "\n")))
        (when (not (string-empty-p (string-trim command)))
          ;; Send to claude using the same format as the original function
          (claude-code--do-send-command (format "/emacs-terminal %s" command))
          (delete-frame)
          (message "Command sent to Claude"))))))

;; Configure vterm key bindings
(with-eval-after-load 'vterm
  (define-key vterm-mode-map (kbd "C-c i") 'claude-code-send-emacs-terminal)
  (define-key vterm-mode-map (kbd "C-c h") 'claude-code-send-emacs-terminal-popup)
  ;; (define-key vterm-mode-map (kbd "C-y") 'claude-code-send-emacs-terminal)
  (define-key vterm-mode-map (kbd "C-c 1") 'claude-code-send-1)
  (define-key vterm-mode-map (kbd "C-c v") 'vterm-yank)
  (define-key vterm-mode-map (kbd "C-c k") 'my-layout-smart-claude-code)
  (define-key vterm-mode-map (kbd "C-l") 'windmove-right)
  (define-key vterm-mode-map (kbd "C-u") 'claude-code-terminal-switch))

;; Evil mode bindings for terminal switching - ensures C-u works in all evil states
(with-eval-after-load 'evil
  (evil-define-key 'insert claude-code-terminal-mode-map (kbd "C-u") 'claude-code-terminal-switch)
  (evil-define-key 'normal claude-code-terminal-mode-map (kbd "C-u") 'claude-code-terminal-switch)
  (evil-define-key 'emacs claude-code-terminal-mode-map (kbd "C-u") 'claude-code-terminal-switch)
  
  ;; Evil mode bindings for terminal prefix cycling - only in terminal buffers
  (evil-define-key 'insert claude-code-terminal-mode-map (kbd "C-f") 'claude-code-terminal-cycle-prefix)
  (evil-define-key 'normal claude-code-terminal-mode-map (kbd "C-f") 'claude-code-terminal-cycle-prefix)
  (evil-define-key 'emacs claude-code-terminal-mode-map (kbd "C-f") 'claude-code-terminal-cycle-prefix)
  
  ;; Global evil bindings - override C-u everywhere to do terminal switching
  (evil-global-set-key 'normal (kbd "C-u") 'claude-code-terminal-switch)
  (evil-global-set-key 'insert (kbd "C-u") 'claude-code-terminal-switch)
  (evil-global-set-key 'visual (kbd "C-u") 'claude-code-terminal-switch)
  (evil-global-set-key 'emacs (kbd "C-u") 'claude-code-terminal-switch))

;; Also override in global map for non-evil scenarios
(global-set-key (kbd "C-u") 'claude-code-terminal-switch)

(provide 'claude-code-terminal)
;;; claude-code-terminal.el ends here
