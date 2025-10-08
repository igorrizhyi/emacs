;;; test_ai_terminal.el --- Simple test for AI terminal functionality -*- lexical-binding: t; -*-

;; This file contains basic tests to verify the AI terminal functionality
;; without requiring all dependencies.

;;; Code:

;; Mock functions to simulate dependencies
(defvar claude-code--ai-connected-terminal nil)
(defvar claude-code-ai-terminal-timeout 30)
(defvar claude-code-ai-command-confirmation t)
(defvar claude-code-ai-dangerous-commands 
  '("rm -rf" "sudo" "chmod 777" "mkfs" "dd" "fdisk" "parted" "format"))

;; Mock claude-code--buffer-p function
(defun claude-code--buffer-p (buffer)
  "Mock function to test if BUFFER is a Claude buffer."
  (let ((name (if (stringp buffer) buffer (buffer-name buffer))))
    (and name (string-match-p "^\\*claude:" name))))

;; Mock terminal send function
(defun claude-code--term-send-string (backend string)
  "Mock function to send STRING to terminal using BACKEND."
  (message "MOCK: Sending to %s: %s" backend string))

;; Mock terminal backend variable
(defvar claude-code-terminal-backend 'eat)

;; Test the validation function
(defun test-command-validation ()
  "Test the command validation logic."
  (let ((claude-code-ai-command-confirmation nil)) ; Disable interactive prompts
    (message "Testing command validation...")
    
    ;; Test safe command
    (let ((result (claude-code--validate-ai-command "ls -la")))
      (message "Safe command 'ls -la': %s" (if result "PASSED" "FAILED")))
    
    ;; Test dangerous command
    (let ((result (claude-code--validate-ai-command "rm -rf /")))
      (message "Dangerous command 'rm -rf /': %s" (if (not result) "PASSED" "FAILED")))
    
    ;; Test another safe command
    (let ((result (claude-code--validate-ai-command "echo hello")))
      (message "Safe command 'echo hello': %s" (if result "PASSED" "FAILED")))))

;; Test terminal buffer detection
(defun test-terminal-buffer-detection ()
  "Test terminal buffer detection logic."
  (message "Testing terminal buffer detection...")
  
  ;; Test with a mock Claude buffer name
  (let ((result (claude-code--buffer-p "*claude:/home/user*")))
    (message "Claude buffer detection: %s" (if result "PASSED" "FAILED")))
  
  ;; Test with a regular buffer name
  (let ((result (claude-code--buffer-p "*scratch*")))
    (message "Regular buffer detection: %s" (if (not result) "PASSED" "FAILED"))))

;; Test output cleaning function
(defun test-output-cleaning ()
  "Test the terminal output cleaning logic."
  (message "Testing output cleaning...")
  
  (let* ((raw-output "$ echo hello\nworld\nhello\nworld\n$ ")
         (cleaned (claude-code--clean-terminal-output raw-output))
         (expected "world\nhello\nworld"))
    (message "Output cleaning test: %s" 
             (if (string= cleaned expected) "PASSED" "FAILED"))
    (message "Expected: %S" expected)
    (message "Got: %S" cleaned)))

;; Test MCP tool handler response format
(defun test-mcp-response-format ()
  "Test the MCP response format."
  (message "Testing MCP response format...")
  
  ;; Mock successful command result
  (let* ((success-result '(:success t :output "Hello World"))
         (response (if (plist-get success-result :success)
                      `((content . (((type . "text")
                                    (text . ,(format "Command executed successfully:\n%s" 
                                                   (plist-get success-result :output)))))))
                    `((isError . t)
                      (content . (((type . "text")
                                  (text . ,(format "Command failed: %s" 
                                                 (plist-get success-result :error-message)))))))))
    (message "MCP success response format: %s" 
             (if (and (alist-get 'content response)
                      (not (alist-get 'isError response))) "PASSED" "FAILED")))
  
  ;; Mock failed command result
  (let* ((fail-result '(:success nil :error-message "Command not found"))
         (response (if (plist-get fail-result :success)
                      `((content . (((type . "text")
                                    (text . ,(format "Command executed successfully:\n%s" 
                                                   (plist-get fail-result :output)))))))
                    `((isError . t)
                      (content . (((type . "text")
                                  (text . ,(format "Command failed: %s" 
                                                 (plist-get fail-result :error-message)))))))))
    (message "MCP error response format: %s" 
             (if (alist-get 'isError response) "PASSED" "FAILED"))))

;; Run all tests
(defun run-ai-terminal-tests ()
  "Run all AI terminal tests."
  (message "=== AI Terminal Implementation Tests ===")
  (test-command-validation)
  (test-terminal-buffer-detection)
  (test-output-cleaning)
  (test-mcp-response-format)
  (message "=== Tests Complete ==="))

;; Add the AI terminal functions from claude-code.el for testing
(defun claude-code--validate-ai-command (command)
  "Validate AI COMMAND before execution.
Returns t if command is safe to execute, nil otherwise."
  (let ((dangerous-pattern (cl-find-if 
                           (lambda (pattern) 
                             (string-match-p pattern command))
                           claude-code-ai-dangerous-commands)))
    (if dangerous-pattern
        (if claude-code-ai-command-confirmation
            (yes-or-no-p (format "Execute potentially dangerous command '%s'? " command))
          nil)
      (if claude-code-ai-command-confirmation
          (y-or-n-p (format "Execute command '%s'? " command))
        t))))

(defun claude-code--clean-terminal-output (output)
  "Clean terminal escape sequences and formatting from OUTPUT."
  ;; Remove ANSI escape codes
  (setq output (replace-regexp-in-string "\033\\[[0-9;]*m" "" output))
  ;; Remove carriage returns
  (setq output (replace-regexp-in-string "\r" "" output))
  ;; Remove the command echo (first line) and prompt at end
  (let ((lines (split-string output "\n")))
    (when (> (length lines) 1)
      ;; Remove first line (command echo) and last line if it's just a prompt
      (setq lines (cdr lines))
      (when (and lines (string-match-p "^\\s-*\\(\\$\\|#\\|>\\)\\s-*$" (car (last lines))))
        (setq lines (butlast lines))))
    (string-join lines "\n")))

;; Load and run tests
(require 'cl-lib)
(run-ai-terminal-tests)

(provide 'test_ai_terminal)

;;; test_ai_terminal.el ends here