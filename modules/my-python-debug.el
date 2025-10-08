;;; modules/my-python-debug.el --- Python debugging integration -*- lexical-binding: t; -*-

;;; Commentary:
;; This module integrates DAP debugging with pytest and provides
;; breakpoint management and debug test runners.

;;; Code:

(require 'dap-mode)
(require 'dap-python)

;; Use built-in DAP breakpoint functions
;; dap-breakpoint-toggle, dap-breakpoint-delete-all, etc. are already available

;; Debug test runners
(defun my/debug-nearest-test ()
  "Debug the nearest test function with DAP."
  (interactive)
  (let* ((test-func (my/find-nearest-test-function))
         (class-name (my/find-nearest-class))
         (file-path (buffer-file-name))
         (project-root (when (bound-and-true-p projectile-mode)
                        (projectile-project-root))))
    (if (and test-func file-path project-root)
        (let* ((relative-path (file-relative-name file-path project-root))
               (test-spec (if class-name
                             (format "%s::%s::%s" relative-path class-name test-func)
                           (format "%s::%s" relative-path test-func)))
               ;; Create DAP configuration for pytest
               (debug-config
                `(:type "python"
                  :request "launch"
                  :name "Debug Test"
                  :module "pytest"
                  :args ["-xvs" ,test-spec]
                  :cwd ,project-root
                  :console "integratedTerminal"
                  :justMyCode nil)))
          (message "Starting debug session for: %s" test-spec)
          (dap-debug debug-config))
      (message "Could not determine test to debug"))))

(defun my/debug-test-file ()
  "Debug all tests in current file."
  (interactive)
  (let* ((file-path (buffer-file-name))
         (project-root (when (bound-and-true-p projectile-mode)
                        (projectile-project-root))))
    (if (and file-path project-root)
        (let* ((relative-path (file-relative-name file-path project-root))
               (debug-config
                `(:type "python"
                  :request "launch"
                  :name "Debug Test File"
                  :module "pytest"
                  :args ["-xvs" ,relative-path]
                  :cwd ,project-root
                  :console "integratedTerminal"
                  :justMyCode nil)))
          (message "Starting debug session for file: %s" relative-path)
          (dap-debug debug-config))
      (message "Could not determine file to debug"))))

(defun my/debug-test-with-args ()
  "Debug test with custom pytest arguments."
  (interactive)
  (let* ((args (read-string "Pytest args: " "-xvs "))
         (project-root (when (bound-and-true-p projectile-mode)
                        (projectile-project-root))))
    (if project-root
        (let ((debug-config
               `(:type "python"
                 :request "launch"
                 :name "Debug Test with Args"
                 :module "pytest"
                 :args ,(split-string args)
                 :cwd ,project-root
                 :console "integratedTerminal"
                 :justMyCode nil)))
          (message "Starting debug session with args: %s" args)
          (dap-debug debug-config))
      (message "Could not determine project root"))))

;; Use built-in DAP utilities
;; dap-ui-locals, dap-ui-breakpoints, dap-debug-restart are already available

;; Debug session management
(defun my/debug-session-info ()
  "Show information about current debug session."
  (interactive)
  (let ((debug-buffer "*Debug Session Info*"))
    (with-current-buffer (get-buffer-create debug-buffer)
      (erase-buffer)
      (insert "=== Debug Session Info ===\n\n")
      (if (dap--cur-session)
          (let ((session (dap--cur-session)))
            (insert (format "Session ID: %s\n" (dap--debug-session-name session)))
            (insert (format "Status: %s\n" (dap--debug-session-state session)))
            (insert (format "Thread ID: %s\n" (dap--debug-session-thread-id session))))
        (insert "No active debug session\n"))
      (insert "\n--- Breakpoints ---\n")
      (let ((breakpoints (dap-breakpoint-get-all)))
        (if breakpoints
            (dolist (bp breakpoints)
              (insert (format "%s:%d\n" 
                             (plist-get bp :path)
                             (plist-get bp :line))))
          (insert "No breakpoints set\n")))
      (insert "\n=========================\n")
      (goto-char (point-min))
      (read-only-mode 1))
    (display-buffer debug-buffer)))

;; Integration with hydra for quick debug actions
(defun my/debug-hydra ()
  "Show debug control hydra if available, otherwise show basic controls."
  (interactive)
  (if (fboundp 'dap-hydra)
      (dap-hydra)
    (message "Debug controls: C-c d n (next), C-c d s (step in), C-c d o (step out), C-c d c (continue)")))

(provide 'my-python-debug)

;;; my-python-debug.el ends here