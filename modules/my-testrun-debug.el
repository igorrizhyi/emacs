;;; modules/my-testrun-debug.el --- Enhanced testrun debugging and fixes -*- lexical-binding: t; -*-

;;; Commentary:
;; This module provides debugging and fixes for testrun-nearest functionality.
;; It includes utilities to debug test detection and custom functions for better
;; nearest test detection.

;;; Code:

(defun my/debug-testrun-nearest ()
  "Debug information about current cursor position and test detection."
  (interactive)
  (let* ((line-num (line-number-at-pos))
         (current-line (thing-at-point 'line t))
         (current-defun (which-function))
         (buffer-name (buffer-name))
         (file-path (buffer-file-name))
         (nearest-test (my/find-nearest-test-function))
         (nearest-class (my/find-nearest-class))
         (debug-buffer "*Testrun Debug*")
         (project-root (when (bound-and-true-p projectile-mode)
                        (projectile-project-root))))
    ;; Create debug buffer with content
    (with-current-buffer (get-buffer-create debug-buffer)
      (erase-buffer)
      (insert "=== Debug testrun-nearest ===\n\n")
      (insert (format "File: %s\n" (or file-path "<no file>")))
      (insert (format "Line: %d\n" line-num))
      (insert (format "Current line: %s\n" (string-trim (or current-line ""))))
      (insert (format "which-function: %s\n" (or current-defun "<none>")))
      (insert (format "Current function: %s\n" (or (my/find-current-function) "<none>")))
      (insert (format "Nearest test: %s\n" (or nearest-test "<none>")))
      (insert (format "Nearest class: %s\n" (or nearest-class "<none>")))
      (insert (format "Buffer: %s\n" buffer-name))
      (insert (format "Major mode: %s\n" major-mode))
      (insert (format "Project root: %s\n" (or project-root "<none>")))
      
      (insert "\n--- Test Command ---\n")
      (if (and nearest-test nearest-class project-root)
          (let* ((relative-path (file-relative-name file-path project-root))
                 (test-spec (format "%s::%s::%s" relative-path nearest-class nearest-test))
                 (pytest-cmd (format "cd %s && python -m pytest -xvs %s" project-root test-spec)))
            (insert (format "Would run: %s\n" pytest-cmd))
            (insert (format "Test spec: %s\n" test-spec))
            (insert (format "Working dir: %s\n" project-root)))
        (insert "Cannot determine test to run\n"))
      
      (insert "\n==============================\n")
      (goto-char (point-min))
      (read-only-mode 1))
    
    ;; Show the buffer in a popup window
    (pop-to-buffer debug-buffer)
    (message "Debug complete - see popup window")))

(defun my/find-nearest-class ()
  "Find the nearest class from current cursor position."
  (save-excursion
    (let ((class-name nil))
      ;; Search backwards for class definition
      (while (and (not class-name) (not (bobp)))
        (beginning-of-line)
        (when (looking-at "^\\s-*class\\s-+\\([A-Za-z][A-Za-z0-9_]*\\)")
          (setq class-name (match-string 1)))
        (unless class-name
          (forward-line -1)))
      class-name)))

(defun my/find-current-function ()
  "Find current function name at cursor position."
  (save-excursion
    (let ((func-name nil))
      ;; Search backwards for any function definition
      (while (and (not func-name) (not (bobp)))
        (beginning-of-line)
        (when (looking-at "^\\s-*def\\s-+\\([A-Za-z_][A-Za-z0-9_]*\\)")
          (setq func-name (match-string 1)))
        (unless func-name
          (forward-line -1)))
      func-name)))

(defun my/find-nearest-test-function ()
  "Find the nearest test function from current cursor position."
  (interactive)
  (save-excursion
    (let ((start-pos (point))
          (test-function nil))
      ;; First try to find a test function at or before current position
      (while (and (not test-function) (not (bobp)))
        (beginning-of-line)
        (when (looking-at "^\\s-*def\\s-+\\(test_[^(]+\\)")
          (setq test-function (match-string 1)))
        (unless test-function
          (forward-line -1)))
      
      ;; If no test found before, try searching forward
      (unless test-function
        (goto-char start-pos)
        (while (and (not test-function) (not (eobp)))
          (beginning-of-line)
          (when (looking-at "^\\s-*def\\s-+\\(test_[^(]+\\)")
            (setq test-function (match-string 1)))
          (unless test-function
            (forward-line 1))))
      
      (if test-function
          (progn
            (when (called-interactively-p 'interactive)
              (message "Found nearest test: %s" test-function))
            test-function)
        (progn
          (when (called-interactively-p 'interactive)
            (message "No test function found"))
          nil)))))

(defun my/run-nearest-test-fixed ()
  "Run the nearest test function using pytest with specific test selection."
  (interactive)
  (let* ((test-func (my/find-nearest-test-function))
         (file-path (buffer-file-name))
         (project-root (when (bound-and-true-p projectile-mode)
                        (projectile-project-root))))
    (if (and test-func file-path)
        (let* ((relative-path (if project-root
                                 (file-relative-name file-path project-root)
                               file-path))
               (test-spec (format "%s::%s" relative-path test-func))
               (pytest-cmd (format "python -m pytest -vs %s" test-spec)))
          (message "Running test: %s" test-spec)
          (compile pytest-cmd))
      (message "Could not determine test to run"))))

(defun my/run-nearest-test-with-class ()
  "Run the nearest test function or test class, including class context if applicable.
If cursor is on a test class definition (class name contains 'Test'), runs the entire class.
Otherwise, finds the nearest test function and runs it with class context."
  (interactive)
  (let* ((file-path (buffer-file-name))
         (project-root (when (bound-and-true-p projectile-mode)
                        (projectile-project-root)))
         (relative-path (if project-root
                           (file-relative-name file-path project-root)
                         file-path)))
    (when file-path
      (save-excursion
        ;; First check if we're on a test class definition
        (beginning-of-line)
        (if (and (looking-at "^class\\s-+\\([A-Za-z][A-Za-z0-9_]*\\)")
                 (let ((class-name (match-string 1)))
                   (or (string-match-p "Test" class-name)
                       (string-prefix-p "Test" class-name))))
            ;; We're on a test class - run the entire class
            (let* ((class-name (match-string 1))
                   (test-spec (format "%s::%s" relative-path class-name))
                   (pytest-cmd (if project-root
                                  (format "cd %s && python -m pytest -vs %s" project-root test-spec)
                                (format "python -m pytest -vs %s" test-spec))))
              (message "Running test class: %s" test-spec)
              (message "From directory: %s" (or project-root "current directory"))
              (my/run-pytest-with-output-parsing pytest-cmd test-spec))
          
          ;; Not on a class line - find nearest test function
          (let ((test-func (my/find-nearest-test-function)))
            (when test-func
              (let ((class-name nil))
                ;; Find the class this test belongs to
                (goto-char (point-min))
                (while (re-search-forward (format "def %s" test-func) nil t)
                  (save-excursion
                    (beginning-of-line)
                    (while (and (not class-name) (not (bobp)))
                      (forward-line -1)
                      (when (looking-at "^class\\s-+\\([A-Za-z][A-Za-z0-9_]*\\)")
                        (setq class-name (match-string 1))))))
                
                (let* ((test-spec (if class-name
                                     (format "%s::%s::%s" relative-path class-name test-func)
                                   (format "%s::%s" relative-path test-func)))
                       (pytest-cmd (if project-root
                                      (format "cd %s && python -m pytest -vs %s" project-root test-spec)
                                    (format "python -m pytest -vs %s" test-spec))))
                  (message "Running test method: %s" test-spec)
                  (message "From directory: %s" (or project-root "current directory"))
                  (my/run-pytest-with-output-parsing pytest-cmd test-spec))))))))))

(defun my/run-pytest-with-output-parsing (pytest-cmd test-spec)
  "Run pytest command and parse the output for errors."
  (let* ((output-buffer "*pytest-output*")
         (error-buffer "*pytest-errors*")
         (process nil)
         (original-window (selected-window))
         (project-root (when (bound-and-true-p projectile-mode)
                        (projectile-project-root))))
    ;; Clear previous buffers
    (when (get-buffer output-buffer)
      (kill-buffer output-buffer))
    (when (get-buffer error-buffer)
      (kill-buffer error-buffer))
    
    ;; Create output buffer
    (with-current-buffer (get-buffer-create output-buffer)
      (erase-buffer)
      (insert (format "Running: %s\n" pytest-cmd))
      (insert "=" (make-string 80 ?=) "\n\n"))
    
    ;; Setup window layout - show output in bottom split
    (my/setup-pytest-windows output-buffer)
    
    ;; Start the process
    (message "Starting pytest: %s" test-spec)
    (setq process 
          (start-process-shell-command
           "pytest" output-buffer pytest-cmd))
    
    ;; Set up process sentinel to handle completion
    (set-process-sentinel process 
                         (lambda (proc event)
                           (when (memq (process-status proc) '(exit signal))
                             (my/handle-pytest-completion proc event test-spec output-buffer error-buffer project-root))))
    
    ;; Set up process filter to capture output in real-time
    (set-process-filter process
                       (lambda (proc string)
                         (with-current-buffer (process-buffer proc)
                           (goto-char (point-max))
                           (insert string)
                           (goto-char (point-max))
                           ;; Keep the cursor at the bottom in the output window
                           (when-let ((output-window (get-buffer-window (current-buffer))))
                             (with-selected-window output-window
                               (goto-char (point-max)))))))))

(defun my/handle-pytest-completion (process event test-spec output-buffer error-buffer project-root)
  "Handle pytest process completion and parse results."
  (let ((exit-code (process-exit-status process))
        (output-text ""))
    
    ;; Get the full output
    (when (buffer-live-p (get-buffer output-buffer))
      (with-current-buffer output-buffer
        (setq output-text (buffer-string))))
    
    ;; Parse and display results
    (cond 
     ;; Success (exit code 0)
     ((= exit-code 0)
      (message "✅ Test PASSED: %s" test-spec)
      ;; Close the pytest output window before showing popup
      (my/close-pytest-output-window)
      (my/show-success-popup output-text test-spec))
     
     ;; Failure (exit code 1)
     ((= exit-code 1)
      (message "❌ Test FAILED: %s" test-spec)
      (my/setup-error-window-and-show-results output-text error-buffer test-spec project-root))
     
     ;; Other errors (exit code > 1)
     (t
      (message "💥 Test ERROR (exit code %d): %s" exit-code test-spec)
      (my/setup-error-window-and-show-results output-text error-buffer test-spec project-root)))))

(defun my/setup-pytest-windows (output-buffer)
  "Set up window layout for pytest: output in bottom bar using custom layout."
  (let ((current-window (selected-window)))
    ;; Use our custom layout system to show pytest output in bottom bar
    (my-window-layout-show-with-layout 'bottom-bar output-buffer)
    ;; Return focus to the original window
    (select-window current-window)))

(defun my/setup-error-window-and-show-results (output-text error-buffer test-spec project-root)
  "Set up error window and show parsed results with clickable links in right sidebar."
  ;; Parse errors first
  (let ((error-info (my/parse-pytest-errors output-text project-root)))
    ;; Show errors in right sidebar
    (my/show-errors-in-split error-buffer error-info test-spec project-root)
    ;; Close the pytest output window now that we have parsed results
    (my/close-pytest-output-window)))

(defun my/show-errors-in-split (error-buffer error-info test-spec project-root)
  "Show errors in right sidebar with clickable links using custom layout."
  (let ((current-window (selected-window)))
    ;; Create and populate error buffer with clickable links
    (my/populate-error-buffer-with-links error-buffer error-info test-spec project-root)
    
    ;; Use our custom layout system to show errors in right chat sidebar
    (my-window-layout-show-with-layout 'right-chat error-buffer)
    
    ;; Return focus to the original window
    (select-window current-window)))

(defun my/show-success-popup (output-text test-spec)
  "Show a concise success popup with only essential information."
  (let ((timing-info "")
        (test-count "")
        (passed-count ""))
    
    ;; Extract key information from output
    (dolist (line (split-string output-text "\n"))
      (cond
       ;; Extract timing information from final summary line
       ((string-match "=+ \\([0-9]+\\) passed.* in \\([0-9.]+s\\) =+" line)
        (setq passed-count (match-string 1 line))
        (setq timing-info (match-string 2 line)))
       ;; Extract test count from collection line
       ((string-match "collected \\([0-9]+\\) items?" line)
        (setq test-count (match-string 1 line)))
       ;; Fallback: Extract passed count if not found in summary line
       ((and (string-empty-p passed-count) (string-match "\\([0-9]+\\) passed" line))
        (setq passed-count (match-string 1 line)))))
    
    ;; Create concise popup content
    (let ((candidates 
           (list 
            (propertize (format "✅ TEST PASSED: %s" test-spec) 'face 'success)
            ""
            (propertize (format "📊 %s test%s completed"
                               (if (string-empty-p passed-count) "1" passed-count)
                               (if (and (not (string-empty-p passed-count))
                                       (not (string= passed-count "1"))) "s" ""))
                       'face 'font-lock-keyword-face)
            (when (not (string-empty-p timing-info))
              (propertize (format "⏱️  Execution time: %s" timing-info) 
                         'face 'font-lock-comment-face)))))
      
      ;; Remove nil entries and empty strings except the deliberate separator
      (setq candidates (delq nil candidates))
      
      ;; Show using direct posframe - centered
      (let ((buffer-name " *test-results*"))
        (with-current-buffer (get-buffer-create buffer-name)
          (erase-buffer)
          (insert (mapconcat 'identity candidates "\n"))
          (goto-char (point-min)))
        
        ;; Show centered posframe with appropriate height
        (posframe-show buffer-name
                       :poshandler #'posframe-poshandler-frame-center
                       :width 60
                       :height (+ 2 (length candidates))
                       :border-width 2
                       :border-color "#555555"
                       :background-color (face-background 'default)
                       :foreground-color (face-foreground 'default)
                       :internal-border-width 8
                       :left-fringe 8
                       :right-fringe 8)
        
        ;; Wait for user input then hide
        (unwind-protect
            (read-key "Press any key to close...")
          (posframe-hide buffer-name)
          (kill-buffer buffer-name))))))

(defun my/parse-pytest-errors (output-text project-root)
  "Parse pytest output and extract file:line with detailed error information."
  (let* ((lines (split-string output-text "\n"))
         (errors '())
         (in-failure-section nil)
         (current-test-name nil)
         (current-error-details '())
         (collecting-details nil))
    
    (dolist (line lines)
      (cond
       ;; Start of FAILURES section
       ((string-match "^=+ FAILURES =+" line)
        (setq in-failure-section t))
       
       ;; Individual test failure header
       ((and in-failure-section (string-match "^_+ \\(.+\\) _+$" line))
        (setq current-test-name (match-string 1 line))
        (setq current-error-details '())
        (setq collecting-details t))
       
       ;; Match the direct error line format first: "path/file.py:27: AssertionError"
       ((string-match "^\\([^:]+\\.py\\):\\([0-9]+\\): \\([A-Za-z][A-Za-z0-9_]*\\)" line)
        (let* ((file-path (match-string 1 line))
               (line-num (string-to-number (match-string 2 line)))
               (error-type (match-string 3 line))
               (full-path (if (and project-root (not (file-name-absolute-p file-path)))
                             (expand-file-name file-path project-root)
                           file-path))
               (detailed-error (string-join (reverse current-error-details) "\n")))
          ;; Avoid duplicates
          (unless (cl-find-if (lambda (err) 
                               (and (string= (plist-get err :file) full-path)
                                    (= (plist-get err :line) line-num)))
                             errors)
            (push (list :file full-path 
                       :line line-num 
                       :error error-type
                       :test-name current-test-name
                       :details detailed-error) errors))))
       
       ;; Collect error details for current test (after we have a test name)
       ((and in-failure-section collecting-details current-test-name
             (not (string-match "^=\\|^_\\|^-\\|^Captured\\|short test summary" line))
             (not (string-empty-p (string-trim line))))
        (push line current-error-details))
       
       ;; Stop collecting when we hit certain section markers
       ((string-match "^-+\\|^Captured\\|short test summary" line)
        (setq collecting-details nil))))
    
    ;; Return in order found
    (reverse errors)))

(defvar my/error-details-overlays '()
  "List of overlays used for collapsible error details.")

(defun my/populate-error-buffer-with-links (error-buffer error-info test-spec project-root)
  "Populate error buffer with collapsible clickable links to files."
  (with-current-buffer (get-buffer-create error-buffer)
    (erase-buffer)
    
    ;; Clear previous overlays
    (dolist (overlay my/error-details-overlays)
      (when (overlay-buffer overlay)
        (delete-overlay overlay)))
    (setq my/error-details-overlays '())
    
    (insert (format "❌ Test Failures for: %s\n" test-spec))
    (insert (make-string 80 ?=) "\n\n")
    
    (if error-info
        (progn
          (insert "🔍 CLICKABLE ERROR LOCATIONS (Press TAB to toggle details):\n")
          (insert (make-string 40 ?-) "\n")
          
          (dolist (error error-info)
            (let* ((file (plist-get error :file))
                   (line (plist-get error :line))
                   (error-msg (plist-get error :error))
                   (test-name (plist-get error :test-name))
                   (details (plist-get error :details))
                   (relative-file (if project-root
                                     (file-relative-name file project-root)
                                   file))
                   (clickable-text (format "%s:%d: %s" relative-file line error-msg)))
              
              ;; Insert clickable link
              (let ((start (point)))
                (insert clickable-text)
                (let ((link-end (point)))
                  ;; Add expansion indicator
                  (insert " [▶ Press TAB for details]")
                  (let ((line-end (point)))
                    (insert "\n")
                    
                    ;; Make the link clickable
                    (make-button start link-end
                                'action (lambda (button)
                                         (my/open-file-at-line file line))
                                'help-echo (format "Click to open %s at line %d" file line)
                                'follow-link t
                                'face 'link)
                    
                    ;; Store error details as text properties for TAB functionality
                    (put-text-property start line-end 'error-details details)
                    (put-text-property start line-end 'error-file file)
                    (put-text-property start line-end 'error-line line)
                    (put-text-property start line-end 'error-test-name test-name)
                    (put-text-property start line-end 'collapsible-error t))))))
          
          (insert "\n📋 FULL PYTEST OUTPUT AVAILABLE IN *pytest-output* BUFFER\n")
          (insert "\n💡 USAGE: Click links to open files, press TAB on error lines to toggle details\n"))
      (insert "No specific error locations found.\n"))
    
    ;; Set up the error buffer keymap
    (use-local-map (my/create-error-buffer-keymap))
    (goto-char (point-min))
    ;; Don't make it read-only so TAB functionality works
    (setq buffer-read-only nil)))

(defun my/create-error-buffer-keymap ()
  "Create keymap for error buffer with TAB functionality and Enter to open file."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'my/toggle-error-details)
    (define-key map (kbd "<tab>") #'my/toggle-error-details)
    (define-key map (kbd "RET") #'my/open-error-file-at-point)
    (define-key map (kbd "<return>") #'my/open-error-file-at-point)
    (define-key map (kbd "q") #'quit-window)
    map))

(defun my/open-error-file-at-point ()
  "Open the error file at the current line using stored text properties."
  (interactive)
  (let ((pos (point)))
    (when (get-text-property pos 'collapsible-error)
      (let ((file (get-text-property pos 'error-file))
            (line (get-text-property pos 'error-line)))
        (when (and file line)
          (my/open-file-at-line file line))))))

(defun my/toggle-error-details ()
  "Toggle detailed error information at point."
  (interactive)
  (let ((pos (point)))
    (when (get-text-property pos 'collapsible-error)
      (let* ((details (get-text-property pos 'error-details))
             (test-name (get-text-property pos 'error-test-name))
             (line-start (line-beginning-position))
             (line-end (line-end-position))
             (is-expanded (get-text-property pos 'error-expanded)))
        
        (if is-expanded
            ;; Collapse: find and remove the details
            (save-excursion
              (let ((inhibit-read-only t))
                (goto-char line-end)
                ;; Update indicator first
                (when (looking-back "\\[▼ Press TAB to hide\\]" (line-beginning-position))
                  (replace-match "[▶ Press TAB for details]"))
                
                ;; Find and delete the expanded content
                (forward-line 1)
                (let ((details-start (point)))
                  ;; Look for the end of our details block (next non-indented line or buffer end)
                  (while (and (not (eobp))
                             (or (looking-at "^  ") ; Indented content
                                 (looking-at "^$")))  ; Empty lines
                    (forward-line 1))
                  ;; Delete the details region
                  (delete-region details-start (point)))
                
                ;; Remove expanded state and clean up overlays
                (put-text-property line-start line-end 'error-expanded nil)
                (dolist (ov my/error-details-overlays)
                  (when (and (overlay-buffer ov)
                           (>= (overlay-start ov) line-start)
                           (<= (overlay-end ov) line-end))
                    (delete-overlay ov)
                    (setq my/error-details-overlays (delq ov my/error-details-overlays))))))
          
          ;; Expand: create details
          (when (and details (not (string-empty-p (string-trim details))))
            (save-excursion
              (goto-char line-end)
              (let ((inhibit-read-only t))
                ;; Update indicator
                (when (looking-back "\\[▶ Press TAB for details\\]" (line-beginning-position))
                  (replace-match "[▼ Press TAB to hide]"))
                
                ;; Insert details
                (insert "\n")
                (let ((details-start (point)))
                  ;; Insert a clean header
                  (insert (format "  Error Details for %s:\n" (or test-name "test")))
                  (insert "\n")
                  
                  ;; Insert the details with proper indentation
                  (let ((details-lines (split-string details "\n")))
                    (dolist (detail-line details-lines)
                      (insert (format "  %s\n" detail-line))))
                  
                  (insert "\n")
                  
                  ;; Create styled overlay for the entire block
                  (let ((overlay (make-overlay details-start (point))))
                    (overlay-put overlay 'face 'my/error-details-face)
                    (overlay-put overlay 'my/error-details t)
                    (push overlay my/error-details-overlays))
                  
                  ;; Mark as expanded
                  (put-text-property line-start line-end 'error-expanded t))))))))))

(defface my/error-details-face
  '((t :background "#2d1b1b" 
       :foreground "#ff9999"
       :extend t
       :inherit fixed-pitch))
  "Face for expanded error details."
  :group 'my-testrun-debug)

(defun my/close-pytest-output-window ()
  "Close the pytest output window using custom layout system."
  (my-window-layout-hide-bottom-bar))

(defun my/open-file-at-line (file line)
  "Open file at specific line in the main center window using layout system."
  (let ((buffer (find-file-noselect file)))
    ;; Use layout system to show the file in main center
    (my-layout-show-in-main-center buffer)
    ;; The layout function should handle window selection, but let's position cursor
    (with-current-buffer buffer
      (goto-line line)
      ;; Highlight the line briefly
      (pulse-momentary-highlight-one-line (point)))
    (message "Opened %s at line %d" (file-name-nondirectory file) line)))

(defun my/test-detection-at-point ()
  "Test detection functions at current cursor position."
  (interactive)
  (message "=== Testing Detection Functions ===")
  (message "Position: %d" (point))
  (message "Line: %s" (string-trim (thing-at-point 'line t)))
  (message "Nearest class: %s" (my/find-nearest-class))
  (message "Current function: %s" (my/find-current-function))
  (message "Nearest test: %s" (my/find-nearest-test-function))
  (message "================================"))

(defun my/show-testrun-config ()
  "Show current testrun configuration."
  (interactive)
  (message "Testrun configuration:")
  (message "  testrun-runners: %S" (bound-and-true-p testrun-runners))
  (message "  testrun-mode-alist: %S" (bound-and-true-p testrun-mode-alist))
  (message "  Current major mode: %s" major-mode)
  (when (bound-and-true-p testrun-runners)
    (let ((runner (cdr (assq major-mode testrun-runners))))
      (message "  Runner for current mode: %S" runner))))

;; Enhanced testrun nearest function
(defun my/testrun-nearest-enhanced ()
  "Enhanced version of testrun-nearest with better test detection."
  (interactive)
  (if (fboundp 'testrun-nearest)
      (progn
        (my/debug-testrun-nearest)
        (my/show-testrun-config)
        (message "Running original testrun-nearest...")
        (testrun-nearest)
        (message "If that didn't work, try M-x my/run-nearest-test-with-class"))
    (progn
      (message "testrun-nearest not available, using custom implementation")
      (my/run-nearest-test-with-class))))

;; Function to run all tests with the same UI flow as single test
;; This provides the same experience as my/run-nearest-test-with-class:
;; 1. Opens pytest output in bottom split in real-time
;; 2. On failure, parses errors and shows clickable links in right split
;; 3. Maintains focus on the main code window
(defun my/testrun-all ()
  "Run all tests in the project with output parsing and error display."
  (interactive)
  (let* ((project-root (when (bound-and-true-p projectile-mode)
                        (projectile-project-root))))
    (if project-root
        (let* ((pytest-cmd (format "cd %s && python -m pytest -vs" project-root))
               (test-spec "all tests"))
          (message "Running all tests in project: %s" project-root)
          (my/run-pytest-with-output-parsing pytest-cmd test-spec))
      (let* ((pytest-cmd "python -m pytest -vs")
             (test-spec "all tests"))
        (message "Running all tests in current directory")
        (my/run-pytest-with-output-parsing pytest-cmd test-spec)))))

(provide 'my-testrun-debug)

;;; my-testrun-debug.el ends here
