;;; modules/my-navigation.el --- Navigation utilities -*- lexical-binding: t; -*-

;;; Commentary:
;; UP/DOWN arrows jump 10 lines at a time
;; LEFT/RIGHT arrows navigate between functions

;;; Code:

;; Require smart splits for advanced split management
(require 'my-layout)

(defun my/jump-up ()
  "Jump up 10 lines and postpone jump registration."
  (interactive)
  (forward-line -10)
  (when (fboundp 'my-super-jumps-postpone-async)
    (my-super-jumps-postpone-async "half-page-up")))

(defun my/jump-down ()
  "Jump down 10 lines and postpone jump registration."
  (interactive)
  (forward-line 10)
  (when (fboundp 'my-super-jumps-postpone-async)
    (my-super-jumps-postpone-async "half-page-down")))

(defun my/next-defun ()
  "Move to the beginning of the next function definition and postpone jump registration.
Uses `beginning-of-defun' with a negative argument to move forward."
  (interactive)
  (beginning-of-defun -1)
  (when (fboundp 'my-super-jumps-postpone-async)
    (my-super-jumps-postpone-async "next-function")))

(defun my/prev-defun ()
  "Move to the beginning of the previous function definition and postpone jump registration."
  (interactive)
  (beginning-of-defun 1)
  (when (fboundp 'my-super-jumps-postpone-async)
    (my-super-jumps-postpone-async "prev-function")))

;; Bind arrow keys for normal and visual modes
(map! :n "<up>" #'my/jump-up
      :n "<down>" #'my/jump-down
      :v "<up>" #'my/jump-up
      :v "<down>" #'my/jump-down
      ;; Function navigation with left/right arrows
      :n "<left>" #'my/prev-defun         ; Previous function
      :n "<right>" #'my/next-defun)       ; Next function

;; Aggressively override Ctrl-Tab from yasnippet
(after! yasnippet
  ;; First unbind the yasnippet function
  (map! :map yas-minor-mode-map
        "C-<tab>" nil)
  (map! :map yas-keymap
        "C-<tab>" nil)
  ;; Unbind from insert mode specifically
  (map! :i "C-<tab>" nil))

;; Advice to register jump before buffer switching
(defun my/register-jump-before-switch-buffer (&rest _)
  "Register current position as jump before switching buffers."
  (when (fboundp 'my-super-jumps-mark-and-register)
    (my-super-jumps-mark-and-register)))

;; Add advice to switch-to-buffer
(advice-add 'switch-to-buffer :before #'my/register-jump-before-switch-buffer)

;; Keep the original bindings - they'll now automatically register jumps
(map! :g "C-<tab>" #'switch-to-buffer
      :n "C-<tab>" #'switch-to-buffer
      :i "C-<tab>" #'switch-to-buffer
      :v "C-<tab>" #'switch-to-buffer)

;; Helper function to set evil jump before switching buffers
(defun my/goto-jumps-selection ()
  (interactive)
  (evil-set-jump)
  (windmove-left)
  )

;; Force override with global-set-key as backup
(with-eval-after-load 'yasnippet
  (global-set-key (kbd "C-<tab>") #'my/smart-switch-buffer))

;; Python structural navigation with { and }
(with-eval-after-load 'python
  (defun my/python-nav-up-list-backward ()
    "Move to the beginning of the current/outer block backward."
    (interactive)
    (python-nav-backward-up-list 1))
  (defun my/python-nav-up-list-forward ()
    "Move forward to the beginning of the next outer block."
    (interactive)
    (python-nav-backward-up-list -1))
  
  ;; Class block navigation functions
  (defun my/python-prev-class ()
    "Move to the previous class definition."
    (interactive)
    (let ((current-pos (point)))
      (if (re-search-backward "^class " nil t)
          (progn
            (beginning-of-line)
            (message "Moved to previous class"))
        (progn
          (goto-char current-pos)
          (message "No previous class found")))))
  
  (defun my/python-next-class ()
    "Move to the next class definition."
    (interactive)
    (let ((current-pos (point))
          (found nil))
      ;; Move forward to avoid matching current line if we're on a class definition
      (when (looking-at "^class ")
        (forward-line 1))
      (if (re-search-forward "^class " nil t)
          (progn
            (beginning-of-line)
            (message "Moved to next class"))
        (progn
          (goto-char current-pos)
          (message "No next class found")))))
  
  (defun my/python-current-or-outer-class ()
    "Move to the current class definition or the outer class if nested."
    (interactive)
    (let ((current-pos (point))
          (current-indent (current-indentation))
          (found-class nil))
      ;; Look backwards for class definition
      (save-excursion
        (while (and (not found-class) (re-search-backward "^class " nil t))
          (let ((class-indent (current-indentation)))
            ;; If we find a class at same or lesser indentation, that's our target
            (when (<= class-indent current-indent)
              (setq found-class (point))))))
      (if found-class
          (progn
            (goto-char found-class)
            (message "Moved to current/outer class"))
        (message "No enclosing class found"))))
  
  ;; Replace { and } with class navigation
  (map! :map python-mode-map
        :n "{" #'my/python-prev-class
        :n "}" #'my/python-next-class
        ;; Keep the original block navigation on shifted versions if needed
        :n "C-{" #'my/python-nav-up-list-backward
        :n "C-}" #'my/python-nav-up-list-forward
        :n "M-{" #'my/python-current-or-outer-class)
  
  (when (boundp 'python-ts-mode-map)
    (map! :map python-ts-mode-map
          :n "{" #'my/python-prev-class
          :n "}" #'my/python-next-class
          ;; Keep the original block navigation on shifted versions if needed
          :n "C-{" #'my/python-nav-up-list-backward
          :n "C-}" #'my/python-nav-up-list-forward
          :n "M-{" #'my/python-current-or-outer-class)))

;;; Custom Global Marks System with Usage Tracking
(defvar my/global-marks (make-hash-table :test 'equal)
  "Hash table storing global marks.
Key: mark name (string)
Value: plist with :buffer :position :line :preview :created-time :last-visited")

(defvar my/marks-counter 0
  "Counter for auto-generating mark names.")

(defun my/get-language-for-mode ()
  "Get the language identifier for markdown code blocks based on current major mode."
  (cond
   ((derived-mode-p 'emacs-lisp-mode) "elisp")
   ((derived-mode-p 'lisp-mode) "lisp")
   ((derived-mode-p 'python-mode) "python")
   ((derived-mode-p 'python-ts-mode) "python")
   ((derived-mode-p 'js-mode 'js2-mode 'js3-mode) "javascript")
   ((derived-mode-p 'typescript-mode 'typescript-ts-mode) "typescript")
   ((derived-mode-p 'java-mode) "java")
   ((derived-mode-p 'c-mode) "c")
   ((derived-mode-p 'c++-mode) "cpp")
   ((derived-mode-p 'rust-mode 'rust-ts-mode) "rust")
   ((derived-mode-p 'go-mode 'go-ts-mode) "go")
   ((derived-mode-p 'ruby-mode) "ruby")
   ((derived-mode-p 'php-mode) "php")
   ((derived-mode-p 'sh-mode 'bash-ts-mode) "bash")
   ((derived-mode-p 'sql-mode) "sql")
   ((derived-mode-p 'css-mode) "css")
   ((derived-mode-p 'html-mode) "html")
   ((derived-mode-p 'xml-mode) "xml")
   ((derived-mode-p 'yaml-mode) "yaml")
   ((derived-mode-p 'json-mode) "json")
   ((derived-mode-p 'markdown-mode) "markdown")
   ((derived-mode-p 'org-mode) "org")
   (t "text")))

(defun my/get-project-marks-file ()
  "Get the markdown file path for storing marks context for current project."
  (let* ((project-root (if (fboundp 'projectile-project-root)
                          (projectile-project-root)
                        (if (fboundp 'project-root)
                            (project-root (project-current))
                          default-directory)))
         (project-name (file-name-nondirectory (directory-file-name project-root)))
         (safe-name (replace-regexp-in-string "[^a-zA-Z0-9_-]" "_" project-name)))
    (expand-file-name (format "marks-%s.md" safe-name) temporary-file-directory)))

(defun my/generate-mark-context (position)
  "Generate context around POSITION with 3 lines before and after, removing common indentation."
  (save-excursion
    (goto-char position)
    (let* ((mark-line (line-number-at-pos))
           (start-line (max 1 (- mark-line 3)))
           (end-line (+ mark-line 3))
           (start-pos (progn (goto-line start-line) (line-beginning-position)))
           (end-pos (progn (goto-line end-line) (line-end-position)))
           (raw-context (buffer-substring-no-properties start-pos end-pos))
           (lines (split-string raw-context "\n"))
           ;; Find minimum indentation of non-empty lines
           (min-indent (apply 'min 
                             (mapcar (lambda (line)
                                       (if (string-match "^[ \t]*$" line)
                                           most-positive-fixnum  ; Ignore empty lines
                                         (progn
                                           (string-match "^[ \t]*" line)
                                           (length (match-string 0 line)))))
                                     lines)))
           ;; Remove common indentation from all lines
           (dedented-lines (mapcar (lambda (line)
                                     (if (string-match "^[ \t]*$" line)
                                         line  ; Keep empty lines as-is
                                       (substring line (min min-indent (length line)))))
                                   lines))
           (context (string-join dedented-lines "\n"))
           (language (my/get-language-for-mode)))
      (list :context context :language language :start-line start-line :mark-line mark-line))))

(defun my/update-marks-markdown ()
  "Update the markdown file with all current marks."
  (let ((markdown-file (my/get-project-marks-file))
        (project-root (if (fboundp 'projectile-project-root)
                         (projectile-project-root)
                       (if (fboundp 'project-root)
                           (project-root (project-current))
                         default-directory))))
    (with-temp-file markdown-file
      (insert (format "# Global Marks for %s\n"
                     (file-name-nondirectory (directory-file-name project-root))))
      ;; (insert (format "*Generated: %s*\n\n"
      ;;                (format-time-string "%Y-%m-%d %H:%M:%S")))
      (insert (format "<!-- PROJECT_ROOT: %s -->\n\n" project-root))
      
      ;; Sort marks by last visited (most recent first)
      (let ((marks-list '()))
        (maphash (lambda (name info) (push (cons name info) marks-list)) my/global-marks)
        (setq marks-list (sort marks-list 
                              (lambda (a b)
                                (time-less-p (plist-get (cdr b) :last-visited)
                                           (plist-get (cdr a) :last-visited)))))
        
        (dolist (mark-entry marks-list)
          (let* ((mark-name (car mark-entry))
                 (mark-info (cdr mark-entry))
                 (buffer (plist-get mark-info :buffer))
                 (buffer-name (plist-get mark-info :buffer-name))
                 (file-path (plist-get mark-info :file-path))
                 (line-num (plist-get mark-info :line))
                 (last-visited (plist-get mark-info :last-visited))
                 (buffer-exists (and buffer (buffer-live-p buffer))))

            (insert (format "### %s:%d [%s]\n"
                           (if file-path 
                               (file-name-nondirectory file-path)
                             buffer-name) 
                           line-num
                           mark-name))

            ;; Add context if buffer exists
            (when buffer-exists
              (let ((context-info (with-current-buffer buffer
                                   (my/generate-mark-context (plist-get mark-info :position)))))
                (insert (format "```%s\n" (plist-get context-info :language)))
                (insert (plist-get context-info :context))
                (insert "\n```\n\n")))
            ))))))

