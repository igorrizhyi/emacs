;;; claude-code-core.el --- Core functionality for Claude Code Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: DESKTOP2 <yuya373@DESKTOP2>
;; Keywords: tools, convenience
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

;; Core functionality for Claude Code Emacs including:
;; - Buffer management functions
;; - String processing utilities
;; - Session lifecycle management

;;; Code:

(require 'projectile)
(require 'eat)

;; Terminal integration variables
(defvar claude-code-terminal-current-context)

;; Forward declarations for MCP integration
(declare-function claude-code-mcp-disconnect "claude-code-mcp-connection" (project-root))
(declare-function claude-code-eat-mode "claude-code-ui" ())

;;; Customization

(defgroup claude-code nil
  "Run Claude Code within Emacs."
  :group 'tools
  :prefix "claude-code-")


(defcustom claude-code-executable "claude"
  "The executable name or path for Claude Code CLI."
  :type 'string
  :group 'claude-code)

(defconst claude-code-available-options
  '(("--verbose" . "Enable detailed logging")
    ("--model sonnet" . "Use Claude Sonnet model")
    ("--model opus" . "Use Claude Opus model")
    ("--resume" . "Resume specific session by ID")
    ("--continue" . "Load latest conversation in current directory")
    ("--dangerously-skip-permissions" . "Skip permission prompts"))
  "Available options for Claude Code CLI.")

;;; Buffer Management

(defun claude-code-normalize-project-root (project-root)
  "Normalize PROJECT-ROOT by expanding tildes and removing trailing slash.
Return nil if PROJECT-ROOT is nil."
  (when project-root
    (directory-file-name (expand-file-name project-root))))

(defun claude-code-buffer-name ()
  "Return the buffer name for Claude Code session in current project.
Return nil if not in a project."
  (when-let ((project-root (claude-code-normalize-project-root (projectile-project-root))))
    (format "*claude:%s*" project-root)))

(defun claude-code-get-buffer ()
  "Get the Claude Code buffer for the current project, or nil if it doesn't exist."
  (get-buffer (claude-code-buffer-name)))

(defun claude-code-ensure-buffer ()
  "Ensure Claude Code buffer exists, error if not."
  (or (claude-code-get-buffer)
      (error "No Claude Code session for this project.  Use 'claude-code-run' to start one")))

(defun claude-code-with-terminal-buffer (body-fn)
  "Execute BODY-FN in the Claude Code terminal buffer."
  (let ((buf (claude-code-ensure-buffer)))
    (with-current-buffer buf
      (funcall body-fn))))

;; Keep old name for backward compatibility
(defalias 'claude-code-with-vterm-buffer 'claude-code-with-terminal-buffer)

;;; Session Management

;;;###autoload
(defun claude-code-run ()
  "Start Claude Code session for the current project.
With prefix argument, select from available options."
  (interactive)
  ;; Clear any existing terminal context first
  (when (boundp 'claude-code-terminal-current-context)
    (setq claude-code-terminal-current-context nil))
  (let* ((buffer-name (claude-code-buffer-name))
         (project-root (claude-code-normalize-project-root (projectile-project-root)))
         (default-directory project-root)
         (buf (get-buffer buffer-name))
         (selected-option (when current-prefix-arg
                            (let* ((choices (mapcar (lambda (opt)
                                                      (format "%s - %s"
                                                              (car opt)
                                                              (cdr opt)))
                                                    claude-code-available-options))
                                   (selected (completing-read "Select Claude option: " choices nil t)))
                              (when selected
                                (car (split-string selected " - "))))))
         (extra-input (when (and selected-option
                                 (string-match-p "--resume" selected-option))
                        (read-string "Session ID: ")))
         (claude-command (concat claude-code-executable
                                 (when selected-option
                                   (concat " " selected-option))
                                 (when extra-input
                                   (concat " " extra-input)))))
    ;; Create eat terminal if buffer doesn't exist or is not an eat terminal
    (unless (and buf
                 (with-current-buffer buf
                   (derived-mode-p 'eat-mode)))
      (setq buf (eat-make buffer-name "/bin/sh" nil
                          (list "-c" claude-command)))
      (with-current-buffer buf
        (claude-code-eat-mode)))
    (switch-to-buffer-other-window buf)

    ;; Send terminal context if available
    (when (and (boundp 'claude-code-terminal-current-context)
               claude-code-terminal-current-context)
      (claude-code-send-terminal-context claude-code-terminal-current-context))))

(defun claude-code-send-terminal-context (terminal-id)
  "Send terminal context message to Claude Code with TERMINAL-ID."
  (when terminal-id
    ;; Add a delay to let Claude Code initialize properly
    (run-with-timer 2.0 nil
                    (lambda ()
                      (when (get-buffer (claude-code-buffer-name))
                        (let ((context-message
                               (format "I'm working from a terminal buffer with ID '%s'. You can interact with this terminal using the MCP tools: getTerminalContent, executeTerminalCommandInEmacs, getTerminalList, and createTerminal. The terminal ID is '%s' and you can use it to read terminal content or execute commands in this specific terminal session."
                                       terminal-id terminal-id)))
                          (claude-code-send-string context-message)))))))

;;;###autoload
(defun claude-code-switch-to-buffer ()
  "Switch to the Claude Code buffer for the current project."
  (interactive)
  (let ((buffer-name (claude-code-buffer-name)))
    (if (get-buffer buffer-name)
        (switch-to-buffer-other-window buffer-name)
      (message "No Claude Code session for this project. Use 'claude-code-run' to start one."))))

;;;###autoload
(defun claude-code-close ()
  "Close the window displaying the Claude Code buffer for the current project."
  (interactive)
  (let* ((buffer-name (claude-code-buffer-name))
         (buffer (get-buffer buffer-name)))
    (if buffer
        (let ((window (get-buffer-window buffer)))
          (if window
              (delete-window window)
            (message "Claude Code buffer is not displayed in any window")))
      (message "No Claude Code buffer found for this project"))))

;;;###autoload
(defun claude-code-quit ()
  "Quit the Claude Code session for the current project and kill the buffer."
  (interactive)
  (let* ((buffer-name (claude-code-buffer-name))
         (buffer (get-buffer buffer-name)))
    (if buffer
        (progn
          ;; First close any windows showing the buffer
          (dolist (window (get-buffer-window-list buffer nil t))
            (delete-window window))
          ;; Send /quit to Claude and then kill the buffer
          (with-current-buffer buffer
            (when-let ((proc (get-buffer-process buffer)))
              (process-send-string proc "/quit\n"))
            (run-at-time 3 nil
                         (lambda ()
                           (when (buffer-live-p buffer)
                             ;; Kill process if still running
                             (when-let ((proc (get-buffer-process buffer)))
                               (when (process-live-p proc)
                                 (kill-process proc)))
                             ;; Kill the buffer
                             (let ((kill-buffer-query-functions nil))
                               (kill-buffer buffer)))
                           ;; Clear terminal context when session ends
                           (when (boundp 'claude-code-terminal-current-context)
                             (setq claude-code-terminal-current-context nil))
                           (message "Claude Code session ended for this project")))))
      (message "No Claude Code buffer found for this project"))))

;;; String Sending Functions

(defun claude-code-send-string (string &optional _paste-p)
  "Send STRING to the Claude Code session."
  (interactive "sEnter text: ")
  (claude-code-with-terminal-buffer
   (lambda ()
     (when-let ((proc (get-buffer-process (current-buffer))))
       (process-send-string proc string)
       (sit-for 0.05)  ;; Small delay for eat to process
       (process-send-string proc "\n")))))

;;;###autoload
(defun claude-code-send-region ()
  "Send selected region to Claude Code."
  (interactive)
  (if (use-region-p)
      (let ((text (buffer-substring-no-properties (region-beginning) (region-end))))
        (claude-code-send-string text))
    (user-error "No region selected")))

(provide 'claude-code-core)
;;; claude-code-core.el ends here
