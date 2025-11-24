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
(require 'async)

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

(defvar claude-code-terminal-shell-stack (make-hash-table :test 'equal)
  "Hash table tracking shell nesting stack for each terminal ID.
Each value is a list of shell contexts: ((command prompt) ...), newest first.")

(defvar claude-code-terminal-last-command-line (make-hash-table :test 'equal)
  "Hash table storing the command line when Enter was pressed for each terminal.")

(defvar claude-code-terminal-pending-check (make-hash-table :test 'equal)
  "Hash table tracking pending prompt checks after Enter for each terminal.")

(defvar claude-code-terminal-async-commands (make-hash-table :test 'equal)
  "Hash table tracking asynchronous command execution for each terminal.
Each entry is a plist with :start-time :start-marker :callback :timer :command :meaningful-found :wait-start.")

(defvar claude-code-terminal-embedded-shells (make-hash-table :test 'equal)
  "Hash table tracking active embedded shell commands for headline display.")

(defvar claude-code-terminal-check-delay 0.8
  "Delay in seconds before checking prompt after Enter key press.")

(defvar claude-code-terminal-ignored-commands
  '("cd" "ls" "pwd" "echo" "export" "set" "unset" "history" "clear" "exit")
  "Commands that commonly change prompts temporarily but don't create embedded contexts.")

(defvar claude-code-terminal-debug-mode nil
  "Enable debug messages for shell nesting detection.")

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

(defun claude-code-terminal-create-numbered (&optional directory)
  "Create a new terminal buffer with auto-generated numbered name based on current terminal.
If current terminal follows pattern 'name_N', creates 'name_{N+1}'.
If no current terminal or no pattern match, creates 'local_1'."
  (interactive)
  (let* ((project-root (claude-code-normalize-project-root (projectile-project-root)))
         (sessions (claude-code-terminal-get-sessions project-root))
         (current-terminal-id (when (and (boundp 'claude-code-terminal-id)
                                        claude-code-terminal-id)
                               claude-code-terminal-id))
         (base-name (if (and current-terminal-id
                            (string-match "^\\(.+\\)_\\([0-9]+\\)$" current-terminal-id))
                       (match-string 1 current-terminal-id)
                     "local"))
         (existing-numbers (mapcar (lambda (session)
                                    (let ((id (cdr session)))
                                      (when (string-match (concat "^" (regexp-quote base-name) "_\\([0-9]+\\)$") id)
                                        (string-to-number (match-string 1 id)))))
                                  sessions))
         (max-number (if existing-numbers
                        (apply #'max (delq nil existing-numbers))
                      0))
         (new-terminal-id (format "%s_%d" base-name (1+ max-number)))
         (buffer-name (claude-code-terminal-buffer-name project-root new-terminal-id))
         (default-directory (or directory project-root)))
    
    ;; Create vterm buffer
    (let ((buffer (vterm buffer-name)))
      ;; Store terminal ID as buffer-local variable
      (with-current-buffer buffer
        (setq-local claude-code-terminal-id new-terminal-id)
        (setq-local claude-code-terminal-project-root project-root)
        ;; Enable claude terminal mode and apply font scaling
        (claude-code-terminal-mode 1)
        (claude-code-terminal-apply-large-font))
      
      ;; Register terminal session
      (claude-code-terminal-register project-root buffer-name new-terminal-id)
      
      ;; Update last created terminal ID and record access time
      (setq claude-code-terminal-last-created new-terminal-id)
      (puthash new-terminal-id (current-time) claude-code-terminal-access-times)
      
      ;; Switch to the buffer
      (switch-to-buffer buffer)
      
      new-terminal-id)))

(defun claude-code-terminal-switch-recent ()
  "Switch to the most recent terminal without prompting."
  (interactive)
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
        ;; Sort terminals by access time (most recent first) and switch to the first one
        (let* ((sorted-terminals 
                (sort other-terminals
                      (lambda (a b)
                        (let* ((id-a (plist-get a :terminal-id))
                               (id-b (plist-get b :terminal-id))
                               (time-a (gethash id-a claude-code-terminal-access-times nil))
                               (time-b (gethash id-b claude-code-terminal-access-times nil)))
                          ;; Sort by access time (most recent first)
                          (cond
                           ((and time-a time-b) (time-less-p time-b time-a))
                           (time-a nil)  ; a has time, b doesn't -> a comes first
                           (time-b t)    ; b has time, a doesn't -> b comes first  
                           (t nil)))))) ; both nil -> preserve order
               (most-recent-terminal (car sorted-terminals)))
          (when most-recent-terminal
            (let ((buffer (plist-get most-recent-terminal :buffer)))
              (when (buffer-live-p buffer)
                (switch-to-buffer buffer)
                ;; Update access time for the terminal we just switched to
                (claude-code-terminal-update-last-focused)
                (message "Switched to terminal: %s" 
                         (plist-get most-recent-terminal :terminal-id))))))
      (message "No other terminals available"))))

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

;;; Asynchronous Command Execution

(defun claude-code-terminal-async-check-output (terminal-id)
  "Check for output from asynchronous command in TERMINAL-ID."
  (let* ((async-info (gethash terminal-id claude-code-terminal-async-commands))
         (buffer (claude-code-terminal-get-by-id terminal-id))
         (start-marker (plist-get async-info :start-marker))
         (start-time (plist-get async-info :start-time))
         (callback (plist-get async-info :callback))
         (command (plist-get async-info :command))
         (timer (plist-get async-info :timer))
         (meaningful-found (plist-get async-info :meaningful-found))
         (wait-start (plist-get async-info :wait-start))
         (timeout-seconds 30)
         (wait-after-meaningful 0.5))
    
    (when (and async-info buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        (let* ((current-time (current-time))
               (elapsed (float-time (time-subtract current-time start-time)))
               (output (buffer-substring-no-properties start-marker (point-max)))
               ;; Try to remove just the command echo line, but be conservative
               (cleaned-output (if (string-match (concat "\\(^.*\\b" (regexp-quote command) "\\b.*?\r?\n\\)\\(.*\\)") output)
                                  (match-string 2 output)
                                output)))
          
          (cond
           ;; Timeout reached
           ((>= elapsed timeout-seconds)
            (when timer (cancel-timer timer))
            (remhash terminal-id claude-code-terminal-async-commands)
            (funcall callback (list :success nil 
                                    :stdout output
                                    :stderr "Command timed out waiting for output"
                                    :exit-code 124
                                    :timeout t
                                    :working-directory default-directory)))
           
           ;; Already found meaningful output, now check if wait period is over
           ((and meaningful-found wait-start
                 (>= (float-time (time-subtract current-time wait-start)) wait-after-meaningful))
            (when timer (cancel-timer timer))
            (remhash terminal-id claude-code-terminal-async-commands)
            (funcall callback (list :success t
                                    :stdout cleaned-output
                                    :stderr ""
                                    :exit-code 0
                                    :timeout nil
                                    :working-directory default-directory)))
           
           ;; Found meaningful output for the first time - start wait period  
           ((and (not meaningful-found)
                 (> (length output) 10)) ; Just check we have substantial output
            ;; Mark that we found meaningful output and start wait timer
            (plist-put (gethash terminal-id claude-code-terminal-async-commands) :meaningful-found t)
            (plist-put (gethash terminal-id claude-code-terminal-async-commands) :wait-start current-time)
            ;; Continue checking
            nil)
           
           ;; No meaningful output yet, continue checking
           (t
            ;; Timer will call this function again
            nil)))))))

(defun claude-code-terminal-execute-command-async (terminal-id command callback &optional project-root timeout)
  "Execute COMMAND asynchronously in terminal TERMINAL-ID.
CALLBACK will be called with the result plist when output is detected or timeout occurs.
Returns immediately without blocking."
  (let ((buffer (claude-code-terminal-get-by-id terminal-id project-root)))
    (if (not buffer)
        (funcall callback (list :success nil 
                               :stdout ""
                               :stderr "Terminal not found"
                               :exit-code 1
                               :timeout nil
                               :working-directory (or project-root default-directory)))
      
      (with-current-buffer buffer
        (if (not (derived-mode-p 'vterm-mode))
            (funcall callback (list :success nil 
                                   :stdout ""
                                   :stderr "Buffer is not in vterm-mode"
                                   :exit-code 1
                                   :timeout nil
                                   :working-directory (or project-root default-directory)))
          
          ;; Cancel any existing async command for this terminal
          (let ((existing-info (gethash terminal-id claude-code-terminal-async-commands)))
            (when existing-info
              (when-let ((existing-timer (plist-get existing-info :timer)))
                (cancel-timer existing-timer))
              (remhash terminal-id claude-code-terminal-async-commands)))
          
          ;; Set marker BEFORE sending command to catch all output
          (let* ((start-marker (point-max))
                 (start-time (current-time))
                 (check-interval 1) ; Check every 100ms
                 ;; Start timer with initial delay to let command begin execution
                 (timer (run-with-timer 0.05 check-interval 
                                       'claude-code-terminal-async-check-output terminal-id)))
          
          ;; Send the command AFTER setting up monitoring
          (vterm-send-string command)
          (vterm-send-return)
            
            ;; Store async command info
            (puthash terminal-id 
                     (list :start-time start-time
                           :start-marker start-marker
                           :callback callback
                           :timer timer
                           :command command
                           :meaningful-found nil
                           :wait-start nil)
                     claude-code-terminal-async-commands)
            
            ;; Return immediately
            (message "Command sent asynchronously: %s" command)))))))

(defun claude-code-terminal-execute-command-with-callback (terminal-id command callback &optional project-root)
  "Execute COMMAND asynchronously and call CALLBACK with results.
This is the recommended way to execute commands that might be continuous.
CALLBACK receives a plist: (:success t/nil :stdout string :stderr string :exit-code num :timeout t/nil :working-directory string)"
  (claude-code-terminal-execute-command-async terminal-id command callback project-root))

(defun claude-code-terminal-example-async-usage ()
  "Example of how to use asynchronous command execution.
This demonstrates running a continuous command like 'tail -f' without blocking Emacs."
  (interactive)
  (let ((terminal-id (claude-code-terminal-get-current-id)))
    (if terminal-id
        (claude-code-terminal-execute-command-with-callback
         terminal-id
         "tail -f /var/log/syslog" ; Example continuous command
         (lambda (result)
           (message "Async command result: %s" 
                   (if (plist-get result :success)
                       (format "SUCCESS: %s" (plist-get result :stdout))
                     (format "FAILED: %s" (plist-get result :stderr))))))
      (message "No terminal found"))))

;;; Terminal Content Access

(defun claude-code-terminal-get-content (terminal-id &optional project-root)
  "Get content of terminal buffer by TERMINAL-ID in PROJECT-ROOT."
  (let ((buffer (claude-code-terminal-get-by-id terminal-id project-root)))
    (when buffer
      (with-current-buffer buffer
        (buffer-substring-no-properties (point-min) (point-max))))))

(defun claude-code-terminal-execute-command (terminal-id command &optional project-root timeout async)
  "Execute COMMAND in terminal buffer TERMINAL-ID in PROJECT-ROOT.
If ASYNC is t (default), executes asynchronously and returns immediately.
If ASYNC is nil, uses synchronous execution and waits for command completion.
Returns a plist with :success, :stdout, :stderr, :exit-code, :timeout, :working-directory."
  (message "Executing command in terminal '%s' (%s): %s" terminal-id project-root command)
  (let ((buffer (claude-code-terminal-get-by-id terminal-id project-root))
        (timeout-seconds (or timeout 30))
        (async-mode (if (eq async nil) nil t))) ; Default to async=t
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
                 (start-marker (point-max)))
            
            (if async-mode
                ;; Async execution: monitor actual vterm process output
                (let* ((start-marker (point-max))
                       (completion-marker (format "__ASYNC_COMPLETE_%d__" (random 10000)))
                       (vterm-process (get-buffer-process (current-buffer))))

                  ;; Send command with completion marker to terminal
                  (vterm-send-string (format "%s; echo \"%s:$?\"" command completion-marker))
                  (vterm-send-return)
                  
                  ;; Simple polling-based approach
                  (let* ((start-time (current-time))
                         (check-interval 0.1) ; Check every 100ms
                         (last-content-length (length (buffer-substring-no-properties start-marker (point-max))))
                         (stable-count 0)
                         (min-stable-checks 3) ; Need 3 consecutive stable checks
                         (output "")
                         (exit-code 0)
                         (found-completion nil))
                    
                    ;; Poll for changes in buffer content
                    (while (and (< (float-time (time-subtract (current-time) start-time)) timeout-seconds)
                               (not found-completion))
                      (sleep-for check-interval)
                      
                      ;; Check current buffer content from our marker
                      (let* ((current-content (buffer-substring-no-properties start-marker (point-max)))
                             (current-length (length current-content)))
                        
                        ;; Check if we found the completion marker
                        (when (string-match (format "%s:\\([0-9]+\\)" completion-marker) current-content)
                          (setq exit-code (string-to-number (match-string 1 current-content)))
                          (setq found-completion t)
                          (setq output current-content))
                        
                        ;; Track stability (no new output for a few checks)
                        (if (= current-length last-content-length)
                            (setq stable-count (1+ stable-count))
                          (setq stable-count 0
                                last-content-length current-length))
                        
                        ;; If we have output but no completion marker, check if it's stable
                        (when (and (> current-length 0)
                                   (not found-completion)
                                   (>= stable-count min-stable-checks))
                          ;; Output seems stable, assume command finished
                          (setq output current-content
                                found-completion t
                                exit-code 0))))
                    
                    (list :success (and found-completion (= exit-code 0))
                          :stdout (or output "")
                          :stderr (if found-completion "" "Command timed out or no output")
                          :exit-code exit-code
                          :timeout (not found-completion)
                          :working-directory working-dir)))
              
              ;; Sync execution: wait for command completion
              (let* ((command-with-exit-code (format "%s; echo \"__EXIT_CODE__:$?\"" command))
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
                          :working-directory working-dir)))))))))))

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

;;; Shell Nesting Detection

(defun claude-code-terminal-extract-prompt-prefix (line)
  "Extract prompt prefix from LINE, ignoring common prompt suffixes and commands."
  (when line
    (let ((trimmed (string-trim line)))
      (cond
       ;; Git-style prompts - extract everything before the last command (if there is one)
       ((string-match "^\\(.*[✗✓⚡➜].*?\\)\\s-+\\([^[:space:]]+\\)\\s*$" trimmed)
        (string-trim (match-string 1 trimmed)))
       ;; Standard prompts ending with $ # > followed by command
       ((string-match "^\\(.*?[$#>]+\\)\\s-+\\([^[:space:]]+\\)" trimmed)
        (string-trim (match-string 1 trimmed)))
       ;; If line ends with just prompt characters, return as-is
       ((string-match "[$#>✗✓⚡➜]\\s-*$" trimmed)
        (string-trim trimmed))
       ;; Fallback: try to remove what looks like a command at the end
       ((string-match "^\\(.*?\\)\\s-+[^[:space:]]+\\s*$" trimmed)
        (string-trim (match-string 1 trimmed)))
       ;; If nothing matches, return the whole line
       (t (string-trim trimmed))))))

(defun claude-code-terminal-extract-command (line)
  "Extract the command (first word) from command LINE."
  (when line
    (let ((trimmed (string-trim line)))
      ;; Try multiple patterns to extract command
      (cond
       ;; Standard prompts ending with $ # > 
       ((string-match "^[^$#>]*[$#>]+\\s-*\\([^[:space:]]+\\)" trimmed)
        (match-string 1 trimmed))
       ;; Git-style prompts with symbols like ✗ ✓ etc.
       ((string-match "^.*[✗✓⚡➜][[:space:]]+\\([^[:space:]]+\\)" trimmed)
        (match-string 1 trimmed))
       ;; Fallback: look for last token that looks like a prompt separator followed by command
       ((string-match "\\s-\\([^[:space:]]+\\)\\s-+\\([^[:space:]]+\\)\\s*$" trimmed)
        (match-string 2 trimmed))
       ;; Last resort: take the last word if line seems like a command
       ((string-match "\\([^[:space:]]+\\)\\s*$" trimmed)
        (let ((last-word (match-string 1 trimmed)))
          ;; Only return if it looks like a command (not a path or complex string)
          (when (and last-word
                     (not (string-match-p "/" last-word))
                     (< (length last-word) 50))
            last-word)))))))

(defun claude-code-terminal-extract-full-command (line)
  "Extract the full command (everything after the prompt) from command LINE."
  (when line
    (let ((trimmed (string-trim line)))
      (cond
       ;; Git-style prompts - extract everything after the prompt symbols
       ((string-match "^.*[✗✓⚡➜][[:space:]]+\\(.*\\)$" trimmed)
        (string-trim (match-string 1 trimmed)))
       ;; Standard prompts ending with $ # >
       ((string-match "^[^$#>]*[$#>]+\\s-*\\(.*\\)$" trimmed)
        (string-trim (match-string 1 trimmed)))
       ;; Fallback: try to extract everything after what looks like a prompt
       ((string-match "^.*?\\s-+\\(.*\\)$" trimmed)
        (string-trim (match-string 1 trimmed)))
       ;; If nothing matches, return empty string
       (t "")))))

(defun claude-code-terminal-extract-prompt-only (line)
  "Extract just the prompt part from LINE, excluding any command."
  (when line
    (let ((trimmed (string-trim line)))
      (cond
       ;; Git-style prompts - extract everything up to and including the symbol, then remove command
       ((string-match "^\\(.*[✗✓⚡➜]\\)" trimmed)
        (string-trim (match-string 1 trimmed)))
       ;; Standard prompts ending with $ # > - extract up to the prompt symbol
       ((string-match "^\\(.*[$#>]\\)" trimmed)
        (string-trim (match-string 1 trimmed)))
       ;; Fallback - try to find the prompt by removing what looks like a command
       ((string-match "^\\(.*?\\)\\s-+[^[:space:]]+.*$" trimmed)
        (string-trim (match-string 1 trimmed)))
       ;; If nothing matches, return the whole line
       (t trimmed)))))

(defun claude-code-terminal-should-ignore-command-p (command)
  "Return t if COMMAND should be ignored for nesting detection."
  (or (not command)
      (member command claude-code-terminal-ignored-commands)
      (string-match-p "^\\s-*$" command)))

(defun claude-code-terminal-get-current-line ()
  "Get the current line content in the terminal."
  (save-excursion
    (end-of-line)
    (let ((end (point)))
      (beginning-of-line)
      (buffer-substring-no-properties (point) end))))

(defun claude-code-terminal-start-monitoring (terminal-id original-prefix)
  "Start monitoring for prompt changes to detect when we exit the embedded shell."
  (when claude-code-terminal-debug-mode
    (message "[DEBUG] Starting monitoring for terminal %s, watching for return to prefix: %s" 
             terminal-id original-prefix))
  
  ;; Start a timer that periodically checks if we've returned to the original prompt
  (let ((timer (run-at-time 1.0 1.0 'claude-code-terminal-check-exit terminal-id original-prefix)))
    (puthash terminal-id timer claude-code-terminal-pending-check)))

(defun claude-code-terminal-check-exit (terminal-id original-prefix)
  "Check if we've exited back to any known shell prompt in our stack."
  (let* ((terminal-buffer (claude-code-terminal-get-by-id terminal-id))
         (current-line (when terminal-buffer
                        (with-current-buffer terminal-buffer
                          (claude-code-terminal-get-current-line))))
         (current-prefix (when current-line
                          (claude-code-terminal-extract-prompt-prefix current-line)))
         (stack (gethash terminal-id claude-code-terminal-shell-stack)))
    
    ;; If terminal buffer is gone, stop monitoring
    (unless terminal-buffer
      (when claude-code-terminal-debug-mode
        (message "[DEBUG] Terminal %s buffer no longer exists, stopping monitoring" terminal-id))
      (let ((timer (gethash terminal-id claude-code-terminal-pending-check)))
        (when timer
          (cancel-timer timer)
          (remhash terminal-id claude-code-terminal-pending-check)))
      (cl-return-from claude-code-terminal-check-exit nil))
    
    (when claude-code-terminal-debug-mode
      (message "[DEBUG] Monitoring check for terminal %s:" terminal-id)
      (message "[DEBUG]   Current line: %s" current-line)
      (message "[DEBUG]   Current prefix: %s" current-prefix)
      (message "[DEBUG]   Looking for original prefix: %s" original-prefix)
      (message "[DEBUG]   Stack: %s" stack))
    
    ;; Check if we've returned to ANY known prefix in our stack (including original)
    (when (and current-prefix stack)
      (let ((found-context nil)
            (context-index 0))
        
        ;; First check if current prefix matches any context in the stack
        (let ((index 0))
          (dolist (context stack)
            (let ((context-prefix (cadr context)))
              (when (and context-prefix 
                         (string= current-prefix context-prefix)
                         (not found-context)) ; Take the first match
                (setq found-context index)))
            (setq index (1+ index))))
        
        ;; Only check for original prefix if we didn't find it in the stack
        (when (and (not found-context) original-prefix (string= current-prefix original-prefix))
          (setq found-context 'original))
        
        (when found-context
          (when claude-code-terminal-debug-mode
            (message "[DEBUG] Detected return to context: %s" found-context))
          
          ;; Cancel current monitoring
          (let ((timer (gethash terminal-id claude-code-terminal-pending-check)))
            (when timer
              (cancel-timer timer)
              (remhash terminal-id claude-code-terminal-pending-check)))
          
          (cond
           ;; Returned to original shell - clear everything
           ((eq found-context 'original)
            (remhash terminal-id claude-code-terminal-shell-stack)
            (remhash terminal-id claude-code-terminal-embedded-shells)
            (when claude-code-terminal-debug-mode
              (message "[DEBUG] Cleared all embedded contexts")))
           
           ;; Returned to a previous context in stack - pop to that level
           ((numberp found-context)
            (let* ((new-stack (nthcdr (1+ found-context) stack))
                   (current-command (if new-stack 
                                      (caar new-stack)
                                    nil)))
              (if new-stack
                  (progn
                    (puthash terminal-id new-stack claude-code-terminal-shell-stack)
                    (puthash terminal-id current-command claude-code-terminal-embedded-shells)
                    (when claude-code-terminal-debug-mode
                      (message "[DEBUG] Popped to previous context: %s" current-command))
                    ;; Start monitoring for the next level up
                    (claude-code-terminal-start-monitoring terminal-id (cadar new-stack)))
                ;; Stack is empty, clear everything
                (remhash terminal-id claude-code-terminal-shell-stack)
                (remhash terminal-id claude-code-terminal-embedded-shells)
                (when claude-code-terminal-debug-mode
                  (message "[DEBUG] Cleared all embedded contexts"))))))
          
          ;; Update display
          (when (and (bound-and-true-p claude-code-terminal-mode)
                     (bound-and-true-p claude-code-terminal-id)
                     (string= claude-code-terminal-id terminal-id))
            (force-mode-line-update))
          
          (message "Context changed"))))))

(defun claude-code-terminal-check-context-exit (terminal-id current-prefix)
  "Check if we've exited from an embedded shell context."
  (let ((stack (gethash terminal-id claude-code-terminal-shell-stack)))
    (when stack
      ;; Check if current prefix matches any previous context in the stack
      (let ((found-context nil)
            (new-stack '()))
        
        ;; Look through stack from newest to oldest
        (dolist (context stack)
          (let ((context-prefix (cadr context)))
            (if (and context-prefix 
                     (string= current-prefix context-prefix)
                     (not found-context))
                ;; Found the context we returned to
                (setq found-context context)
              ;; Keep contexts that are older than the one we returned to
              (when found-context
                (push context new-stack)))))
        
        (when found-context
          ;; We've exited one or more embedded shells
          (if new-stack
              (progn
                ;; Still in nested context, update stack
                (puthash terminal-id new-stack claude-code-terminal-shell-stack)
                (let ((current-command (caar new-stack)))
                  (puthash terminal-id current-command claude-code-terminal-embedded-shells)))
            ;; Returned to base context, clear everything
            (remhash terminal-id claude-code-terminal-shell-stack)
            (remhash terminal-id claude-code-terminal-embedded-shells))
          
          ;; Force header line update
          (when (and (bound-and-true-p claude-code-terminal-mode)
                     (bound-and-true-p claude-code-terminal-id)
                     (string= claude-code-terminal-id terminal-id))
            (force-mode-line-update))
          
          (message "Exited embedded shell context"))))))

(defun claude-code-terminal-on-return-pressed ()
  "Handle Return key press to detect context changes."
  (when (and (bound-and-true-p claude-code-terminal-id)
             (derived-mode-p 'vterm-mode))
    (let* ((terminal-id claude-code-terminal-id)
           (current-line (claude-code-terminal-get-current-line))
           (command (claude-code-terminal-extract-command current-line))
           (current-prefix (claude-code-terminal-extract-prompt-prefix current-line))
           (existing-timer (gethash terminal-id claude-code-terminal-pending-check)))
      
      (when claude-code-terminal-debug-mode
        (message "[DEBUG] Return pressed in terminal %s" terminal-id)
        (message "[DEBUG]   Command line: %s" current-line)
        (message "[DEBUG]   Extracted command: %s" command)
        (message "[DEBUG]   Current prefix: %s" current-prefix)
        (message "[DEBUG]   Should ignore: %s" (claude-code-terminal-should-ignore-command-p command)))
      
      ;; Cancel any existing timer
      (when existing-timer
        (cancel-timer existing-timer)
        (when claude-code-terminal-debug-mode
          (message "[DEBUG]   Cancelled existing timer")))
      
      ;; Store command info for later comparison
      (puthash terminal-id (list current-line current-prefix command) claude-code-terminal-last-command-line)
      
      ;; If command is not ignored, immediately set header and start monitoring
      (when (and command (not (claude-code-terminal-should-ignore-command-p command)))
        (when claude-code-terminal-debug-mode
          (message "[DEBUG] Command not ignored - setting header immediately"))
        
        ;; Extract full command for display (everything after the prompt)
        (let* ((full-command (claude-code-terminal-extract-full-command current-line))
               ;; Extract just the prompt part (remove the command from current-prefix)
               (clean-prefix (claude-code-terminal-extract-prompt-only current-line))
               (stack (gethash terminal-id claude-code-terminal-shell-stack '())))
          (when claude-code-terminal-debug-mode
            (message "[DEBUG] Full command for display: %s" full-command)
            (message "[DEBUG] Clean prefix to monitor: %s" clean-prefix))
          
          ;; Set header immediately with full command
          (push (list full-command clean-prefix) stack)
          (puthash terminal-id stack claude-code-terminal-shell-stack)
          (puthash terminal-id full-command claude-code-terminal-embedded-shells)
          (force-mode-line-update)
          
          ;; Start monitoring for the clean prefix (without command)
          (claude-code-terminal-start-monitoring terminal-id clean-prefix))))))

(defun claude-code-terminal-reset-context (terminal-id)
  "Reset shell nesting context for TERMINAL-ID."
  (when claude-code-terminal-debug-mode
    (message "[DEBUG] Resetting context for terminal %s" terminal-id))
  
  (remhash terminal-id claude-code-terminal-shell-stack)
  (remhash terminal-id claude-code-terminal-embedded-shells)
  (remhash terminal-id claude-code-terminal-last-command-line)
  
  ;; Cancel pending check timer
  (let ((timer (gethash terminal-id claude-code-terminal-pending-check)))
    (when timer
      (cancel-timer timer)
      (remhash terminal-id claude-code-terminal-pending-check)
      (when claude-code-terminal-debug-mode
        (message "[DEBUG] Cancelled monitoring timer"))))
  
  ;; Cancel async command timer
  (let ((async-info (gethash terminal-id claude-code-terminal-async-commands)))
    (when async-info
      (when-let ((async-timer (plist-get async-info :timer)))
        (cancel-timer async-timer)
        (when claude-code-terminal-debug-mode
          (message "[DEBUG] Cancelled async command timer")))
      (remhash terminal-id claude-code-terminal-async-commands))))

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

;; Auto-cleanup sentinel for vterm process exit
(defun claude-code-terminal--vterm-exit-sentinel (process event)
  "Kill buffer when vterm process exits cleanly (via C-d or exit)."
  (when (and (not (process-live-p process))
             (string-match-p "\\(finished\\|exited\\)" event))
    (let ((buf (process-buffer process)))
      (when (and (buffer-live-p buf)
                 (with-current-buffer buf
                   (bound-and-true-p claude-code-terminal-id)))
        (message "Terminal %s closed" 
                 (with-current-buffer buf claude-code-terminal-id))
        (kill-buffer buf)))))

;; Add cleanup hook
(add-hook 'kill-buffer-hook 
          (lambda ()
            (when (bound-and-true-p claude-code-terminal-id)
              (claude-code-terminal-unregister 
               claude-code-terminal-project-root 
               (buffer-name))
              ;; Clean up shell nesting context
              (claude-code-terminal-reset-context claude-code-terminal-id))))

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
          ;; Use completion system with proper ordering preservation and preview
          (let ((choice (cond
                         ;; For ivy, disable sorting and add preview
                         ((and (boundp 'ivy-mode) ivy-mode)
                          (let ((ivy-sort-functions-alist nil))
                            (ivy-read "Switch to terminal (recent first): " choices
                                      :action (lambda (x) x)
                                      :update-fn (lambda ()
                                                   (when ivy--current
                                                     (let* ((choice-entry (assoc ivy--current choices))
                                                            (term (when choice-entry (cdr choice-entry)))
                                                            (buffer (when term (plist-get term :buffer))))
                                                       (when (and buffer (buffer-live-p buffer))
                                                         (switch-to-buffer buffer))))))))
                         
                         ;; For vertico, disable sorting and add preview
                         ((and (boundp 'vertico-mode) vertico-mode)
                          (let ((vertico-sort-function nil))
                            (minibuffer-with-setup-hook
                                (lambda ()
                                  ;; Hook into vertico's selection change
                                  (when (boundp 'vertico--index)
                                    (let ((preview-function 
                                           (lambda ()
                                             (when (and (boundp 'vertico--candidates) 
                                                        (boundp 'vertico--index)
                                                        vertico--candidates
                                                        vertico--index
                                                        (>= vertico--index 0)
                                                        (< vertico--index (length vertico--candidates)))
                                               (let* ((selected-candidate (nth vertico--index vertico--candidates))
                                                      (choice-entry (assoc selected-candidate choices))
                                                      (term (when choice-entry (cdr choice-entry)))
                                                      (buffer (when term (plist-get term :buffer))))
                                                 (when (and buffer (buffer-live-p buffer))
                                                   (with-selected-window (minibuffer-selected-window)
                                                     (switch-to-buffer buffer))))))))
                                      ;; Add hook for navigation changes
                                      (add-hook 'post-command-hook preview-function nil t)
                                      ;; Also trigger preview immediately for initial selection
                                      (run-with-timer 0.01 nil preview-function))))
                              (completing-read "Switch to terminal (recent first): " choices nil t))))
                         
                         ;; For helm, disable sorting and add preview
                         ((and (boundp 'helm-mode) helm-mode)
                          (let ((helm-candidate-sort-fn nil))
                            (helm :sources
                                  (helm-build-sync-source "Terminals"
                                    :candidates choices
                                    :persistent-action (lambda (candidate)
                                                         (let* ((choice-entry (assoc candidate choices))
                                                                (term (when choice-entry (cdr choice-entry)))
                                                                (buffer (when term (plist-get term :buffer))))
                                                           (when (and buffer (buffer-live-p buffer))
                                                             (switch-to-buffer buffer))))
                                    :action (lambda (candidate) candidate))
                                  :prompt "Switch to terminal (recent first): ")))
                         
                         ;; For default completing-read with basic preview
                         (t
                          (minibuffer-with-setup-hook
                              (lambda ()
                                (add-hook 'after-change-functions
                                          (lambda (&rest _)
                                            (let* ((input (minibuffer-contents))
                                                   (match (try-completion input choices)))
                                              (when (and match (stringp match))
                                                (let* ((choice-entry (assoc match choices))
                                                       (term (when choice-entry (cdr choice-entry)))
                                                       (buffer (when term (plist-get term :buffer))))
                                                  (when (and buffer (buffer-live-p buffer))
                                                    (with-selected-window (minibuffer-selected-window)
                                                      (switch-to-buffer buffer)))))))
                                          nil t))
                            (let ((completion-cycle-threshold nil)
                                  (read-file-name-completion-ignore-case nil))
                              (completing-read "Switch to terminal (recent first): " choices nil t)))))))
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

(defun claude-code-terminal-mark-embedded (command)
  "Manually mark current terminal as being in an embedded shell with COMMAND."
  (interactive "sEmbedded shell command: ")
  (let ((terminal-id (claude-code-terminal-get-current-id)))
    (unless terminal-id
      (user-error "Not in a Claude terminal buffer"))
    
    (when (string-empty-p command)
      (user-error "Command cannot be empty"))
    
    ;; Add to embedded shells tracking
    (puthash terminal-id command claude-code-terminal-embedded-shells)
    
    ;; Force header line update
    (force-mode-line-update)
    
    (message "Marked terminal as embedded shell: %s" command)))

(defun claude-code-terminal-unmark-embedded ()
  "Manually remove embedded shell marking from current terminal."
  (interactive)
  (let ((terminal-id (claude-code-terminal-get-current-id)))
    (unless terminal-id
      (user-error "Not in a Claude terminal buffer"))
    
    ;; Reset the context completely
    (claude-code-terminal-reset-context terminal-id)
    
    ;; Force header line update
    (force-mode-line-update)
    
    (message "Removed embedded shell marking")))

(defun claude-code-terminal-show-context ()
  "Show current shell nesting context for debugging."
  (interactive)
  (let* ((terminal-id (claude-code-terminal-get-current-id))
         (stack (when terminal-id (gethash terminal-id claude-code-terminal-shell-stack)))
         (embedded (when terminal-id (gethash terminal-id claude-code-terminal-embedded-shells))))
    
    (unless terminal-id
      (user-error "Not in a Claude terminal buffer"))
    
    (with-output-to-temp-buffer "*Terminal Context*"
      (princ (format "=== Terminal Context for %s ===\n\n" terminal-id))
      
      (princ (format "Current embedded shell: %s\n\n" 
                     (or embedded "None")))
      
      (if stack
          (progn
            (princ "Shell stack (newest first):\n")
            (let ((index 1))
              (dolist (context stack)
                (princ (format "  %d. Command: %s\n" index (car context)))
                (princ (format "     Prompt:  %s\n" (cadr context)))
                (setq index (1+ index)))))
        (princ "No shell stack\n"))
      
      (princ "\n=== Variables ===\n")
      (princ (format "Check delay: %s seconds\n" claude-code-terminal-check-delay))
      (princ (format "Ignored commands: %s\n" claude-code-terminal-ignored-commands))
      (princ (format "Debug mode: %s\n" claude-code-terminal-debug-mode)))))

(defun claude-code-terminal-toggle-debug ()
  "Toggle debug mode for shell nesting detection."
  (interactive)
  (setq claude-code-terminal-debug-mode (not claude-code-terminal-debug-mode))
  (message "Terminal debug mode: %s" 
           (if claude-code-terminal-debug-mode "ENABLED" "DISABLED")))

(defun claude-code-terminal-test-regexes ()
  "Test the prompt extraction regexes with sample lines."
  (interactive)
  (let ((test-lines '("user@host:~/project $ kubectl exec -it pod -- bash"
                     "root@pod:/code# ls"
                     ">>> print('hello')"
                     "mysql> SELECT * FROM users;"
                     "➜  terminal git:(master) ✗ kbash webpush-directory-responses-develop-8695574569-qdxcd"
                     "root@webpush-directory-responses-develop-8695574569-qdxcd:/code# pwd")))
    (with-output-to-temp-buffer "*Regex Test*"
      (princ "=== Prompt Extraction Test ===\n\n")
      (dolist (line test-lines)
        (princ (format "Line: %s\n" line))
        (princ (format "  Prefix: %s\n" (claude-code-terminal-extract-prompt-prefix line)))
        (princ (format "  Command: %s\n\n" (claude-code-terminal-extract-command line)))))))

;;; Mode Definition

(defvar claude-code-terminal-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") (lambda () (interactive) (vterm-send-C-c)))
    (define-key map (kbd "C-c C-k") #'claude-code-terminal-kill)
    (define-key map (kbd "C-c C-s") #'claude-code-terminal-switch)
    (define-key map (kbd "C-c C-t") #'claude-code-terminal-cycle-prefix)
    ;; Shell nesting commands
    (define-key map (kbd "C-c C-m") #'claude-code-terminal-mark-embedded)
    (define-key map (kbd "C-c C-u") #'claude-code-terminal-unmark-embedded)
    (define-key map (kbd "C-c C-d") #'claude-code-terminal-show-context)
    (define-key map (kbd "C-c C-g") #'claude-code-terminal-toggle-debug)
    ;; Override C-u for terminal switching (takes precedence over universal-argument)
    (define-key map (kbd "C-u") #'claude-code-terminal-switch)
    ;; Override C-f for terminal prefix cycling (only in terminal buffers)
    (define-key map (kbd "C-f") #'claude-code-terminal-switch-recent)
    (define-key map (kbd "C-g") #'claude-code-terminal-cycle-prefix)
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
  "Generate header line with terminal ID, embedded shell status, and current state background."
  (let* ((terminal-id claude-code-terminal-id)
         (embedded-shell (gethash terminal-id claude-code-terminal-embedded-shells))
         (state-name (claude-code-terminal-get-evil-state-name))
         ;; Check if this window is focused in the right chat layout position
         (is-focused-right (claude-code-terminal-is-in-focused-right-window))
         (bg-color (if is-focused-right
                       "#ff0000"  ; BRIGHT RED for testing - very obvious
                     (claude-code-terminal-get-evil-state-background)))
         (fg-color (if is-focused-right
                       "#ffffff"  ; White text for focused right window
                     (claude-code-terminal-get-evil-state-foreground)))
         ;; Add very obvious text when focused
         (focus-indicator (if is-focused-right " ★★★ FOCUSED RIGHT WINDOW ★★★ " ""))
         (text (if embedded-shell
                   (format " :: %s :: %s %s" terminal-id embedded-shell focus-indicator)
                 (format " :: %s %s" terminal-id focus-indicator)))
         (width (window-width))
         (remaining-width (max 0 (- width (length text))))
         (full-line (concat text (make-string remaining-width ?\s))))
    (propertize full-line 'face `(:background ,bg-color :foreground ,fg-color :weight bold :height 1.5))))

(defun claude-code-terminal-is-in-focused-right-window ()
  "Check if current Claude terminal window is the focused right window in my-layout system."
  (let ((terminal-id (bound-and-true-p claude-code-terminal-id))
        (focus-flag (bound-and-true-p my-layout--is-focused-right-window))
        (buffer-name (buffer-name)))
    ;; Just check the basic focus flag for now - remove complex window checking
    (and terminal-id focus-flag)))

(define-minor-mode claude-code-terminal-mode
  "Minor mode for Claude Code terminal buffers."
  :lighter " CC-Term"
  :keymap claude-code-terminal-mode-map
  (if claude-code-terminal-mode
      (progn
        ;; Setup auto-cleanup when vterm process exits
        (when (and (derived-mode-p 'vterm-mode)
                   (get-buffer-process (current-buffer)))
          (set-process-sentinel (get-buffer-process (current-buffer))
                               #'claude-code-terminal--vterm-exit-sentinel))
        
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

;; Force modeline update when window selection changes
(add-hook 'window-selection-change-functions
          (lambda (frame)
            (dolist (window (window-list frame))
              (with-current-buffer (window-buffer window)
                (when (bound-and-true-p claude-code-terminal-mode)
                  (force-mode-line-update))))))

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
  (define-key vterm-mode-map (kbd "C-u") 'claude-code-terminal-switch)
  
  ;; Hook into Return key for shell nesting detection
  (advice-add 'vterm-send-return :before 'claude-code-terminal-on-return-pressed)
  (message "[DEBUG] Added advice to vterm-send-return"))

;; Evil mode bindings for terminal switching - ensures C-u works in all evil states
(with-eval-after-load 'evil
  (evil-define-key 'insert claude-code-terminal-mode-map (kbd "C-u") 'claude-code-terminal-switch)
  (evil-define-key 'normal claude-code-terminal-mode-map (kbd "C-u") 'claude-code-terminal-switch)
  (evil-define-key 'emacs claude-code-terminal-mode-map (kbd "C-u") 'claude-code-terminal-switch)
  (evil-define-key 'emacs claude-code-terminal-mode-map (kbd "s-k") 'my-layout-smart-claude-code)
  (evil-define-key 'insert claude-code-terminal-mode-map (kbd "s-k") 'my-layout-smart-claude-code)
  (evil-define-key 'normal claude-code-terminal-mode-map (kbd "s-k") 'my-layout-smart-claude-code)
  
  ;; Evil mode bindings for terminal quick switching - only in terminal buffers
  (evil-define-key 'insert claude-code-terminal-mode-map (kbd "C-f") 'claude-code-terminal-switch-recent)
  (evil-define-key 'normal claude-code-terminal-mode-map (kbd "C-f") 'claude-code-terminal-switch-recent)
  (evil-define-key 'emacs claude-code-terminal-mode-map (kbd "C-f") 'claude-code-terminal-switch-recent)
  
  ;; Override Evil C-g for terminal prefix cycling in all states
  (evil-define-key 'insert claude-code-terminal-mode-map (kbd "C-g") 'claude-code-terminal-cycle-prefix)
  (evil-define-key 'normal claude-code-terminal-mode-map (kbd "C-g") 'claude-code-terminal-cycle-prefix)
  (evil-define-key 'emacs claude-code-terminal-mode-map (kbd "C-g") 'claude-code-terminal-cycle-prefix)
  
  ;; Evil mode bindings for shell nesting commands
  (evil-define-key 'insert claude-code-terminal-mode-map (kbd "C-c C-m") 'claude-code-terminal-mark-embedded)
  (evil-define-key 'normal claude-code-terminal-mode-map (kbd "C-c C-m") 'claude-code-terminal-mark-embedded)
  (evil-define-key 'emacs claude-code-terminal-mode-map (kbd "C-c C-m") 'claude-code-terminal-mark-embedded)
  
  (evil-define-key 'insert claude-code-terminal-mode-map (kbd "C-c C-u") 'claude-code-terminal-unmark-embedded)
  (evil-define-key 'normal claude-code-terminal-mode-map (kbd "C-c C-u") 'claude-code-terminal-unmark-embedded)
  (evil-define-key 'emacs claude-code-terminal-mode-map (kbd "C-c C-u") 'claude-code-terminal-unmark-embedded)
  
  (evil-define-key 'insert claude-code-terminal-mode-map (kbd "C-c C-d") 'claude-code-terminal-show-context)
  (evil-define-key 'normal claude-code-terminal-mode-map (kbd "C-c C-d") 'claude-code-terminal-show-context)
  (evil-define-key 'emacs claude-code-terminal-mode-map (kbd "C-c C-d") 'claude-code-terminal-show-context)
  
  ;; Global evil bindings - override C-u everywhere to do terminal switching
  (evil-global-set-key 'normal (kbd "C-u") 'claude-code-terminal-switch)
  (evil-global-set-key 'insert (kbd "C-u") 'claude-code-terminal-switch)
  (evil-global-set-key 'visual (kbd "C-u") 'claude-code-terminal-switch)
  (evil-global-set-key 'emacs (kbd "C-u") 'claude-code-terminal-switch))

;; Also override in global map for non-evil scenarios
(global-set-key (kbd "C-u") 'claude-code-terminal-switch)

(provide 'claude-code-terminal)
;;; claude-code-terminal.el ends here
