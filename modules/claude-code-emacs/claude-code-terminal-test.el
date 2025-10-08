;;; claude-code-terminal-test.el --- Tests for claude-code-terminal -*- lexical-binding: t; -*-

;; Copyright (C) 2025

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

;; Tests for claude-code-terminal module.

;;; Code:

(require 'ert)
(require 'claude-code-terminal)

(defvar claude-code-terminal-test-project-root "/tmp/test-project/")

(ert-deftest test-claude-code-terminal-generate-id ()
  "Test terminal ID generation."
  (let ((claude-code-terminal-counter 0))
    (should (string= "term-1" (claude-code-terminal-generate-id)))
    (should (string= "term-2" (claude-code-terminal-generate-id)))
    (should (string= "term-3" (claude-code-terminal-generate-id)))))

(ert-deftest test-claude-code-terminal-buffer-name ()
  "Test terminal buffer name generation."
  (should (string= "*claude-terminal:test-project:term-1*"
                   (claude-code-terminal-buffer-name "/tmp/test-project/" "term-1")))
  (should (string= "*claude-terminal:another:term-2*"
                   (claude-code-terminal-buffer-name "/home/user/another/" "term-2"))))

(ert-deftest test-claude-code-terminal-register-unregister ()
  "Test terminal session registration and unregistration."
  (let ((claude-code-terminal-sessions (make-hash-table :test 'equal))
        (project-root "/tmp/test-project/")
        (buffer-name "*claude-terminal:test:term-1*")
        (terminal-id "term-1"))
    
    ;; Test registration
    (claude-code-terminal-register project-root buffer-name terminal-id)
    (let ((sessions (claude-code-terminal-get-sessions project-root)))
      (should (= 1 (length sessions)))
      (should (string= buffer-name (caar sessions)))
      (should (string= terminal-id (cdar sessions))))
    
    ;; Test unregistration
    (claude-code-terminal-unregister project-root buffer-name)
    (let ((sessions (claude-code-terminal-get-sessions project-root)))
      (should (= 0 (length sessions))))))

(ert-deftest test-claude-code-terminal-get-sessions ()
  "Test getting terminal sessions for a project."
  (let ((claude-code-terminal-sessions (make-hash-table :test 'equal))
        (project-root "/tmp/test-project/"))
    
    ;; Initially empty
    (should (= 0 (length (claude-code-terminal-get-sessions project-root))))
    
    ;; Add some sessions
    (claude-code-terminal-register project-root "*term1*" "term-1")
    (claude-code-terminal-register project-root "*term2*" "term-2")
    
    (let ((sessions (claude-code-terminal-get-sessions project-root)))
      (should (= 2 (length sessions)))
      ;; Check that both terminals are present
      (should (cl-find "term-1" sessions :key #'cdr :test #'string=))
      (should (cl-find "term-2" sessions :key #'cdr :test #'string=)))))

(provide 'claude-code-terminal-test)
;;; claude-code-terminal-test.el ends here