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
(require 'eshell)
(require 'esh-mode)
(require 'em-prompt)

;; Forward declaration for functions from claude-code.el
(declare-function claude-code--do-send-command "claude-code" (cmd))

;;; Variables

(defvar claude-code-terminal-sessions (make-hash-table :test 'equal)
  "Hash table tracking terminal sessions by project root.
Each value is a list of (buffer-name . terminal-id) pairs.")

(defvar claude-code-terminal-mistty-buffers (make-hash-table :test 'equal)
  "Hash table mapping terminal-id to active mistty buffer.
When a terminal is in embedded mode (ssh, docker exec, etc.),
the mistty buffer takes over and should be used instead of eshell.")

(defvar-local claude-code-terminal-embedded-command nil
  "The embedding command that started this mistty session (e.g., ssh, kubectl exec).")

(defvar claude-code-terminal-counter 0
  "Counter for generating unique terminal IDs.")

(defvar claude-code-terminal-directory-tracking-enabled t
  "Enable automatic directory tracking for find-file commands.
When enabled, find-file will use the current eshell terminal working directory
instead of the buffer's default-directory.")

(defvar claude-code-terminal-last-directory-sync-time (make-hash-table :test 'equal)
  "Hash table tracking last directory sync time for each terminal ID.
Used to prevent excessive directory syncing.")

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

(defvar claude-code-terminal-monitored-commands
  '("kubectl" "docker" "ssh" "bash" "zsh" "sh" "python" "mysql" "psql" "redis-cli" 
    "vim" "emacs" "nano" "htop" "top" "watch" "tail" "less" "more" "man" "git"
    "npm" "node" "make" "cargo" "go" "java" "mvn" "gradle" "terraform" "ansible"
    "gdb" "lldb" "k9s" "helm" "minikube" "vagrant" "tmux" "screen" "nohup"
    "jupyter" "ipython" "R" "sqlite3" "mongo" "curl" "wget" "nc" "telnet" "ping"
    "traceroute" "mtr" "dig" "nslookup" "iperf" "iperf3" "tcpdump" "wireshark"
    "strace" "ltrace" "perf" "valgrind" "gprof" "kbash" "klogs" "kedit" "kdjan" "adb" "psql")
  "Commands that should be monitored for embedded shell context and status display.
These commands typically create interactive sessions or long-running processes.")

(defvar claude-code-terminal-debug-mode nil
  "Enable debug messages for shell nesting detection.")

;;; Directory Tracking Functions

(defun claude-code-terminal-sync-directory (terminal-id)
  "Synchronize default-directory with eshell's working directory.
For eshell, default-directory is automatically tracked, so this mostly validates and records the sync."
  (message "[DEBUG] Starting sync for terminal-id: %s" terminal-id)
  (when-let ((buffer (claude-code-terminal-get-by-id terminal-id)))
    (message "[DEBUG] Found buffer: %s" buffer)
    (with-current-buffer buffer
      (message "[DEBUG] Mode check - eshell-mode: %s" (derived-mode-p 'eshell-mode))
      (when (derived-mode-p 'eshell-mode)
        ;; Eshell automatically tracks default-directory
        (let ((dir default-directory))
          (message "[DEBUG] Current directory: %s" dir)
          (when (and dir (file-directory-p dir))
            (puthash terminal-id (current-time) claude-code-terminal-last-directory-sync-time)
            (message "[DEBUG] Successfully synced directory for %s: %s" terminal-id dir)
            dir))))))

(defun claude-code-terminal-find-file-with-terminal-directory ()
  "Enhanced find-file that uses current eshell working directory.
When called from an eshell terminal buffer, uses the terminal's PWD."
  (interactive)
  (if-let ((terminal-id (claude-code-terminal-get-current-id)))
      (progn
        ;; Sync directory (eshell auto-tracks, but this records the sync)
        (claude-code-terminal-sync-directory terminal-id)
        ;; Then call find-file normally - it will use default-directory
        (call-interactively 'find-file))
    ;; Not in a terminal buffer, use normal find-file
    (call-interactively 'find-file)))

;; Hook to override find-file in eshell terminal buffers
(defun claude-code-terminal-setup-directory-hooks ()
  "Set up hooks for on-demand directory synchronization."
  ;; Override find-file in eshell buffers to use synced directory
  (add-hook 'eshell-mode-hook
            (lambda ()
              (when (bound-and-true-p claude-code-terminal-id)
                (local-set-key (kbd "C-x C-f") 'claude-code-terminal-find-file-with-terminal-directory)
                (local-set-key (kbd "s-f") 'claude-code-terminal-find-file-with-terminal-directory)))))

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

    ;; Create eshell terminal buffer
    (let ((buffer (claude-code-terminal--create-eshell-buffer buffer-name)))
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

(defun claude-code-terminal--create-eshell-buffer (buffer-name)
  "Create a new eshell buffer with BUFFER-NAME.
Returns the created buffer."
  (let ((eshell-buffer-name buffer-name))
    (save-window-excursion
      (eshell 'N))  ; 'N means create new buffer regardless of existing ones
    (get-buffer buffer-name)))

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

    ;; Create eshell terminal buffer
    (let ((buffer (claude-code-terminal--create-eshell-buffer buffer-name)))
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
  "Get terminal buffer by TERMINAL-ID in PROJECT-ROOT.
First checks registered sessions, then scans all buffers for unregistered terminals.
If terminal has active mistty (embedded mode), returns mistty buffer instead."
  (let* ((root (or project-root (claude-code-normalize-project-root (projectile-project-root))))
         (sessions (claude-code-terminal-get-sessions root))
         (eshell-buffer
          (or
           ;; First try registered sessions
           (catch 'found
             (dolist (session sessions)
               (when (string= (cdr session) terminal-id)
                 (let ((buffer (get-buffer (car session))))
                   (when (and buffer (buffer-live-p buffer))
                     (throw 'found buffer)))))
             nil)
           ;; Fall back to scanning all buffers for unregistered terminals
           (catch 'found
             (dolist (buffer (buffer-list))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (when (and (bound-and-true-p claude-code-terminal-id)
                              (string= claude-code-terminal-id terminal-id))
                     (throw 'found buffer)))))
             nil))))
    ;; Check if mistty is active for this terminal
    (if (and (boundp 'claude-code-terminal-mistty-buffers)
             (hash-table-p claude-code-terminal-mistty-buffers))
        (let ((mistty-buf (gethash terminal-id claude-code-terminal-mistty-buffers)))
          (if (and mistty-buf (buffer-live-p mistty-buf))
              mistty-buf
            eshell-buffer))
      eshell-buffer)))

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

(defun claude-code-terminal--get-effective-buffer (terminal-id eshell-buffer)
  "Get the effective buffer for TERMINAL-ID.
Returns mistty buffer if embedded mode active, otherwise ESHELL-BUFFER."
  (let ((mistty-buf (gethash terminal-id claude-code-terminal-mistty-buffers)))
    (if (and mistty-buf (buffer-live-p mistty-buf))
        mistty-buf
      eshell-buffer)))

(defun claude-code-terminal-list-active ()
  "List all active terminal buffers with their IDs.
Also discovers eshell buffers with `claude-code-terminal-mode' that may not be registered.
When a terminal has active mistty (embedded mode), returns mistty buffer instead of eshell."
  (interactive)
  (let ((active-terminals '())
        (seen-buffers '()))
    ;; First, get terminals from the registered sessions
    (maphash (lambda (project-root sessions)
               (dolist (session sessions)
                 (let* ((eshell-buffer (get-buffer (car session)))
                        (terminal-id (cdr session))
                        (effective-buffer (when (and eshell-buffer (buffer-live-p eshell-buffer))
                                            (claude-code-terminal--get-effective-buffer terminal-id eshell-buffer))))
                   (when effective-buffer
                     (push eshell-buffer seen-buffers)  ;; Track eshell as seen
                     (push (list :project-root project-root
                                :buffer-name (car session)
                                :terminal-id terminal-id
                                :buffer effective-buffer  ;; Use mistty if active
                                :eshell-buffer eshell-buffer)  ;; Keep reference to eshell
                           active-terminals)))))
             claude-code-terminal-sessions)
    ;; Also scan for unregistered eshell terminal buffers
    (dolist (buffer (buffer-list))
      (when (and (buffer-live-p buffer)
                 (not (memq buffer seen-buffers)))
        (with-current-buffer buffer
          (cond
           ;; Case 1: Buffer has claude-code-terminal-mode and ID (skip mistty embedded buffers)
           ((and (bound-and-true-p claude-code-terminal-mode)
                 (bound-and-true-p claude-code-terminal-id)
                 (not (bound-and-true-p claude-code-terminal-embedded-command)))
            (let* ((project-root (or (bound-and-true-p claude-code-terminal-project-root)
                                     default-directory))
                   (effective-buffer (claude-code-terminal--get-effective-buffer
                                      claude-code-terminal-id buffer)))
              (claude-code-terminal-register project-root (buffer-name) claude-code-terminal-id)
              (push (list :project-root project-root
                         :buffer-name (buffer-name)
                         :terminal-id claude-code-terminal-id
                         :buffer effective-buffer
                         :eshell-buffer buffer)
                    active-terminals)))
           ;; Case 2: Eshell buffer matching our naming pattern *claude-terminal:*
           ((and (derived-mode-p 'eshell-mode)
                 (string-match "\\*claude-terminal:\\([^:]+\\):\\([^*]+\\)\\*" (buffer-name)))
            (let* ((project-root (match-string 1 (buffer-name)))
                   (terminal-id (match-string 2 (buffer-name)))
                   (effective-buffer (claude-code-terminal--get-effective-buffer terminal-id buffer)))
              ;; Set buffer-local variables and enable mode
              (setq-local claude-code-terminal-id terminal-id)
              (setq-local claude-code-terminal-project-root project-root)
              (claude-code-terminal-mode 1)
              (claude-code-terminal-register project-root (buffer-name) terminal-id)
              (push (list :project-root project-root
                         :buffer-name (buffer-name)
                         :terminal-id terminal-id
                         :buffer effective-buffer
                         :eshell-buffer buffer)
                    active-terminals)))))))
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
      (condition-case err
          (with-current-buffer buffer
            (let* ((current-time (current-time))
                   (elapsed (float-time (time-subtract current-time start-time)))
                   ;; Safely get output, handling invalid markers
                   (safe-start (max (point-min) (min start-marker (point-max))))
                   (output (buffer-substring-no-properties safe-start (point-max)))
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
           
           ;; Check for command completion using prompt detection
           ((not meaningful-found)
            (let* ((current-line (claude-code-terminal-get-current-line))
                   (current-prompt (when (and current-line (stringp current-line))
                                    (claude-code-terminal-extract-prompt-only current-line)))
                   ;; Get original prompt when command was sent
                   (original-prompt (when-let ((command-data (gethash terminal-id claude-code-terminal-last-command-line)))
                                     (let ((command-line (if (listp command-data) (car command-data) command-data)))
                                       (when (stringp command-line)
                                         (claude-code-terminal-extract-prompt-only command-line))))))
              ;; Command completed if we see a prompt again and have some output
              (if (and current-prompt
                       original-prompt
                       (string= current-prompt original-prompt)
                       (> (length output) 5)) ; Minimal output threshold
                  ;; Command completed - finish immediately
                  (progn
                    (when timer (cancel-timer timer))
                    (remhash terminal-id claude-code-terminal-async-commands)
                    (funcall callback (list :success t
                                            :stdout cleaned-output
                                            :stderr ""
                                            :exit-code 0
                                            :timeout nil
                                            :working-directory default-directory)))
                ;; Not completed yet, continue checking
                nil)))
           
           ;; Fallback: use old logic for non-prompt-based detection
           (t
            ;; If we have substantial output but no clear prompt, use the old wait logic
            (if (> (length output) 10)
                (progn
                  (plist-put (gethash terminal-id claude-code-terminal-async-commands) :meaningful-found t)
                  (plist-put (gethash terminal-id claude-code-terminal-async-commands) :wait-start current-time)
                  nil)
              ;; Continue checking
              nil)))))
        ;; Error handling - cancel timer and cleanup on any error
        (error
         (when timer (cancel-timer timer))
         (remhash terminal-id claude-code-terminal-async-commands)
         (message "Terminal async monitoring error for %s: %s" terminal-id (error-message-string err)))))))

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
        (if (not (derived-mode-p 'eshell-mode))
            (funcall callback (list :success nil
                                   :stdout ""
                                   :stderr "Buffer is not in eshell-mode"
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
                 (check-interval 1) ; Check every second
                 ;; Capture current prompt before sending command
                 (current-line (claude-code-terminal-get-current-line))
                 (original-prompt (when current-line
                                   (claude-code-terminal-extract-prompt-only current-line)))
                 ;; Start timer with initial delay to let command begin execution
                 (timer (run-with-timer 0.05 check-interval
                                       'claude-code-terminal-async-check-output terminal-id)))

          ;; Store the original command line for prompt comparison
          (when current-line
            (puthash terminal-id (list current-line original-prompt command) claude-code-terminal-last-command-line))

          ;; Send the command to eshell
          (goto-char (point-max))
          (insert command)
          (eshell-send-input)

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

(defun claude-code-terminal-send-string (buffer string &optional send-newline)
  "Send STRING to terminal BUFFER (eshell or mistty).
If SEND-NEWLINE is non-nil, also execute the command (send Enter).
This function handles eshell's text-based input model and mistty."
  (with-current-buffer buffer
    (cond
     ;; Mistty buffer - use mistty API
     ((and (bound-and-true-p claude-code-terminal-embedded-command)
           (fboundp 'mistty-send-string))
      (mistty-send-string string)
      (when send-newline
        (mistty-send-command)))
     ;; Eshell buffer
     ((derived-mode-p 'eshell-mode)
      (goto-char (point-max))
      (insert string)
      (when send-newline
        (eshell-send-input)))
     ;; Fallback for other terminal types (vterm, etc.)
     (t
      (let ((proc (get-buffer-process buffer)))
        (when proc
          (process-send-string proc string)
          (when send-newline
            (process-send-string proc "\n"))))))))

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
        (if (not (derived-mode-p 'eshell-mode))
            (list :success nil
                  :stdout ""
                  :stderr "Buffer is not in eshell-mode"
                  :exit-code 1
                  :timeout nil
                  :working-directory (or project-root default-directory))
          ;; Get current working directory from terminal
          (let* ((working-dir default-directory)
                 (start-marker (point-max)))

            (if async-mode
                ;; Async execution: monitor eshell output
                (let* ((start-marker (point-max))
                       (completion-marker (format "__ASYNC_COMPLETE_%d__" (random 10000))))

                  ;; Send command with completion marker to eshell
                  (goto-char (point-max))
                  (insert (format "%s; echo \"%s:$?\"" command completion-marker))
                  (eshell-send-input)

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

                ;; Send command with exit code capture to eshell
                (goto-char (point-max))
                (insert command-with-exit-code)
                (eshell-send-input)

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
       ;; ((string-match "^\\(.*[✗✓⚡➜].*?\\)\\s-+\\([^[:space:]]+\\)\\s*$" trimmed)
       ;;  (string-trim (match-string 1 trimmed)))
       ;; Standard prompts ending with $ # > followed by command
       ((string-match "^\\(.*?[$#>]+\\)\\s-+\\([^[:space:]]+\\)" trimmed)
        (string-trim (match-string 1 trimmed)))
       ;; If line ends with just prompt characters, return as-is
       ((string-match "[$#>✗✓⚡➜]\\s-*$" trimmed)
        (string-trim trimmed))
       ;; Fallback: try to remove what looks like a command at the end
       ;; ((string-match "^\\(.*?\\)\\s-+[^[:space:]]+\\s*$" trimmed)
       ;;  (string-trim (match-string 1 trimmed)))
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

(defun claude-code-terminal-should-monitor-command-p (command)
  "Return t if COMMAND should be monitored for nesting detection.
Uses a whitelist approach - only predefined commands are monitored."
  (and command
       (not (string-match-p "^\\s-*$" command))
       (member command claude-code-terminal-monitored-commands)))


(defun claude-code-terminal-get-current-line ()
  "Get the current line content in the terminal.
For eshell, gets the current input line at the prompt."
  (save-excursion
    (cond
     ;; For eshell, get the current prompt line
     ((derived-mode-p 'eshell-mode)
      (goto-char (point-max))
      (let ((end (line-end-position)))
        (eshell-bol)  ; Go to beginning of eshell line (after prompt)
        (beginning-of-line)  ; Go to actual beginning including prompt
        (buffer-substring-no-properties (point) end)))
     ;; For other terminals
     (t
      (end-of-line)
      (let ((end (point)))
        (beginning-of-line)
        (buffer-substring-no-properties (point) end))))))

(defun claude-code-terminal-start-monitoring (terminal-id original-prefix)
  "Store the original prefix for later prompt checking.
Instead of continuous monitoring, we now check on keystrokes (Enter, C-c, C-d)."
  (when claude-code-terminal-debug-mode
    (message "[DEBUG] Storing original prefix for terminal %s: %s"
             terminal-id original-prefix))
  ;; Store the original prefix for later comparison (no continuous timer)
  (puthash terminal-id original-prefix claude-code-terminal-pending-check))

(defun claude-code-terminal-schedule-prompt-check ()
  "Schedule an async prompt check after 1 second.
Called after Enter, C-c, or C-d keystrokes."
  (when (and (bound-and-true-p claude-code-terminal-id)
             (derived-mode-p 'eshell-mode))
    (let ((terminal-id claude-code-terminal-id))
      (when claude-code-terminal-debug-mode
        (message "[DEBUG] Scheduling prompt check for terminal %s in 1 second" terminal-id))
      ;; Cancel any existing scheduled check
      (let ((existing-timer (gethash terminal-id claude-code-terminal-prompt-check-timers)))
        (when (timerp existing-timer)
          (cancel-timer existing-timer)))
      ;; Schedule new check after 1 second
      (let ((timer (run-at-time 1.0 nil 'claude-code-terminal-do-prompt-check terminal-id)))
        (puthash terminal-id timer claude-code-terminal-prompt-check-timers)))))

(defvar claude-code-terminal-prompt-check-timers (make-hash-table :test 'equal)
  "Hash table storing scheduled prompt check timers per terminal.")

(defun claude-code-terminal-do-prompt-check (terminal-id)
  "Perform the actual prompt check for TERMINAL-ID."
  (let* ((terminal-buffer (claude-code-terminal-get-by-id terminal-id))
         (original-prefix (gethash terminal-id claude-code-terminal-pending-check)))

    (unless terminal-buffer
      (when claude-code-terminal-debug-mode
        (message "[DEBUG] Terminal %s buffer no longer exists" terminal-id))
      (remhash terminal-id claude-code-terminal-prompt-check-timers)
      (cl-return-from claude-code-terminal-do-prompt-check nil))

    (with-current-buffer terminal-buffer
      (let* ((current-line (claude-code-terminal-get-current-line))
             (current-prefix (claude-code-terminal-extract-prompt-prefix current-line))
             (stack (gethash terminal-id claude-code-terminal-shell-stack)))

        (when claude-code-terminal-debug-mode
          (message "[DEBUG] Prompt check for terminal %s:" terminal-id)
          (message "[DEBUG]   Current line: %s" current-line)
          (message "[DEBUG]   Current prefix: %s" current-prefix)
          (message "[DEBUG]   Original prefix: %s" original-prefix)
          (message "[DEBUG]   Stack: %s" stack))

        ;; Check if we've returned to any known prefix in our stack
        (when (and current-prefix stack)
          (let ((found-context nil)
                (index 0))

            ;; Check stack contexts
            (dolist (context stack)
              (let ((context-prefix (cadr context)))
                (when (and context-prefix
                           (string= current-prefix context-prefix)
                           (not found-context))
                  (setq found-context index)))
              (setq index (1+ index)))

            ;; Also check original prefix
            (when (and (not found-context) original-prefix (string= current-prefix original-prefix))
              (setq found-context 'original))

            (when found-context
              (when claude-code-terminal-debug-mode
                (message "[DEBUG] Detected return to context: %s" found-context))

              (cond
               ;; Returned to original shell - clear everything
               ((eq found-context 'original)
                (remhash terminal-id claude-code-terminal-shell-stack)
                (remhash terminal-id claude-code-terminal-embedded-shells)
                (remhash terminal-id claude-code-terminal-pending-check)
                (when claude-code-terminal-debug-mode
                  (message "[DEBUG] Cleared all embedded contexts")))

               ;; Returned to a previous context in stack - pop to that level
               ((numberp found-context)
                (let* ((new-stack (nthcdr (1+ found-context) stack))
                       (current-command (if new-stack (caar new-stack) nil)))
                  (if new-stack
                      (progn
                        (puthash terminal-id new-stack claude-code-terminal-shell-stack)
                        (puthash terminal-id current-command claude-code-terminal-embedded-shells)
                        (when claude-code-terminal-debug-mode
                          (message "[DEBUG] Popped to previous context: %s" current-command)))
                    ;; Stack is empty, clear everything
                    (remhash terminal-id claude-code-terminal-shell-stack)
                    (remhash terminal-id claude-code-terminal-embedded-shells)
                    (remhash terminal-id claude-code-terminal-pending-check)
                    (when claude-code-terminal-debug-mode
                      (message "[DEBUG] Cleared all embedded contexts"))))))

              ;; Update display
              (force-mode-line-update))))))))


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
            (force-mode-line-update)))))))

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
             (derived-mode-p 'eshell-mode))
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
        (message "[DEBUG]   Should monitor: %s" (claude-code-terminal-should-monitor-command-p command)))
      
      ;; Store command info for later comparison
      (puthash terminal-id (list current-line current-prefix command) claude-code-terminal-last-command-line)
      
      ;; If command should be monitored, cancel existing timer and start new monitoring
      (when (claude-code-terminal-should-monitor-command-p command)
        ;; Cancel existing timer only when starting new monitoring
        (when existing-timer
          (cancel-timer existing-timer)
          (when claude-code-terminal-debug-mode
            (message "[DEBUG]   Cancelled existing timer for new monitored command")))
        
        (when claude-code-terminal-debug-mode
          (message "[DEBUG] Command should be monitored - setting header immediately"))
        
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
          (claude-code-terminal-start-monitoring terminal-id clean-prefix)))
      
      ;; Even if no new monitored command was started, check if we've returned to a known prompt
      ;; This handles cases like C-d exit where monitoring might have been canceled
      (unless (claude-code-terminal-should-monitor-command-p command)
        (let ((stack (gethash terminal-id claude-code-terminal-shell-stack)))
          (when (and stack current-prefix)
            ;; Check if current prompt matches any context in the stack
            (let ((found-context nil)
                  (index 0))
              (dolist (context stack)
                (let ((context-prefix (cadr context)))
                  (when (and context-prefix 
                             (string= current-prefix context-prefix)
                             (not found-context))
                    (setq found-context index)))
                (setq index (1+ index)))
              
              (when found-context
                (when claude-code-terminal-debug-mode
                  (message "[DEBUG] Detected return to known context at index %s: %s" found-context current-prefix))
                
                ;; Pop the stack to the found context level
                (let ((new-stack (nthcdr (1+ found-context) stack)))
                  (if new-stack
                      (progn
                        (puthash terminal-id new-stack claude-code-terminal-shell-stack)
                        (puthash terminal-id (caar new-stack) claude-code-terminal-embedded-shells)
                        (when claude-code-terminal-debug-mode
                          (message "[DEBUG] Popped stack to context: %s" (caar new-stack))))
                    ;; Stack is empty, clear everything
                    (remhash terminal-id claude-code-terminal-shell-stack)
                    (remhash terminal-id claude-code-terminal-embedded-shells)
                    (when claude-code-terminal-debug-mode
                      (message "[DEBUG] Cleared all contexts - returned to base shell"))))
                
                ;; Force display update
                (force-mode-line-update)))))))))

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

;; Auto-cleanup sentinel for eshell process exit
(defun claude-code-terminal--eshell-exit-sentinel (process event)
  "Kill buffer when eshell process exits cleanly (via C-d or exit)."
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
              ;; Only unregister if this is a real terminal (not mistty embedded)
              (unless (bound-and-true-p claude-code-terminal-embedded-command)
                (claude-code-terminal-unregister
                 (bound-and-true-p claude-code-terminal-project-root)
                 (buffer-name)))
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
                                                    "never"))
                                         (shell-stack (gethash id claude-code-terminal-shell-stack))
                                         (stack-info 
                                          (cond
                                           ;; No embedded shells
                                           ((not shell-stack) "")
                                           ;; Single embedded shell
                                           ((= (length shell-stack) 1)
                                            (format " → %s" (caar shell-stack)))
                                           ;; Multiple embedded shells - show first and last
                                           (t
                                            (let ((first-command (car (car (last shell-stack))))  ; First item (deepest in stack)
                                                  (last-command (caar shell-stack)))              ; Last item (top of stack)
                                              (format " → %s :: %s" first-command last-command))))))
                                    (cons (format "%s [%s] (%s)%s" 
                                                 (plist-get term :buffer-name)
                                                 (plist-get term :terminal-id)
                                                 time-str
                                                 stack-info)
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

;;; Prompt and Input Styling

(defvar claude-code-terminal-prompt-font "Perfect DOS VGA 437 Win"
  "Font family for eshell prompt and command input.")

(defface claude-code-terminal-prompt-face
  '((t :family "Perfect DOS VGA 437 Win" :height 0.65 :foreground "#00ff00"))
  "Face for eshell prompt with retro hacker font.")

(defface claude-code-terminal-input-face
  '((t :family "Perfect DOS VGA 437 Win" :height 0.65))
  "Face for eshell command input with retro hacker font.")

;;; Doom-modeline Integration for Colorful Mode Line

(defface claude-code-terminal-id-face
  '((t :background "#4a90e2" :foreground "#ffffff" :weight bold))
  "Face for terminal ID in mode line.")

(defface claude-code-terminal-first-command-face
  '((t :background "#f39c12" :foreground "#000000" :weight bold))
  "Face for first command in nested shell stack.")

(defface claude-code-terminal-current-command-face
  '((t :background "#cf8f2b" :foreground "#000000" :weight bold))
  "Face for current/last command in shell stack.")

(declare-function doom-modeline-def-segment "doom-modeline" (name &rest plist))

(defface claude-code-terminal-cwd-face
  '((t :background "#3b4252" :foreground "#88c0d0" :weight normal))
  "Face for current working directory in mode line.")

(defun claude-code-terminal-doom-modeline-terminal-id ()
  "Generate terminal ID + current directory segment for doom-modeline."
  (when (bound-and-true-p claude-code-terminal-id)
    (let ((cwd (abbreviate-file-name default-directory)))
      (concat
       (propertize (format " %s " claude-code-terminal-id)
                   'face 'claude-code-terminal-id-face)
       (propertize (format " %s " cwd)
                   'face 'claude-code-terminal-cwd-face)))))

(defun claude-code-terminal-doom-modeline-commands ()
  "Generate shell commands segment for doom-modeline."
  (when (bound-and-true-p claude-code-terminal-id)
    (let ((shell-stack (gethash claude-code-terminal-id claude-code-terminal-shell-stack))
          (embedded-cmd (bound-and-true-p claude-code-terminal-embedded-command)))
      (cond
       ;; Mistty embedded mode - show the embedding command
       (embedded-cmd
        (propertize (format " ⚡%s " embedded-cmd)
                    'face 'claude-code-terminal-first-command-face))
       ;; No embedded shells
       ((not shell-stack) nil)
       ;; Single embedded shell - use first-command-face to keep consistency
       ((= (length shell-stack) 1)
        (propertize (format " %s " (caar shell-stack))
                    'face 'claude-code-terminal-first-command-face))
       ;; Multiple embedded shells - show first and last
       (t
        (let ((first-command (car (car (last shell-stack))))  ; First item (deepest in stack)
              (last-command (caar shell-stack)))              ; Last item (top of stack)
          (concat
           (propertize (format " %s " first-command)
                       'face 'claude-code-terminal-first-command-face)
           (propertize (format " %s " last-command)
                       'face 'claude-code-terminal-current-command-face))))))))

(defun claude-code-terminal-doom-modeline-evil-state ()
  "Generate large evil state indicator that stretches across the modeline."
  (when (and (bound-and-true-p claude-code-terminal-id)
             (bound-and-true-p evil-mode))
    (if (eq evil-state 'normal)
        ;; Normal mode - show grey background that fills all remaining space
        (let ((padding-length (max 10 (window-width))))  ; Use full window width, let doom-modeline handle overflow
          (propertize (make-string padding-length ?\s)
                      'face '(:background "#666666")))
      ;; Other modes - transparent (no visual indicator)
      nil)))

;; Setup doom-modeline integration when the package is available
(with-eval-after-load 'doom-modeline
  (doom-modeline-def-segment claude-code-terminal-id
    "Display terminal ID with colored background."
    (claude-code-terminal-doom-modeline-terminal-id))
  
  (doom-modeline-def-segment claude-code-terminal-commands  
    "Display shell command stack with colored backgrounds."
    (claude-code-terminal-doom-modeline-commands))
  
  (doom-modeline-def-segment claude-code-terminal-evil-state
    "Display large evil state indicator for terminals."
    (claude-code-terminal-doom-modeline-evil-state))
  
  ;; Add our segments to the default modeline with evil state indicator (no right side segments)
  (doom-modeline-def-modeline 'claude-terminal
    '(bar workspace-name window-number matches claude-code-terminal-id claude-code-terminal-commands claude-code-terminal-evil-state)
    '())
  
  ;; Use our custom modeline in terminal buffers
  (add-hook 'claude-code-terminal-mode-hook
            (lambda ()
              (doom-modeline-set-modeline 'claude-terminal))))
  

;;; Mode Definition

(defun claude-code-terminal-send-C-c ()
  "Send C-c to the terminal process."
  (interactive)
  (when-let ((proc (get-buffer-process (current-buffer))))
    (process-send-string proc "\C-c")))

(defvar claude-code-terminal-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'claude-code-terminal-send-C-c)
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
    ;; Directory-aware find-file keybindings
    (define-key map (kbd "s-f") #'claude-code-terminal-find-file-with-terminal-directory)
    (define-key map (kbd "C-x C-f") #'claude-code-terminal-find-file-with-terminal-directory)
    map)
  "Keymap for Claude Code terminal mode.")


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
        ;; Setup eshell hooks for command stack monitoring
        (when (derived-mode-p 'eshell-mode)
          (add-hook 'eshell-pre-command-hook #'claude-code-terminal-eshell-pre-command nil t)
          (add-hook 'eshell-post-command-hook #'claude-code-terminal-eshell-post-command nil t))

        ;; Setup auto-cleanup when eshell process exits
        (when (and (derived-mode-p 'eshell-mode)
                   (get-buffer-process (current-buffer)))
          (set-process-sentinel (get-buffer-process (current-buffer))
                               #'claude-code-terminal--eshell-exit-sentinel))

        ;; Ensure mode-line is visible (don't override, let telephone-line handle it)
        (unless mode-line-format
          (setq-local mode-line-format (default-value 'mode-line-format)))
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
(add-hook 'eshell-mode-hook
          (lambda ()
            (when (bound-and-true-p claude-code-terminal-id)
              (claude-code-terminal-mode 1)
              (claude-code-terminal-apply-large-font)
              ;; Set up eshell command hooks for this buffer
              (claude-code-terminal-setup-eshell-hooks))))

;; Initialize directory tracking hooks
(claude-code-terminal-setup-directory-hooks)

;;; Eshell Command Stack Monitoring

(defvar-local claude-code-terminal-eshell-last-input nil
  "The last command input in this eshell buffer.")

(defun claude-code-terminal-setup-eshell-hooks ()
  "Set up eshell hooks for command stack monitoring in current buffer.
Call interactively in an eshell buffer to enable command stack monitoring."
  (interactive)
  (if (not (derived-mode-p 'eshell-mode))
      (message "Not in an eshell buffer!")
    (add-hook 'eshell-pre-command-hook #'claude-code-terminal-eshell-pre-command nil t)
    (add-hook 'eshell-post-command-hook #'claude-code-terminal-eshell-post-command nil t)
    (message "Eshell hooks set up! pre-command-hook now: %s" eshell-pre-command-hook)))

(defun claude-code-terminal-setup-all-hooks ()
  "Set up eshell hooks on ALL existing claude terminal buffers.
Run this after reloading the module to enable command monitoring on existing terminals."
  (interactive)
  (let ((count 0))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'eshell-mode)
                   (bound-and-true-p claude-code-terminal-id))
          (add-hook 'eshell-pre-command-hook #'claude-code-terminal-eshell-pre-command nil t)
          (add-hook 'eshell-post-command-hook #'claude-code-terminal-eshell-post-command nil t)
          (setq count (1+ count))
          (message "Set up hooks for: %s" claude-code-terminal-id))))
    (message "Eshell hooks set up on %d terminal(s)" count)))

(defun claude-code-terminal-eshell-pre-command ()
  "Called before eshell executes a command.
Detects monitored commands and starts tracking them."
  ;; Always log that hook fired (temporary debug)
  (message "[HOOK] eshell-pre-command fired! terminal-id=%s"
           (bound-and-true-p claude-code-terminal-id))
  (when (bound-and-true-p claude-code-terminal-id)
    (let* ((terminal-id claude-code-terminal-id)
           (input (and (boundp 'eshell-last-input-start)
                      (boundp 'eshell-last-input-end)
                      eshell-last-input-start
                      eshell-last-input-end
                      (buffer-substring-no-properties eshell-last-input-start
                                                      eshell-last-input-end)))
           (command (when input
                     (car (split-string (string-trim input))))))

      ;; Store the input for post-command processing
      (setq claude-code-terminal-eshell-last-input input)

      ;; Always show what we detected
      (message "[HOOK] input=%s, command=%s, monitored=%s"
               input command (claude-code-terminal-should-monitor-command-p command))

      ;; If this is a monitored command, push to stack
      (when (and command (claude-code-terminal-should-monitor-command-p command))
        (let ((stack (gethash terminal-id claude-code-terminal-shell-stack '()))
              (eshell-prompt (claude-code-terminal-get-eshell-prompt)))
          (when claude-code-terminal-debug-mode
            (message "[DEBUG] Monitored command detected: %s" input)
            (message "[DEBUG] Current eshell prompt: %s" eshell-prompt))

          ;; Push command to stack with eshell prompt
          (push (list (string-trim input) eshell-prompt) stack)
          (puthash terminal-id stack claude-code-terminal-shell-stack)
          (puthash terminal-id (string-trim input) claude-code-terminal-embedded-shells)
          (force-mode-line-update)

          ;; Schedule subprocess tracking after command starts
          (run-at-time 0.1 nil #'claude-code-terminal-track-subprocess terminal-id))))))

(defun claude-code-terminal-eshell-post-command ()
  "Called after eshell finishes a command.
For monitored commands (ssh, docker), we DON'T pop immediately.
The process sentinel will handle that when the subprocess actually exits."
  (when (bound-and-true-p claude-code-terminal-id)
    (let* ((terminal-id claude-code-terminal-id)
           (stack (gethash terminal-id claude-code-terminal-shell-stack))
           (last-command claude-code-terminal-eshell-last-input)
           (last-cmd-name (when last-command
                           (car (split-string (string-trim last-command))))))

      (message "[HOOK] eshell-post-command: stack=%d, last-cmd=%s"
               (length stack) last-cmd-name)

      ;; DON'T pop if the last command was a monitored one -
      ;; those are handled by process sentinel when they actually exit
      (when (and stack
                 (not (claude-code-terminal-should-monitor-command-p last-cmd-name)))
        ;; Only pop for non-monitored commands that somehow got on stack
        (message "[HOOK] Non-monitored command, checking process...")
        (unless (get-buffer-process (current-buffer))
          (message "[HOOK] No process, popping context")
          (claude-code-terminal-pop-embedded-context terminal-id))))))

(defun claude-code-terminal-get-eshell-prompt ()
  "Get the current eshell prompt string."
  (when (derived-mode-p 'eshell-mode)
    (save-excursion
      (goto-char eshell-last-output-end)
      (buffer-substring-no-properties (line-beginning-position) (point)))))

(defun claude-code-terminal-track-subprocess (terminal-id)
  "Track the subprocess created by a monitored command in TERMINAL-ID."
  (message "[TRACK] track-subprocess called for %s" terminal-id)
  (if-let ((buffer (claude-code-terminal-get-by-id terminal-id)))
      (with-current-buffer buffer
        (let ((proc (get-buffer-process buffer)))
          (message "[TRACK] buffer=%s, proc=%s" buffer proc)
          (if proc
              (progn
                (message "[TRACK] Adding sentinel to process: %s (status: %s)"
                         proc (process-status proc))
                ;; Add sentinel to detect when subprocess exits
                (let ((original-sentinel (process-sentinel proc)))
                  (set-process-sentinel
                   proc
                   (lambda (process event)
                     (message "[SENTINEL] Process event: %s, status: %s"
                              event (process-status process))
                     ;; Call original sentinel if it exists (wrap in ignore-errors)
                     (when original-sentinel
                       (ignore-errors
                         (funcall original-sentinel process event)))
                     ;; When process finishes, pop embedded context
                     (when (memq (process-status process) '(exit signal))
                       (message "[SENTINEL] Subprocess exited, popping context")
                       (run-at-time 0.1 nil
                                    #'claude-code-terminal-pop-embedded-context
                                    terminal-id))))))
            (message "[TRACK] No process found! Stack will NOT be tracked."))))
    (message "[TRACK] Buffer not found for %s" terminal-id)))

(defun claude-code-terminal-pop-embedded-context (terminal-id)
  "Pop the top embedded context from the stack for TERMINAL-ID."
  (message "[POP] pop-embedded-context called for %s (from: %s)"
           terminal-id (backtrace-frame 4))
  (let ((stack (gethash terminal-id claude-code-terminal-shell-stack)))
    (message "[POP] current stack: %s" stack)
    (when stack
      (let ((new-stack (cdr stack)))
        (if new-stack
            (progn
              (puthash terminal-id new-stack claude-code-terminal-shell-stack)
              (puthash terminal-id (caar new-stack) claude-code-terminal-embedded-shells)
              (message "[POP] Popped to: %s" (caar new-stack)))
          ;; Stack is now empty
          (remhash terminal-id claude-code-terminal-shell-stack)
          (remhash terminal-id claude-code-terminal-embedded-shells)
          (message "[POP] Stack empty, back to base shell"))
        (force-mode-line-update)))))

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
  (add-hook 'evil-emacs-state-entry-hook 'claude-code-terminal-update-header-line)

  ;; In eshell normal mode, 'i' goes to bottom and enters insert
  (defun claude-code-terminal-eshell-insert ()
    "Go to end of buffer and enter insert mode in eshell."
    (interactive)
    (goto-char (point-max))
    (evil-insert-state))

  (evil-define-key 'normal eshell-mode-map (kbd "i") #'claude-code-terminal-eshell-insert))

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

;; Forward declaration for MCP capture function
(declare-function claude-code-mcp-capture-and-send "claude-code-mcp-tools" ())
(declare-function claude-code-mcp-has-pending-capture-p "claude-code-mcp-tools" ())

;; Mistty smart Enter - captures MCP output or sends normal enter
(defun claude-code-terminal-mistty-smart-enter ()
  "Send Enter to mistty, or capture MCP output if pending.
When an MCP command is waiting for output capture, this captures and sends the result.
Otherwise, sends a normal Enter to mistty."
  (interactive)
  (if (and (fboundp 'claude-code-mcp-has-pending-capture-p)
           (claude-code-mcp-has-pending-capture-p))
      ;; Capture pending MCP output
      (claude-code-mcp-capture-and-send)
    ;; Normal Enter - send to mistty
    (when (fboundp 'mistty-send-command)
      (mistty-send-command))))

;; Smart Enter function that captures MCP output if pending
(defun claude-code-terminal-smart-enter ()
  "Send Enter to terminal, or capture MCP output if pending.
When an MCP command is waiting for output capture, this captures and sends the result.
Handles simple expansions from `my-eshell-simple-expansions'.
For embedded commands (ssh, etc.), spawns mistty in a bottom split.
Otherwise, sends a normal Enter to the terminal."
  (interactive)
  (if (and (fboundp 'claude-code-mcp-has-pending-capture-p)
           (claude-code-mcp-has-pending-capture-p))
      ;; Capture pending MCP output
      (claude-code-mcp-capture-and-send)
    ;; Normal Enter - check for expansions and embedded commands
    (when (derived-mode-p 'eshell-mode)
      (let* ((input (string-trim (buffer-substring-no-properties eshell-last-output-end (point))))
             (simple-entry (and (boundp 'my-eshell-simple-expansions)
                                (assoc input my-eshell-simple-expansions)))
             (is-embedded nil))
        ;; Handle simple expansions first
        (when simple-entry
          (let* ((data (cdr simple-entry))
                 (is-plist (and (listp data) (plist-get data :cmd)))
                 (replacement (if is-plist
                                  (funcall (plist-get data :cmd))
                                (if (functionp data) (funcall data) data)))
                 (eat (and is-plist (plist-get data :eat))))
            (when eat
              (setq is-embedded t))
            (delete-region eshell-last-output-end (point))
            (insert replacement)
            ;; Re-read input after expansion
            (setq input (string-trim (buffer-substring-no-properties eshell-last-output-end (point))))))

        ;; Check if command needs embedded mode
        (when (and (not (string-empty-p input))
                   (claude-code-terminal--is-embedded-command-p input))
          (setq is-embedded t))

        (if (and is-embedded (not (string-empty-p input)))
            ;; Embedded command - spawn mistty instead
            (progn
              (message "[EMBEDDED] Spawning mistty for: %s" (car (split-string input)))
              ;; Clear input line and add note
              (delete-region eshell-last-output-end (point))
              (insert (format "# Spawning in mistty: %s" input))
              (eshell-send-input)
              ;; Spawn mistty with the command
              (claude-code-terminal-spawn-mistty input))
          ;; Regular command - run in eshell
          (claude-code-terminal--set-state :embedded-mode nil)
          ;; Insert newline before execution to create unstyled gap before output
          (when (not (string-empty-p input))
            (goto-char (point-max))
            (insert "\n"))
          (eshell-send-input))))))

(defun claude-code-terminal-send-interrupt ()
  "Send C-c (interrupt) to eshell."
  (interactive)
  (when (derived-mode-p 'eshell-mode)
    (eshell-interrupt-process)))

(defun claude-code-terminal-send-eof ()
  "Send C-d (EOF) to eshell."
  (interactive)
  (when (derived-mode-p 'eshell-mode)
    (eshell-send-eof-to-process)))

;; Configure eshell terminal key bindings
(with-eval-after-load 'eshell
  ;; Eshell keybindings - works like normal Emacs editing
  (define-key eshell-mode-map (kbd "C-c c") 'claude-code-terminal-create)
  (define-key eshell-mode-map (kbd "C-c n") 'claude-code-terminal-create-numbered)
  (define-key eshell-mode-map (kbd "C-c i") 'claude-code-send-emacs-terminal)
  (define-key eshell-mode-map (kbd "C-c h") 'claude-code-send-emacs-terminal-popup)
  (define-key eshell-mode-map (kbd "C-c 1") 'claude-code-send-1)
  (define-key eshell-mode-map (kbd "C-c k") 'my-layout-smart-claude-code)
  (define-key eshell-mode-map (kbd "C-l") 'windmove-right)
  (define-key eshell-mode-map (kbd "C-u") 'claude-code-terminal-switch)
  ;; Enter key - smart capture or normal
  (define-key eshell-mode-map (kbd "<return>") 'claude-code-terminal-smart-enter)
  ;; C-c C-c for interrupt with prompt check
  (define-key eshell-mode-map (kbd "C-c C-c") 'claude-code-terminal-send-interrupt)
  ;; C-d for EOF with prompt check
  (define-key eshell-mode-map (kbd "C-d") 'claude-code-terminal-send-eof)
  ;; Directory-aware find-file keybindings
  (define-key eshell-mode-map (kbd "s-f") 'claude-code-terminal-find-file-with-terminal-directory)
  (define-key eshell-mode-map (kbd "C-x C-f") 'claude-code-terminal-find-file-with-terminal-directory)
  ;; Super key alternatives for consistency
  (define-key eshell-mode-map (kbd "s-c") 'claude-code-terminal-create)
  (define-key eshell-mode-map (kbd "s-n") 'claude-code-terminal-create-numbered)
  (define-key eshell-mode-map (kbd "s-i") 'claude-code-send-emacs-terminal)
  (define-key eshell-mode-map (kbd "s-h") 'claude-code-send-emacs-terminal-popup)
  (define-key eshell-mode-map (kbd "s-1") 'claude-code-send-1)
  (define-key eshell-mode-map (kbd "s-k") 'my-layout-smart-claude-code)
  (define-key eshell-mode-map (kbd "s-u") 'claude-code-terminal-switch)

  (message "[DEBUG] Configured eshell terminal keybindings"))

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

;; Auto-setup eshell hooks on all existing terminals when module loads
(run-with-idle-timer 1 nil #'claude-code-terminal-setup-all-hooks)

;;; Output styling with per-terminal embedded mode tracking
;;;
;;; Two modes:
;;; - Embedded mode (ssh, kubectl exec -it, etc.): font size only, terminal via eat
;;; - Regular mode (ls, ifconfig, etc.): font size + background + padding

;; Per-terminal state using hash table (keyed by terminal-id)
(defvar claude-code-terminal-output-state (make-hash-table :test 'equal)
  "Hash table tracking output styling state for each terminal.
Keys are terminal IDs, values are plists with:
  :in-command - non-nil when command is executing
  :first-output - non-nil before first output chunk
  :output-start-pos - position where output started
  :embedded-mode - non-nil for interactive commands (ssh, etc.)")

;; Face specs for different modes
(defvar claude-code-terminal-output-face-regular
  '(:height 0.85 :inherit nil :background "#372413" :extend t)
  "Face for regular command output (with background).")

(defvar claude-code-terminal-output-face-embedded
  '(:height 0.85 :inherit nil)
  "Face for embedded mode output (font size only, no background).")

(defun claude-code-terminal--get-id ()
  "Get current terminal ID or buffer name as fallback."
  (or (and (boundp 'claude-code-terminal-id) claude-code-terminal-id)
      (buffer-name)))

(defun claude-code-terminal--get-state (key)
  "Get state KEY for current terminal."
  (let* ((terminal-id (claude-code-terminal--get-id))
         (state (gethash terminal-id claude-code-terminal-output-state)))
    (plist-get state key)))

(defun claude-code-terminal--set-state (key value)
  "Set state KEY to VALUE for current terminal."
  (let* ((terminal-id (claude-code-terminal--get-id))
         (state (gethash terminal-id claude-code-terminal-output-state)))
    (setq state (plist-put state key value))
    (puthash terminal-id state claude-code-terminal-output-state)))

(defun claude-code-terminal--is-embedded-command-p (input)
  "Check if INPUT is an embedded/interactive command."
  (let ((input-trimmed (string-trim input)))
    (or
     ;; ssh
     (string-prefix-p "ssh " input-trimmed)
     (string= "ssh" input-trimmed)
     ;; kubectl exec with -it flag
     (and (string-prefix-p "kubectl " input-trimmed)
          (string-match-p "\\bexec\\b.*-[ti]" input-trimmed))
     ;; docker exec with -it flag
     (and (string-prefix-p "docker " input-trimmed)
          (string-match-p "\\bexec\\b.*-[ti]" input-trimmed)))))

(defun claude-code-terminal-mark-command-start ()
  "Mark that we're executing a command and determine mode."
  (claude-code-terminal--set-state :in-command t)
  (claude-code-terminal--set-state :first-output t)
  (claude-code-terminal--set-state :output-start-pos nil)
  ;; Don't reset embedded-mode here - it's set in smart-enter before this hook
  )

(defun claude-code-terminal-mark-command-end ()
  "Mark that command finished and add bottom padding for regular mode."
  (let ((output-start-pos (claude-code-terminal--get-state :output-start-pos))
        (embedded-mode (claude-code-terminal--get-state :embedded-mode)))
    (if embedded-mode
        ;; Clean up embedded overlay
        (claude-code-terminal-cleanup-embedded-overlay)
      ;; Only add bottom padding for regular mode
      (when output-start-pos
        (let ((end (marker-position eshell-last-output-start)))
          (when (and end (> end output-start-pos))
            (let ((ov (make-overlay (1- end) end nil nil nil)))
              (overlay-put ov 'after-string
                           (concat (propertize "\n" 'face claude-code-terminal-output-face-regular)
                                   "\n"))
              (overlay-put ov 'claude-code-terminal-output t)))))))
  (claude-code-terminal--set-state :in-command nil)
  (claude-code-terminal--set-state :embedded-mode nil))

(defun claude-code-terminal-fontify-output ()
  "Apply styling to command output based on mode."
  (let ((in-command (claude-code-terminal--get-state :in-command))
        (embedded-mode (claude-code-terminal--get-state :embedded-mode)))
    (when in-command
      (let ((start (marker-position eshell-last-output-start))
            (end (marker-position eshell-last-output-end)))
        (when (and start end (< start end))
          (let ((text (buffer-substring-no-properties start end)))
            ;; Skip if this looks like a prompt (traditional or emoji)
            (unless (or (string-match-p "[$#] $" text)
                        (string-match-p (concat "^" (regexp-quote claude-code-terminal-prompt-emoji) " $") text))
              (if embedded-mode
                  ;; Embedded mode: font size only
                  (let* ((face claude-code-terminal-output-face-embedded)
                         (padding (propertize "  " 'face face))
                         (ov (make-overlay start end nil nil nil)))
                    (overlay-put ov 'face face)
                    (overlay-put ov 'line-prefix padding)
                    (overlay-put ov 'wrap-prefix padding)
                    (overlay-put ov 'claude-code-terminal-output t)
                    (when (claude-code-terminal--get-state :first-output)
                      (claude-code-terminal--set-state :first-output nil)
                      (claude-code-terminal--set-state :output-start-pos start)))
                ;; Regular mode: font size + background + padding
                (let* ((face claude-code-terminal-output-face-regular)
                       (padding (propertize "  " 'face face))
                       (ov (make-overlay start end nil nil nil)))
                  (overlay-put ov 'face face)
                  (overlay-put ov 'line-prefix padding)
                  (overlay-put ov 'wrap-prefix padding)
                  (overlay-put ov 'evaporate nil)
                  (overlay-put ov 'claude-code-terminal-output t)
                  (when (claude-code-terminal--get-state :first-output)
                    (overlay-put ov 'before-string
                                 (concat "" (propertize "\n" 'face face)))
                    (claude-code-terminal--set-state :first-output nil)
                    (claude-code-terminal--set-state :output-start-pos start)))))))))))

(add-hook 'eshell-pre-command-hook #'claude-code-terminal-clear-input-overlay)
(add-hook 'eshell-pre-command-hook #'claude-code-terminal-mark-command-start)
(add-hook 'eshell-post-command-hook #'claude-code-terminal-mark-command-end -90)
(add-hook 'eshell-output-filter-functions #'claude-code-terminal-fontify-output)

;;; Prompt and Input Font Styling

(defvar-local claude-code-terminal-input-overlay nil
  "Overlay for styling command input with retro font.")

(defun claude-code-terminal-style-input ()
  "Apply retro font to current input line."
  (when (and (derived-mode-p 'eshell-mode)
             (bound-and-true-p claude-code-terminal-id)
             (not (claude-code-terminal--get-state :in-command)))
    (let ((start eshell-last-output-end)
          (end (point-max)))
      (when (< start end)
        ;; Remove old overlay if exists
        (when (and claude-code-terminal-input-overlay
                   (overlay-buffer claude-code-terminal-input-overlay))
          (delete-overlay claude-code-terminal-input-overlay))
        ;; Create new overlay for input
        (setq claude-code-terminal-input-overlay (make-overlay start end nil nil t))
        (overlay-put claude-code-terminal-input-overlay 'face 'claude-code-terminal-input-face)
        (overlay-put claude-code-terminal-input-overlay 'claude-code-terminal-input t)))))

(defun claude-code-terminal-clear-input-overlay ()
  "Finalize input overlay before command execution.
Converts the dynamic input overlay to a fixed overlay covering just the command."
  (when (and claude-code-terminal-input-overlay
             (overlay-buffer claude-code-terminal-input-overlay))
    ;; Make the overlay non-rear-advancing so it won't grow with output
    (let ((start (overlay-start claude-code-terminal-input-overlay))
          (end (overlay-end claude-code-terminal-input-overlay)))
      (delete-overlay claude-code-terminal-input-overlay)
      ;; Create fixed overlay for the command text (non-extending)
      (let ((fixed-ov (make-overlay start end nil nil nil)))
        (overlay-put fixed-ov 'face 'claude-code-terminal-input-face)
        (overlay-put fixed-ov 'claude-code-terminal-command t)))
    (setq claude-code-terminal-input-overlay nil)))

(defvar claude-code-terminal-prompt-emoji "👾"
  "Emoji to use as the eshell prompt.")

(defun claude-code-terminal-eshell-prompt ()
  "Minimal emoji-only eshell prompt."
  (concat claude-code-terminal-prompt-emoji " "))

(defun claude-code-terminal-setup-prompt-font ()
  "Set up retro font and emoji prompt for eshell."
  ;; Set minimal emoji prompt
  (setq-local eshell-prompt-function #'claude-code-terminal-eshell-prompt)
  (setq-local eshell-prompt-regexp (concat "^" (regexp-quote claude-code-terminal-prompt-emoji) " "))
  ;; Style prompt via eshell-prompt-face
  (face-remap-add-relative 'eshell-prompt
                           :family claude-code-terminal-prompt-font
                           :foreground "#00ff00")
  ;; Update input styling on changes
  (add-hook 'post-command-hook #'claude-code-terminal-style-input nil t)
  ;; Refresh prompt to apply new format immediately
  (when (eq major-mode 'eshell-mode)
    (run-at-time 0.1 nil
                 (lambda (buf)
                   (when (buffer-live-p buf)
                     (with-current-buffer buf
                       (let ((inhibit-read-only t))
                         ;; Delete old prompt line
                         (goto-char (point-max))
                         (forward-line 0)
                         (delete-region (point) (point-max))
                         ;; Emit new prompt
                         (eshell-emit-prompt)))))
                 (current-buffer))))

(add-hook 'eshell-mode-hook #'claude-code-terminal-setup-prompt-font)

;;; Eat integration
;;; - Enable eat-eshell-mode globally once and never disable
;;; - Our advice bypasses eat for non-embedded commands
;;; - Embedded mode uses eat's terminal emulation with overlay styling

;; Per-terminal eat overlay and marker tracking
(defvar claude-code-terminal-eat-overlays (make-hash-table :test 'equal)
  "Hash table of eat overlays per terminal.")

(defvar claude-code-terminal-eat-markers (make-hash-table :test 'equal)
  "Hash table of eat start markers per terminal.")

(defun claude-code-terminal-setup-eat ()
  "Enable eat-eshell-mode globally if not already enabled."
  (when (and (fboundp 'eat-eshell-mode)
             (not (bound-and-true-p eat-eshell-mode)))
    (eat-eshell-mode 1)))

;; Enable eat globally when eat.el loads
(with-eval-after-load 'eat
  (claude-code-terminal-setup-eat))

;; Also try on eshell start in case eat loads later
(add-hook 'eshell-mode-hook #'claude-code-terminal-setup-eat)

(defun claude-code-terminal-setup-embedded-overlay ()
  "Set up overlay for embedded mode output styling."
  (let* ((terminal-id (claude-code-terminal--get-id))
         (face claude-code-terminal-output-face-embedded)
         (padding (propertize "  " 'face face))
         (ov (make-overlay (point) (point) nil nil nil)))
    (overlay-put ov 'face face)
    (overlay-put ov 'line-prefix padding)
    (overlay-put ov 'wrap-prefix padding)
    (overlay-put ov 'evaporate nil)
    (overlay-put ov 'claude-code-terminal-embedded t)
    (puthash terminal-id ov claude-code-terminal-eat-overlays)
    (puthash terminal-id (point-marker) claude-code-terminal-eat-markers)
    ;; Add hook to update overlay as output comes
    (add-hook 'eat-eshell-update-hook #'claude-code-terminal-update-embedded-overlay nil t)))

(defun claude-code-terminal-update-embedded-overlay ()
  "Update embedded overlay to cover current output region."
  (let* ((terminal-id (claude-code-terminal--get-id))
         (ov (gethash terminal-id claude-code-terminal-eat-overlays))
         (marker (gethash terminal-id claude-code-terminal-eat-markers)))
    (when (and ov marker)
      (let ((start (marker-position marker))
            (end (point-max)))
        (move-overlay ov start end)))))

(defun claude-code-terminal-cleanup-embedded-overlay ()
  "Clean up embedded overlay after command finishes."
  (let* ((terminal-id (claude-code-terminal--get-id))
         (ov (gethash terminal-id claude-code-terminal-eat-overlays))
         (marker (gethash terminal-id claude-code-terminal-eat-markers)))
    (when ov
      ;; Set final bounds
      (when marker
        (move-overlay ov (marker-position marker) (point)))
      ;; Clear tracking
      (remhash terminal-id claude-code-terminal-eat-overlays)
      (remhash terminal-id claude-code-terminal-eat-markers))
    ;; Remove hook
    (remove-hook 'eat-eshell-update-hook #'claude-code-terminal-update-embedded-overlay t)))

;; Advice to bypass eat's process setup for non-embedded commands
(defun claude-code-terminal-eat-advice (orig-fn fn command args)
  "Let eat handle embedded commands, bypass for regular commands."
  (let ((embedded-mode (claude-code-terminal--get-state :embedded-mode)))
    (if embedded-mode
        (progn
          ;; Set up overlay for embedded mode styling
          (claude-code-terminal-setup-embedded-overlay)
          ;; Let eat handle terminal emulation
          (funcall orig-fn fn command args))
      ;; Regular mode - bypass eat, use normal eshell output
      (funcall fn command args))))

(with-eval-after-load 'eat
  (advice-add #'eat--eshell-adjust-make-process-args :around
              #'claude-code-terminal-eat-advice))

;;; Mistty integration for embedded commands
;;;
;;; Instead of running embedded commands (ssh, kubectl exec -it, etc.) in
;;; eshell with eat-eshell-mode, we spawn a mistty buffer in a bottom split.
;;; This provides better terminal emulation for interactive sessions.

(defun claude-code-terminal-get-mistty-buffer (&optional terminal-id)
  "Get active mistty buffer for TERMINAL-ID (defaults to current terminal)."
  (let ((id (or terminal-id (claude-code-terminal--get-id))))
    (when-let ((buf (gethash id claude-code-terminal-mistty-buffers)))
      (when (buffer-live-p buf)
        buf))))

(defun claude-code-terminal-has-active-mistty-p (&optional terminal-id)
  "Check if TERMINAL-ID has an active mistty buffer."
  (not (null (claude-code-terminal-get-mistty-buffer terminal-id))))

(defun claude-code-terminal-spawn-mistty (command)
  "Spawn mistty to replace eshell for embedded COMMAND.
Mistty becomes the main terminal buffer. When it closes, eshell returns."
  (cl-block claude-code-terminal-spawn-mistty
    (unless (require 'mistty nil t)
      (user-error "Mistty is not installed. Install via M-x package-install RET mistty"))

    (let* ((terminal-id (claude-code-terminal--get-id))
           (eshell-buf (current-buffer))
           (eshell-win (selected-window))
           (project-root (bound-and-true-p claude-code-terminal-project-root))
           (kubeconfig (getenv "KUBECONFIG"))
           mistty-buf)

      ;; Store embedded state
      (claude-code-terminal--set-state :embedded-mode t)
      (claude-code-terminal--set-state :mistty-command command)

      ;; Create mistty buffer (this replaces current window content)
      (message "[MISTTY] Creating mistty for terminal %s..." terminal-id)
      (condition-case err
          (setq mistty-buf (mistty-create))
        (error
         (message "[MISTTY] Error creating: %s" err)
         (claude-code-terminal--set-state :embedded-mode nil)
         (cl-return-from claude-code-terminal-spawn-mistty nil)))

      (unless (and mistty-buf (buffer-live-p mistty-buf))
        (message "[MISTTY] Failed to create buffer")
        (claude-code-terminal--set-state :embedded-mode nil)
        (cl-return-from claude-code-terminal-spawn-mistty nil))

      ;; mistty-create already displayed mistty in current window - that's what we want!
      (message "[MISTTY] Mistty now active for %s" terminal-id)

      ;; Store reference for MCP routing
      (puthash terminal-id mistty-buf claude-code-terminal-mistty-buffers)

      ;; Set up mistty buffer with parent reference and terminal features
      (with-current-buffer mistty-buf
        ;; Parent references for cleanup
        (setq-local claude-code-terminal-parent-id terminal-id)
        (setq-local claude-code-terminal-parent-buffer eshell-buf)
        (setq-local claude-code-terminal-parent-window eshell-win)

        ;; Copy terminal identity so keybindings and lookups work
        (setq-local claude-code-terminal-id terminal-id)
        (setq-local claude-code-terminal-project-root project-root)
        (setq-local claude-code-terminal-embedded-command command)

        ;; Enable terminal mode for keybindings (C-u, C-f, etc.)
        (claude-code-terminal-mode 1)

        ;; Explicitly set doom-modeline for this buffer (after variables are set)
        (when (fboundp 'doom-modeline-set-modeline)
          (doom-modeline-set-modeline 'claude-terminal))

        ;; Add mistty-specific keybindings (same as eshell)
        (local-set-key (kbd "C-c c") #'claude-code-terminal-create)
        (local-set-key (kbd "C-c n") #'claude-code-terminal-create-numbered)
        (local-set-key (kbd "C-c i") #'claude-code-send-emacs-terminal)
        (local-set-key (kbd "C-c h") #'claude-code-send-emacs-terminal-popup)
        (local-set-key (kbd "C-c k") #'my-layout-smart-claude-code)
        (local-set-key (kbd "C-u") #'claude-code-terminal-switch)
        (local-set-key (kbd "C-f") #'claude-code-terminal-switch-recent)
        (local-set-key (kbd "s-c") #'claude-code-terminal-create)
        (local-set-key (kbd "s-n") #'claude-code-terminal-create-numbered)
        (local-set-key (kbd "s-h") #'claude-code-send-emacs-terminal-popup)
        (local-set-key (kbd "s-k") #'my-layout-smart-claude-code)
        (local-set-key (kbd "s-u") #'claude-code-terminal-switch)
        ;; Enter key - smart capture for MCP or normal enter
        (local-set-key (kbd "<return>") #'claude-code-terminal-mistty-smart-enter)
        (local-set-key (kbd "RET") #'claude-code-terminal-mistty-smart-enter)

        ;; doom-modeline handles the modeline via claude-code-terminal-mode hook
        ;; Force modeline update to pick up the new terminal ID and embedded command
        (force-mode-line-update)

        ;; Cleanup hook when mistty process ends
        (add-hook 'mistty-after-process-end-hook
                  #'claude-code-terminal-mistty-cleanup nil t))

      ;; Send command after shell starts
      ;; For kubectl commands, prepend KUBECONFIG if set
      (let ((final-cmd (if (and kubeconfig
                                (string-match-p "\\bkubectl\\b" command))
                           (format "KUBECONFIG=%s %s" kubeconfig command)
                         command)))
        (run-at-time 0.3 nil
                     (lambda (buf cmd)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (mistty-send-string cmd)
                           (mistty-send-command))))
                     mistty-buf final-cmd))

      mistty-buf)))

(defun claude-code-terminal-mistty-cleanup (&rest _args)
  "Clean up mistty and restore parent eshell buffer."
  (let* ((parent-id (bound-and-true-p claude-code-terminal-parent-id))
         (parent-buf (bound-and-true-p claude-code-terminal-parent-buffer))
         (parent-win (bound-and-true-p claude-code-terminal-parent-window))
         (mistty-buf (current-buffer)))

    (message "[MISTTY] Cleanup for terminal %s" parent-id)

    (when parent-id
      ;; Clear mistty reference
      (remhash parent-id claude-code-terminal-mistty-buffers)

      ;; Update parent eshell state
      (when (buffer-live-p parent-buf)
        (with-current-buffer parent-buf
          (claude-code-terminal--set-state :embedded-mode nil)
          (claude-code-terminal--set-state :mistty-command nil)))

      ;; Restore eshell in the window and kill mistty
      (run-at-time 0.1 nil
                   (lambda (mbuf pbuf pwin tid)
                     ;; Restore eshell to window
                     (when (and (buffer-live-p pbuf)
                                (window-live-p pwin))
                       (set-window-buffer pwin pbuf)
                       (select-window pwin)
                       (goto-char (point-max))
                       (message "[MISTTY] Restored eshell for terminal %s" tid))
                     ;; Kill mistty buffer
                     (when (buffer-live-p mbuf)
                       (kill-buffer mbuf)))
                   mistty-buf parent-buf parent-win parent-id))))

(defun claude-code-terminal-send-to-mistty (string &optional terminal-id)
  "Send STRING to the active mistty buffer for TERMINAL-ID."
  (when-let ((mistty-buf (claude-code-terminal-get-mistty-buffer terminal-id)))
    (with-current-buffer mistty-buf
      (mistty-send-string string))))

(defun claude-code-terminal-send-command-to-mistty (command &optional terminal-id)
  "Send COMMAND to the active mistty buffer and execute it."
  (when-let ((mistty-buf (claude-code-terminal-get-mistty-buffer terminal-id)))
    (with-current-buffer mistty-buf
      (mistty-send-string command)
      (mistty-send-command))))

(defun claude-code-terminal-close-mistty (&optional terminal-id)
  "Close the mistty buffer associated with TERMINAL-ID."
  (interactive)
  (let ((id (or terminal-id (claude-code-terminal--get-id))))
    (when-let ((mistty-buf (gethash id claude-code-terminal-mistty-buffers)))
      (when (buffer-live-p mistty-buf)
        (with-current-buffer mistty-buf
          ;; Send exit to close gracefully
          (mistty-send-string "exit")
          (mistty-send-command))))))

(defun claude-code-terminal-exit-embedded ()
  "Exit embedded mistty session if active, otherwise do nothing."
  (interactive)
  (if (claude-code-terminal-has-active-mistty-p)
      (claude-code-terminal-close-mistty)
    (message "No active embedded session")))

;;; Return to terminal after kill-buffer (if previous buffer was terminal)

(defun claude-code-terminal--return-after-kill (orig-fun &rest args)
  "Advice to return to terminal buffer after killing current buffer.
Only switches to terminal if the immediate previous buffer was a terminal."
  (let* ((prev-buf (cadr (buffer-list)))  ; Second buffer = previous
         (prev-is-terminal (and prev-buf
                                (buffer-live-p prev-buf)
                                (with-current-buffer prev-buf
                                  (bound-and-true-p claude-code-terminal-id)))))
    (apply orig-fun args)
    ;; If previous buffer was a terminal and we didn't land on it, switch to it
    (when (and prev-is-terminal
               (buffer-live-p prev-buf)
               (not (eq prev-buf (current-buffer))))
      (switch-to-buffer prev-buf))))

(advice-add 'kill-current-buffer :around #'claude-code-terminal--return-after-kill)

(provide 'claude-code-terminal)
;;; claude-code-terminal.el ends here