(defun my/cleanup-old-marks ()
  "Keep only the 5 most recent marks, removing older ones."
  (let ((marks-list '()))
    ;; Collect all marks with their creation times
    (maphash (lambda (name info)
               (push (cons name (plist-get info :created-time)) marks-list))
             my/global-marks)
    
    ;; If we have more than 5 marks, remove the oldest ones
    (when (> (length marks-list) 5)
      ;; Sort by creation time (newest first)
      (setq marks-list (sort marks-list 
                            (lambda (a b)
                              (time-less-p (cdr b) (cdr a)))))
      
      ;; Remove marks beyond the first 5
      (dolist (mark-entry (nthcdr 5 marks-list))
        (let ((mark-name (car mark-entry)))
          (remhash mark-name my/global-marks)
          (message "Removed old mark: %s" mark-name))))))

(defun my/create-mark (&optional name)
  "Create a global mark at current position.
If NAME is provided, use it as mark name. Otherwise, auto-generate based on timestamp."
  (interactive)
  (let* ((mark-name (or name 
                        (format-time-string "%H:%M:%S" (current-time))))
         (current-buffer (current-buffer))
         (current-pos (point))
         (line-num (line-number-at-pos))
         (preview (save-excursion
                   (let* ((line-start (line-beginning-position))
                          (line-end (line-end-position))
                          (line-text (buffer-substring-no-properties line-start line-end))
                          (trimmed (string-trim line-text))
                          (limited (if (> (length trimmed) 80)
                                     (concat (substring trimmed 0 77) "...")
                                   trimmed)))
                     limited)))
         (current-time (current-time)))
    
    (when (string-empty-p mark-name)
      (user-error "Mark name cannot be empty"))
    
    ;; Store mark in hash table
    (puthash mark-name
             (list :buffer current-buffer
                   :position current-pos
                   :line line-num
                   :preview preview
                   :created-time current-time
                   :last-visited current-time
                   :buffer-name (buffer-name current-buffer)
                   :file-path (or (buffer-file-name current-buffer) 
                                  (buffer-name current-buffer)))
             my/global-marks)
    
    ;; Maintain only 5 most recent marks
    (my/cleanup-old-marks)
    
    ;; Update markdown file with rich context
    (my/update-marks-markdown)
    (my/refresh-markdown-buffer)
    
    (message "Created mark '%s' at %s:%d" mark-name (buffer-name) line-num)))

;; (defun my/jump-to-mark ()
;;   "Show all global marks with preview and jump to selected one."
;;   (interactive)
;;   (if (= (hash-table-count my/global-marks) 0)
;;       (message "No marks found. Create some with `my/create-mark'")

;;     (let ((completion-choices '())
;;           (mark-data (make-hash-table :test 'equal)))

;;       ;; Collect all marks and prepare for sorting
;;       (maphash (lambda (mark-name mark-info)
;;                  (let* ((buffer (plist-get mark-info :buffer))
;;                         (buffer-name (plist-get mark-info :buffer-name))
;;                         (file-path (plist-get mark-info :file-path))
;;                         (line-num (plist-get mark-info :line))
;;                         (preview (plist-get mark-info :preview))
;;                         (last-visited (plist-get mark-info :last-visited))
;;                         (is-current-buffer (eq buffer (current-buffer)))
;;                         ;; Check if buffer still exists
;;                         (buffer-exists (and buffer (buffer-live-p buffer)))
;;                         (choice-text (format "%s %s %s:%d  %s"
;;                                            (propertize mark-name 'face 'font-lock-constant-face)
;;                                            (if is-current-buffer
;;                                                (propertize "[current]" 'face 'success)
;;                                              (if buffer-exists ""
;;                                                (propertize "[dead]" 'face 'error)))
;;                                            (propertize (if file-path (file-name-nondirectory file-path) buffer-name)
;;                                                       'face 'font-lock-function-name-face)
;;                                            line-num
;;                                            (propertize preview 'face 'font-lock-comment-face))))

;;                    (push (cons choice-text
;;                                (list :name mark-name
;;                                      :info mark-info
;;                                      :last-visited last-visited
;;                                      :buffer-exists buffer-exists))
;;                          completion-choices)
;;                    (puthash choice-text
;;                             (list :name mark-name
;;                                   :info mark-info
;;                                   :buffer-exists buffer-exists)
;;                             mark-data)))
;;                my/global-marks)

;;       ;; Sort by last visited time (most recent first)
;;       (setq completion-choices
;;             (sort completion-choices
;;                   (lambda (a b)
;;                     (let ((time-a (plist-get (cdr a) :last-visited))
;;                           (time-b (plist-get (cdr b) :last-visited)))
;;                       (time-less-p time-b time-a)))))

;;       ;; Present completion interface
;;       (let* ((choice-keys (mapcar #'car completion-choices))
;;              (selected (cond
;;                         ;; For ivy users
;;                         ((and (boundp 'ivy-mode) ivy-mode)
;;                          (ivy-read "Jump to mark (recent first): " choice-keys))
;;                         ;; For vertico users
;;                         ((and (boundp 'vertico-mode) vertico-mode)
;;                          (let ((vertico-sort-function nil))
;;                            (completing-read "Jump to mark (recent first): " choice-keys nil t)))
;;                         ;; For helm users
;;                         ((and (boundp 'helm-mode) helm-mode)
;;                          (let ((helm-candidate-sort-fn nil))
;;                            (completing-read "Jump to mark (recent first): " choice-keys nil t)))
;;                         ;; Default completing-read
;;                         (t
;;                          (completing-read "Jump to mark (recent first): " choice-keys nil t)))))

;;         (when selected
;;           (let* ((mark-data-entry (gethash selected mark-data))
;;                  (mark-name (plist-get mark-data-entry :name))
;;                  (mark-info (plist-get mark-data-entry :info))
;;                  (buffer-exists (plist-get mark-data-entry :buffer-exists))
;;                  (target-buffer (plist-get mark-info :buffer))
;;                  (target-pos (plist-get mark-info :position))
;;                  (file-path (plist-get mark-info :file-path)))

;;             (cond
;;              ((not buffer-exists)
;;               ;; Try to reopen the file if buffer is dead
;;               (if (and (stringp file-path) (file-exists-p file-path))
;;                   (progn
;;                     (evil-set-jump)
;;                     (message "evil set jump 1")
;;                     (find-file file-path)
;;                     (goto-char target-pos)
;;                     ;; Update the mark with new buffer
;;                     (plist-put mark-info :buffer (current-buffer))
;;                     (plist-put mark-info :last-visited (current-time))
;;                     (puthash mark-name mark-info my/global-marks)
;;                     (recenter)
;;                     (message "Reopened file and jumped to mark '%s'" mark-name))
;;                 (progn
;;                   (message "Cannot jump to mark '%s': file no longer exists" mark-name)
;;                   (when (y-or-n-p (format "Remove dead mark '%s'? " mark-name))
;;                     (remhash mark-name my/global-marks)
;;                     (message "Removed dead mark '%s'" mark-name)))))
;;              (t
;;               ;; Buffer exists, jump to it
;;               (evil-set-jump)
;;               (message "evil set jump 2")
;;               (switch-to-buffer target-buffer)
;;               (goto-char target-pos)
;;               ;; Update last visited time
;;               (plist-put mark-info :last-visited (current-time))
;;               (puthash mark-name mark-info my/global-marks)
;;               (recenter)
;;               (message "Jumped to mark '%s'" mark-name)))))))))

(defun my/delete-mark ()
  "Delete a global mark."
  (interactive)
  (if (= (hash-table-count my/global-marks) 0)
      (message "No marks to delete")
    
    (let ((mark-names '()))
      ;; Collect all mark names
      (maphash (lambda (mark-name mark-info)
                 (let* ((buffer-name (plist-get mark-info :buffer-name))
                        (line-num (plist-get mark-info :line))
                        (choice-text (format "%s  (%s:%d)" mark-name buffer-name line-num)))
                   (push choice-text mark-names)))
               my/global-marks)
      
      (let* ((selected (completing-read "Delete mark: " (sort mark-names #'string<) nil t))
             (mark-name (car (split-string selected "  "))))
        (when (and selected mark-name)
          (remhash mark-name my/global-marks)
          ;; Update markdown file after deletion
          (my/update-marks-markdown)
          (message "Deleted mark '%s'" mark-name))))))

(defun my/markdown-marks-get-current-mark ()
  "Get the mark name at current markdown section."
  (save-excursion
    (when (re-search-backward "^## \\(.+\\)$" nil t)
      (match-string 1))))

(defun my/markdown-marks-next-mark ()
  "Move to next mark section in markdown."
  (interactive)
  ;; Move to end of current line to avoid matching current line
  (end-of-line)
  (if (re-search-forward "^### " nil t)
      (progn
        (beginning-of-line)
        (recenter-top-bottom 5))
    (progn
      ;; Wrap to beginning and find first mark
      (goto-char (point-min))
      (when (re-search-forward "^### " nil t)
        (beginning-of-line)
        (recenter-top-bottom 5)))))

(defun my/markdown-marks-previous-mark ()
  "Move to previous mark section in markdown."
  (interactive)
  (beginning-of-line)
  (if (re-search-backward "^### " nil t)
      (progn
        (beginning-of-line)
        (recenter-top-bottom 5))
    (progn
      (goto-char (point-max))
      (when (re-search-backward "^### " nil t)
        (beginning-of-line)
        (recenter-top-bottom 5)))))

(defun my/get-project-root-from-markdown ()
  "Extract the project root from the markdown file's PROJECT_ROOT comment."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^<!-- PROJECT_ROOT: \\(.+\\) -->$" nil t)
      (match-string 1))))

(defun my/refresh-markdown-buffer ()
  "Force refresh the markdown buffer content from file."
  (let ((markdown-buffer (get-file-buffer (my/get-project-marks-file))))
    (when markdown-buffer
      (with-current-buffer markdown-buffer
        ;; Force revert without asking - answers "yes" automatically
        (revert-buffer t t t)))))

(defun my/find-mark-by-file-and-line (filename line-num)
  "Find a mark that matches the given filename and line number."
  (let ((found-mark nil))
    (message "DEBUG: Looking for filename=%s line-num=%d" filename line-num)
    (maphash (lambda (mark-name mark-info)
               (let ((file-path (plist-get mark-info :file-path))
                     (mark-line (plist-get mark-info :line)))
                 (message "DEBUG: Checking mark %s: file=%s line=%d" mark-name (when file-path (file-name-nondirectory file-path)) mark-line)
                 (when (and file-path
                           (string-equal filename (file-name-nondirectory file-path))
                           (= line-num mark-line))
                   (message "DEBUG: Found match!")
                   (setq found-mark mark-name))))
             my/global-marks)
    (message "DEBUG: Returning found-mark: %s" found-mark)
    found-mark))

(defun my/markdown-marks-jump-to-mark ()
  "Jump to the mark at current markdown section in the main-right split."
  (interactive)
  (let ((stored-project-root (my/get-project-root-from-markdown)))
    (save-excursion
      ;; First try current line
      (beginning-of-line)
      (message "!!! Ready steady go...")
      (let ((found-header (re-search-forward "^### \\(.+\\):\\([0-9]+\\) \\[\\(.+\\)\\]" (line-end-position) t)))
        ;; If not found on current line, search backwards for nearest ### header
        (unless found-header
          (message "Trying to find header backwards...")
          (beginning-of-line)
          (setq found-header (re-search-backward "^### \\(.+\\):\\([0-9]+\\) \\[\\(.+\\)\\]" nil t)))

        (when found-header
        (let* ((filename (match-string 1))
               (line-num (string-to-number (match-string 2)))
               (mark-name (match-string 3))
               ;; Look up mark in hash table to get full path
               (mark-info (gethash mark-name my/global-marks))
               (full-path (when mark-info (plist-get mark-info :file-path))))

          (if (file-exists-p full-path)
              (progn
                (message "DEBUG: Jumping to %s line %d" full-path line-num)
                ;; Use layout function to show file in main center split
                (my-layout-show-file-main-center full-path line-num)
                ;; Force a recenter to make sure we're at the right position
                (when (get-file-buffer full-path)
                  (with-current-buffer (get-file-buffer full-path)
                    (message "evil jump 1")
                    (goto-line line-num)
                    (recenter)))
                ;; Find and update the timestamp of the corresponding mark
                (let ((mark-name (my/find-mark-by-file-and-line (file-name-nondirectory filename) line-num)))
                  (message "DEBUG: Found mark name: %s" mark-name)
                  (when mark-name
                    (let ((mark-info (gethash mark-name my/global-marks)))
                      (when mark-info
                        (message "DEBUG: Updating timestamp for mark %s" mark-name)
                        (plist-put mark-info :last-visited (current-time))
                        (puthash mark-name mark-info my/global-marks)
                        ;; Refresh the markdown file to reflect the new ordering
                        (message "DEBUG: Refreshing markdown...")
                        (let ((current-markdown-buffer (current-buffer))
                              (target-line (concat "^### " (regexp-quote filename) ":" (number-to-string line-num))))
                          ;; Update markdown file
                          (my/update-marks-markdown)
                          (message "DEBUG: Refreshing markdown buffer only...")
                          ;; Use our dedicated refresh function

                          ;; (my/update-marks-markdown)
                          (my/refresh-markdown-buffer)
                          ;; (my/refresh-markdown-buffer)
                          ;;
                          ;; (with-current-buffer current-markdown-buffer
                          ;;   (when (string-match-p "\\.md$" (buffer-name))  ; Safety check - only modify .md files
                          ;;     (let ((inhibit-read-only t)
                          ;;           (current-pos (point)))

                          ;;       ;; Return to the same position
                          ;;       (goto-char (point-min))
                          ;;       (if (re-search-forward target-line nil t)
                          ;;           (progn
                          ;;             (beginning-of-line)
                          ;;             (recenter-top-bottom 5))
                          ;;         (goto-char current-pos))
                          ;;       ;; Also force window update
                          ;;       )))
                          (message "DEBUG: Markdown refresh complete"))))))
                (message "Jumped to %s:%d in main-right split" filename line-num))
            (message "File not found: %s" full-path))))))
    
    ))

(defun my/markdown-marks-refresh ()
  "Refresh the markdown file and reload it."
  (interactive)
  (my/update-marks-markdown)
  (revert-buffer t t)
  (goto-char (point-min))
  (when (re-search-forward "^### " nil t)
    (beginning-of-line)
    (recenter-top-bottom 5))
  (message "Refreshed marks markdown"))

(defvar my/markdown-marks-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "j") #'my/markdown-marks-next-mark)
    (define-key map (kbd "k") #'my/markdown-marks-previous-mark)
    (define-key map (kbd "s") #'isearch-forward)  ; Execute search with "/"
    (define-key map (kbd "g") #'my/markdown-marks-refresh)
    (define-key map (kbd "q") #'quit-window)
    ;; Arrow key navigation
    (define-key map (kbd "<down>") #'my/markdown-marks-next-mark)
    (define-key map (kbd "<up>") #'my/markdown-marks-previous-mark)
    (define-key map (kbd "<right>") #'my/markdown-marks-jump-to-mark)
    map)
  "Keymap for markdown marks navigation.")

(defun my/apply-marks-markdown-styling ()
  "Apply custom styling specifically for marks markdown buffer."
  (setq-local truncate-lines t)
  ;; Make all headers small
  (face-remap-add-relative 'markdown-header-face-1 :height 0.8)
  (face-remap-add-relative 'markdown-header-face-2 :height 0.7)
  (face-remap-add-relative 'markdown-header-face-3 :background "#372413" :extend t)
  (face-remap-add-relative 'markdown-header-face-4 :height 0.7)
  ;; Make regular text small
  (face-remap-add-relative 'default :height 0.7)
  ;; Make comments small
  (face-remap-add-relative 'markdown-comment-face :height 0.7)
  ;; Hide language keywords (python, elisp, etc.) and brackets
  (face-remap-add-relative 'markdown-language-keyword-face :foreground "#1a1006" :height 0.1)
  (face-remap-add-relative 'markdown-markup-face :foreground "#1a1006" :height 0.1)
  ;; Highlight current line in marks mode
  (hl-line-mode 1)
  (face-remap-add-relative 'hl-line :background "#5a3a15" :foreground "#ffc677" :extend t)
  ;; Keep code blocks normal size (readable)
  (setq-local face-remapping-alist
                (cons '(markdown-code-face . (:height 1.2 :background "#261707" :extend t))
                      face-remapping-alist)))

(define-minor-mode my/markdown-marks-mode
  "Minor mode for navigating marks in markdown view."
  :lighter " MdMarks"
  :keymap my/markdown-marks-mode-map
  (when my/markdown-marks-mode
    ;; Add buffer-local hook to position cursor on line 7 when focused
    (add-hook 'window-selection-change-functions #'my/markdown-marks-focus-hook nil t)
    ;; Apply custom styling for marks markdown
    (my/apply-marks-markdown-styling)
    ;; Force override arrow keys for this buffer in Evil normal mode
    (when (bound-and-true-p evil-mode)
      (evil-local-set-key 'normal (kbd "<down>") #'my/markdown-marks-next-mark)
      (evil-local-set-key 'normal (kbd "<up>") #'my/markdown-marks-previous-mark)
      (evil-local-set-key 'normal (kbd "<right>") #'my/markdown-marks-jump-to-mark)
      (evil-local-set-key 'normal "s" (lambda () (interactive) (execute-kbd-macro "/"))))))

(defun my/markdown-marks-focus-hook (window)
  "Position cursor on line 7 when markdown marks buffer gets focused.
WINDOW is the window that was selected."
  (when (and (eq (current-buffer) (window-buffer (selected-window)))
             my/markdown-marks-mode
             (string-match-p "\\.md$" (buffer-name)))
    (goto-line 7)
    (beginning-of-line)
    (recenter-top-bottom 5)))

;; Evil mode integration for markdown marks - normal mode only
(with-eval-after-load 'evil
  (evil-define-key 'normal my/markdown-marks-mode-map
    "j" #'my/markdown-marks-next-mark
    "k" #'my/markdown-marks-previous-mark
    "s" (lambda () (interactive) (execute-kbd-macro "/"))  ; Execute search with "/"
    "g" #'my/markdown-marks-refresh
    "q" #'quit-window
    ;; Arrow key navigation - override global bindings
    (kbd "<down>") #'my/markdown-marks-next-mark
    (kbd "<up>") #'my/markdown-marks-previous-mark
    (kbd "<right>") #'my/markdown-marks-jump-to-mark)
  
  ;; Make sure we don't override normal j/k movement in insert mode
  (evil-define-key 'insert my/markdown-marks-mode-map
    (kbd "j") nil
    (kbd "k") nil))

(defun my/view-marks-markdown ()
  "Open and view the markdown file with rich marks context in left sidebar."
  (interactive)
  ;; Store jump position from current buffer before switching to marks
  (evil-set-jump)
  (let ((markdown-file (my/get-project-marks-file))
        (current-window (selected-window)))
    (if (file-exists-p markdown-file)
        (progn
          ;; Refresh the markdown file first
          (my/update-marks-markdown)
          ;; Open the file in left sidebar
          (let ((markdown-buffer (find-file-noselect markdown-file)))
            (my-layout-show-in-left-sidebar markdown-buffer)
            ;; Switch to the sidebar window to configure the buffer
            (select-window (my-layout--get-window 'left-sidebar))
            ;; Enable navigation mode
            (my/markdown-marks-mode 1)
            ;; Move to first mark
            (goto-char (point-min))
            (when (re-search-forward "^### " nil t)
              (beginning-of-line)
              (recenter-top-bottom 5))
            ;; Return to original window
            (select-window current-window)
            ))
      (if (= (hash-table-count my/global-marks) 0)
          (message "No marks found. Create some marks first with `my/create-mark'")
        (progn
          ;; Generate the markdown file
          (my/update-marks-markdown)
          ;; Open the file in left sidebar
          (let ((markdown-buffer (find-file-noselect markdown-file)))
            (my-layout-show-in-left-sidebar markdown-buffer)
            ;; Switch to the sidebar window to configure the buffer
            (select-window (my-layout--get-window 'left-sidebar))
            ;; Enable navigation mode
            (my/markdown-marks-mode 1)
            ;; Move to first mark
            (goto-char (point-min))
            (when (re-search-forward "^### " nil t)
              (beginning-of-line)
              (recenter-top-bottom 5))
            ;; Return to original window
            (select-window current-window)
            ))))))

(defvar my/marks-buffer-marks-data nil
  "Store marks data for the marks buffer navigation.")

(defun my/marks-buffer-get-current-mark ()
  "Get the mark name at current line in marks buffer."
  (save-excursion
    (beginning-of-line)
    (when (looking-at "^\\([^ ]+\\)")
      (match-string 1))))

(defun my/marks-buffer-jump-to-mark ()
  "Jump to the mark at current line and close marks buffer."
  (interactive)
  (let ((mark-name (my/marks-buffer-get-current-mark)))
    (when mark-name
      (let ((mark-info (gethash mark-name my/global-marks)))
        (when mark-info
          (quit-window t)  ; Close marks buffer
          (let ((target-buffer (plist-get mark-info :buffer))
                (target-pos (plist-get mark-info :position))
                (file-path (plist-get mark-info :file-path))
                (buffer-exists (and (plist-get mark-info :buffer) 
                                   (buffer-live-p (plist-get mark-info :buffer)))))
            
            (cond
             ((not buffer-exists)
              ;; Try to reopen the file if buffer is dead
              (if (and (stringp file-path) (file-exists-p file-path))
                  (progn
                    (evil-set-jump)
                    (message "evil jump 3")
                    (find-file file-path)
                    (goto-char target-pos)
                    ;; Update the mark with new buffer
                    (plist-put mark-info :buffer (current-buffer))
                    (plist-put mark-info :last-visited (current-time))
                    (puthash mark-name mark-info my/global-marks)
                    (recenter)
                    (message "Reopened file and jumped to mark '%s'" mark-name))
                (message "Cannot jump to mark '%s': file no longer exists" mark-name)))
             (t
              ;; Buffer exists, jump to it
              (evil-set-jump)
              (message "evil jump 4")
              (switch-to-buffer target-buffer)
              (goto-char target-pos)
              ;; Update last visited time
              (plist-put mark-info :last-visited (current-time))
              (puthash mark-name mark-info my/global-marks)
              (recenter)
              (message "Jumped to mark '%s'" mark-name)))))))))

(defun my/marks-buffer-next-mark ()
  "Move to next mark in marks buffer."
  (interactive)
  (forward-line 1)
  ;; Skip non-mark lines (preview, timestamp, empty lines, headers)
  (while (and (not (eobp))
              (or (looking-at "^[ \t]")  ; Lines starting with whitespace
                  (looking-at "^$")      ; Empty lines
                  (looking-at "^Global Marks")  ; Header
                  (looking-at "^=====")        ; Separator
                  (looking-at "^j/k:")))       ; Navigation instructions
    (forward-line 1))
  (when (eobp)
    ;; If we hit end, go to first mark
    (goto-char (point-min))
    (while (and (not (eobp))
                (or (looking-at "^[ \t]")
                    (looking-at "^$")
                    (looking-at "^Global Marks")
                    (looking-at "^=====")
                    (looking-at "^j/k:")))
      (forward-line 1))))

(defun my/marks-buffer-previous-mark ()
  "Move to previous mark in marks buffer."
  (interactive)
  (forward-line -1)
  ;; Skip non-mark lines
  (while (and (not (bobp))
              (or (looking-at "^[ \t]")
                  (looking-at "^$")
                  (looking-at "^Global Marks")
                  (looking-at "^=====")
                  (looking-at "^j/k:")))
    (forward-line -1))
  (when (bobp)
    ;; If we hit beginning, go to last mark
    (goto-char (point-max))
    (while (and (not (bobp))
                (or (looking-at "^[ \t]")
                    (looking-at "^$")))
      (forward-line -1))))

(defun my/marks-buffer-preview-mark ()
  "Preview the mark at current line in another window."
  (interactive)
  (let ((mark-name (my/marks-buffer-get-current-mark)))
    (when mark-name
      (let ((mark-info (gethash mark-name my/global-marks)))
        (when mark-info
          (let ((target-buffer (plist-get mark-info :buffer))
                (target-pos (plist-get mark-info :position))
                (file-path (plist-get mark-info :file-path))
                (buffer-exists (and (plist-get mark-info :buffer) 
                                   (buffer-live-p (plist-get mark-info :buffer)))))
            
            (cond
             ((and buffer-exists target-buffer)
              ;; Buffer exists, show it in other window
              (with-selected-window (other-window-for-scrolling)
                (switch-to-buffer target-buffer)
                (goto-char target-pos)
                (recenter)))
             ((and (stringp file-path) (file-exists-p file-path))
              ;; Buffer doesn't exist, open file in other window
              (with-selected-window (other-window-for-scrolling)
                (find-file file-path)
                (goto-char target-pos)
                (recenter)))
             (t
              (message "Cannot preview mark: buffer/file not available")))))))))

;; (defvar my/marks-buffer-mode-map
;;   (let ((map (make-sparse-keymap)))
;;     (define-key map (kbd "s") #'my/marks-buffer-jump-to-mark)
;;     (define-key map (kbd "j") #'my/marks-buffer-next-mark)
;;     (define-key map (kbd "k") #'my/marks-buffer-previous-mark)
;;     (define-key map (kbd "p") #'my/marks-buffer-preview-mark)
;;     (define-key map (kbd "q") #'quit-window)
;;     (define-key map (kbd "g") #'my/list-marks)  ; Refresh
;;     map)
;;   "Keymap for marks buffer navigation.")

;; (define-minor-mode my/marks-buffer-mode
;;   "Minor mode for navigating marks buffer."
;;   :lighter " Marks"
;;   :keymap my/marks-buffer-mode-map)

;; Evil mode integration for marks buffer
;; (with-eval-after-load 'evil
;;   (evil-define-key 'normal my/marks-buffer-mode-map
;;     "s" #'my/marks-buffer-jump-to-mark
;;     "j" #'my/marks-buffer-next-mark
;;     "k" #'my/marks-buffer-previous-mark
;;     "p" #'my/marks-buffer-preview-mark
;;     "q" #'quit-window
;;     "g" #'my/list-marks))

(defun my/list-marks ()
  "List all global marks in a navigable buffer."
  (interactive)
  (if (= (hash-table-count my/global-marks) 0)
      (message "No marks found")
    
    (let ((marks-info '()))
      ;; Collect all marks
      (maphash (lambda (mark-name mark-info)
                 (push (list mark-name mark-info) marks-info))
               my/global-marks)
      
      ;; Sort by last visited time
      (setq marks-info 
            (sort marks-info 
                  (lambda (a b)
                    (let ((time-a (plist-get (cadr a) :last-visited))
                          (time-b (plist-get (cadr b) :last-visited)))
                      (time-less-p time-b time-a)))))
      
      ;; Create and populate marks buffer
      (with-current-buffer (get-buffer-create "*Global Marks*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize "Global Marks (sorted by last visited)\n" 'face 'font-lock-keyword-face))
          (insert (propertize "=========================================\n\n" 'face 'font-lock-comment-face))
          (insert (propertize "j/k: navigate  s: jump  p: preview  q: quit  g: refresh\n\n" 'face 'font-lock-doc-face))
          
          (dolist (mark-entry marks-info)
            (let* ((mark-name (car mark-entry))
                   (mark-info (cadr mark-entry))
                   (buffer-name (plist-get mark-info :buffer-name))
                   (file-path (plist-get mark-info :file-path))
                   (line-num (plist-get mark-info :line))
                   (preview (plist-get mark-info :preview))
                   (last-visited (plist-get mark-info :last-visited))
                   (buffer-exists (buffer-live-p (plist-get mark-info :buffer))))
              
              (insert (format "%s %s %s:%d\n" 
                             (propertize mark-name 'face 'font-lock-constant-face)
                             (if buffer-exists 
                                 (propertize "✓" 'face 'success)
                               (propertize "✗" 'face 'error))
                             (propertize (if file-path (file-name-nondirectory file-path) buffer-name) 
                                        'face 'font-lock-function-name-face)
                             line-num))
              (insert (format "    %s\n" 
                             (propertize preview 'face 'font-lock-comment-face)))
              (insert (format "    %s\n\n" 
                             (propertize (format-time-string "Last visited: %Y-%m-%d %H:%M:%S" last-visited)
                                        'face 'font-lock-doc-face)))))
          
          ;; Enable our custom mode and position cursor
          (my/marks-buffer-mode 1)
          (setq buffer-read-only t)
          (goto-char (point-min))
          ;; Move to first actual mark
          (my/marks-buffer-next-mark)))
      
      ;; Display buffer and select it
      (pop-to-buffer "*Global Marks*"))))

;;; Mark Auto-Maintenance System

(defvar my/mark-auto-update-enabled t
  "Enable automatic mark position updates on file save.")

(defvar my/mark-removal-notification t
  "Show notification when marks are removed.")

(defvar my/file-marks-cache (make-hash-table :test 'equal)
  "Cache mapping file paths to lists of mark names for performance.")

(defvar my/auto-updating-marks nil
  "Flag to prevent focus hook during automatic mark updates.")

(defun my/get-marks-for-file (file-path)
  "Get all marks that belong to FILE-PATH."
  (let ((marks-list '()))
    (maphash (lambda (mark-name mark-info)
               (when (string-equal file-path (plist-get mark-info :file-path))
                 (push mark-name marks-list)))
             my/global-marks)
    marks-list))

(defun my/find-line-by-content (content &optional original-line)
  "Find line number(s) containing CONTENT. Prefer closest to ORIGINAL-LINE."
  (let ((matches '())
        (line-num 1))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line-content (string-trim 
                            (buffer-substring-no-properties 
                             (line-beginning-position) 
                             (line-end-position)))))
          (when (string-equal content line-content)
            (push line-num matches)))
        (forward-line 1)
        (setq line-num (1+ line-num))))
    
    (cond
     ((null matches) nil)
     ((= 1 (length matches)) (car matches))
     (original-line
      ;; Multiple matches - return closest to original line
      (car (sort matches 
                 (lambda (a b) 
                   (< (abs (- a original-line))
                      (abs (- b original-line)))))))
     (t (car matches)))))

(defun my/update-mark-position (mark-name new-line)
  "Update MARK-NAME to NEW-LINE position."
  (let ((mark-info (gethash mark-name my/global-marks)))
    (when mark-info
      (let* ((file-path (plist-get mark-info :file-path))
             (buffer (find-file-noselect file-path)))
        (with-current-buffer buffer
          (save-excursion
            (goto-line new-line)
            (let ((new-pos (point))
                  (new-preview (string-trim 
                               (buffer-substring-no-properties 
                                (line-beginning-position) 
                                (line-end-position)))))
              ;; Update mark info (don't update last-visited during auto-maintenance)
              (plist-put mark-info :line new-line)
              (plist-put mark-info :position new-pos)
              (plist-put mark-info :preview new-preview)
              (puthash mark-name mark-info my/global-marks))))))))

(defun my/remove-obsolete-mark (mark-name)
  "Remove MARK-NAME that no longer has valid content."
  (when my/mark-removal-notification
    (message "Removed obsolete mark: %s" mark-name))
  (remhash mark-name my/global-marks))

(defun my/update-marks-after-save ()
  "Update mark positions after file save."
  (when (and my/mark-auto-update-enabled 
             (buffer-file-name))
    (let* ((file-path (buffer-file-name))
           (marks-in-file (my/get-marks-for-file file-path)))
      
      (when marks-in-file
        (let ((updated-count 0)
              (removed-count 0))
          
          (dolist (mark-name marks-in-file)
            (let* ((mark-info (gethash mark-name my/global-marks))
                   (original-line (plist-get mark-info :line))
                   (preview-content (plist-get mark-info :preview))
                   (new-line (my/find-line-by-content preview-content original-line)))
              
              (cond
               ((and new-line (= new-line original-line))
                ;; Mark position unchanged - do nothing
                nil)
               (new-line
                ;; Content found at different line - update
                (my/update-mark-position mark-name new-line)
                (setq updated-count (1+ updated-count)))
               (t
                ;; Content not found - remove mark
                (my/remove-obsolete-mark mark-name)
                (setq removed-count (1+ removed-count))))))
          
          ;; Show summary if changes were made
          (when (or (> updated-count 0) (> removed-count 0))
            (my/update-marks-markdown)
            (message "Marks updated: %d moved, %d removed" updated-count removed-count)))))))

;; Hook into file saves
(add-hook 'after-save-hook #'my/update-marks-after-save)

(defun my/jump-to-most-recent-mark ()
  "Jump to the most recently visited mark."
  (interactive)
  (if (= (hash-table-count my/global-marks) 0)
      (message "No marks found. Create some with `my/create-mark'")
    
    (let ((most-recent-mark nil)
          (most-recent-time nil))
      
      ;; Find the most recently visited mark
      (maphash (lambda (mark-name mark-info)
                 (let ((last-visited (plist-get mark-info :last-visited)))
                   (when (or (null most-recent-time)
                            (time-less-p most-recent-time last-visited))
                     (setq most-recent-mark mark-name)
                     (setq most-recent-time last-visited))))
               my/global-marks)
      
      (when most-recent-mark
        (evil-set-jump)
        (let* ((mark-info (gethash most-recent-mark my/global-marks))
               (target-buffer (plist-get mark-info :buffer))
               (target-pos (plist-get mark-info :position))
               (file-path (plist-get mark-info :file-path))
               (buffer-exists (and target-buffer (buffer-live-p target-buffer))))
          
          (cond
           ((not buffer-exists)
            ;; Try to reopen the file if buffer is dead
            (if (and (stringp file-path) (file-exists-p file-path))
                (progn
                  (evil-set-jump)
                  (find-file file-path)
                  (goto-char target-pos)
                  ;; Update the mark with new buffer
                  (plist-put mark-info :buffer (current-buffer))
                  (plist-put mark-info :last-visited (current-time))
                  (puthash most-recent-mark mark-info my/global-marks)
                  (recenter)
                  (message "Jumped to most recent mark '%s'" most-recent-mark))
              (message "Cannot jump to mark '%s': file no longer exists" most-recent-mark)))
           (t
            ;; Buffer exists, jump to it
            (evil-set-jump)
            (switch-to-buffer target-buffer)
            (goto-char target-pos)
            ;; Update last visited time
            (plist-put mark-info :last-visited (current-time))
            (puthash most-recent-mark mark-info my/global-marks)
            (recenter)
            (message "Jumped to most recent mark '%s'" most-recent-mark))))))))

;; Keybindings for custom marks system
(map! :leader
      (:prefix ("j" . "jump/marks")
       :desc "Jump to recent mark" "j" #'my/jump-to-most-recent-mark
       :desc "Create mark" "m" #'my/create-mark
       :desc "Delete mark" "d" #'my/delete-mark
       :desc "List marks" "l" #'my/goto-jumps-selection
       :desc "View markdown" "v" #'my/view-marks-markdown))

;; Also bind to convenient keys
(map! :n "gm" #'my/create-mark)

;; Global C-d binding for creating marks
(global-set-key (kbd "C-d") #'my/create-mark)

;; Also ensure C-d works in Evil states
(after! evil
  (define-key evil-insert-state-map (kbd "C-d") #'my/create-mark)
  (define-key evil-normal-state-map (kbd "C-d") #'my/create-mark)
  (define-key evil-visual-state-map (kbd "C-d") #'my/create-mark))

(provide 'my-navigation)

;;; my-navigation.el ends here
