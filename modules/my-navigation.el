;;; modules/my-navigation.el --- Navigation utilities -*- lexical-binding: t; -*-

;;; Commentary:
;; UP/DOWN arrows jump 10 lines at a time
;; LEFT/RIGHT arrows navigate between functions

;;; Code:

(defun my/jump-up ()
  "Jump up 10 lines."
  (interactive)
  (forward-line -10))

(defun my/jump-down ()
  "Jump down 10 lines."
  (interactive)
  (forward-line 10))

(defun my/next-defun ()
  "Move to the beginning of the next function definition.
Uses `beginning-of-defun' with a negative argument to move forward."
  (interactive)
  (beginning-of-defun -1))

;; Bind arrow keys for normal and visual modes
(map! :n "<up>" #'my/jump-up
      :n "<down>" #'my/jump-down
      :v "<up>" #'my/jump-up
      :v "<down>" #'my/jump-down
      ;; Function navigation with left/right arrows
      :n "<left>" #'beginning-of-defun    ; Previous function
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

;; Then bind our function globally
(map! :g "C-<tab>" #'switch-to-buffer
      :n "C-<tab>" #'switch-to-buffer
      :i "C-<tab>" #'switch-to-buffer
      :v "C-<tab>" #'switch-to-buffer)

;; Force override with global-set-key as backup
(with-eval-after-load 'yasnippet
  (global-set-key (kbd "C-<tab>") #'switch-to-buffer))

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

(defun my/create-mark (&optional name)
  "Create a global mark at current position.
If NAME is provided, use it as mark name. Otherwise, prompt for name.
If called with prefix arg, auto-generate a name."
  (interactive)
  (let* ((auto-name current-prefix-arg)
         (mark-name (cond
                     (auto-name 
                      (setq my/marks-counter (1+ my/marks-counter))
                      (format "auto-%d" my/marks-counter))
                     (name name)
                     (t (read-string "Mark name: " 
                                     (format "mark-%d" (1+ my/marks-counter))))))
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
    
    (message "Created mark '%s' at %s:%d" mark-name (buffer-name) line-num)))

(defun my/jump-to-mark ()
  "Show all global marks with preview and jump to selected one."
  (interactive)
  (if (= (hash-table-count my/global-marks) 0)
      (message "No marks found. Create some with `my/create-mark'")
    
    (let ((completion-choices '())
          (mark-data (make-hash-table :test 'equal)))
      
      ;; Collect all marks and prepare for sorting
      (maphash (lambda (mark-name mark-info)
                 (let* ((buffer (plist-get mark-info :buffer))
                        (buffer-name (plist-get mark-info :buffer-name))
                        (file-path (plist-get mark-info :file-path))
                        (line-num (plist-get mark-info :line))
                        (preview (plist-get mark-info :preview))
                        (last-visited (plist-get mark-info :last-visited))
                        (is-current-buffer (eq buffer (current-buffer)))
                        ;; Check if buffer still exists
                        (buffer-exists (and buffer (buffer-live-p buffer)))
                        (choice-text (format "%s %s %s:%d  %s" 
                                           (propertize mark-name 'face 'font-lock-constant-face)
                                           (if is-current-buffer 
                                               (propertize "[current]" 'face 'success)
                                             (if buffer-exists "" 
                                               (propertize "[dead]" 'face 'error)))
                                           (propertize (file-name-nondirectory file-path) 
                                                      'face 'font-lock-function-name-face)
                                           line-num
                                           (propertize preview 'face 'font-lock-comment-face))))
                   
                   (push (cons choice-text 
                               (list :name mark-name 
                                     :info mark-info 
                                     :last-visited last-visited
                                     :buffer-exists buffer-exists))
                         completion-choices)
                   (puthash choice-text 
                            (list :name mark-name 
                                  :info mark-info 
                                  :buffer-exists buffer-exists)
                            mark-data)))
               my/global-marks)
      
      ;; Sort by last visited time (most recent first)
      (setq completion-choices 
            (sort completion-choices 
                  (lambda (a b)
                    (let ((time-a (plist-get (cdr a) :last-visited))
                          (time-b (plist-get (cdr b) :last-visited)))
                      (time-less-p time-b time-a)))))
      
      ;; Present completion interface
      (let* ((choice-keys (mapcar #'car completion-choices))
             (selected (cond
                        ;; For ivy users
                        ((and (boundp 'ivy-mode) ivy-mode)
                         (ivy-read "Jump to mark (recent first): " choice-keys))
                        ;; For vertico users  
                        ((and (boundp 'vertico-mode) vertico-mode)
                         (let ((vertico-sort-function nil))
                           (completing-read "Jump to mark (recent first): " choice-keys nil t)))
                        ;; For helm users
                        ((and (boundp 'helm-mode) helm-mode)
                         (let ((helm-candidate-sort-fn nil))
                           (completing-read "Jump to mark (recent first): " choice-keys nil t)))
                        ;; Default completing-read
                        (t
                         (completing-read "Jump to mark (recent first): " choice-keys nil t)))))
        
        (when selected
          (let* ((mark-data-entry (gethash selected mark-data))
                 (mark-name (plist-get mark-data-entry :name))
                 (mark-info (plist-get mark-data-entry :info))
                 (buffer-exists (plist-get mark-data-entry :buffer-exists))
                 (target-buffer (plist-get mark-info :buffer))
                 (target-pos (plist-get mark-info :position))
                 (file-path (plist-get mark-info :file-path)))
            
            (cond
             ((not buffer-exists)
              ;; Try to reopen the file if buffer is dead
              (if (and (stringp file-path) (file-exists-p file-path))
                  (progn
                    (find-file file-path)
                    (goto-char target-pos)
                    ;; Update the mark with new buffer
                    (plist-put mark-info :buffer (current-buffer))
                    (plist-put mark-info :last-visited (current-time))
                    (puthash mark-name mark-info my/global-marks)
                    (recenter)
                    (message "Reopened file and jumped to mark '%s'" mark-name))
                (progn
                  (message "Cannot jump to mark '%s': file no longer exists" mark-name)
                  (when (y-or-n-p (format "Remove dead mark '%s'? " mark-name))
                    (remhash mark-name my/global-marks)
                    (message "Removed dead mark '%s'" mark-name)))))
             (t
              ;; Buffer exists, jump to it
              (switch-to-buffer target-buffer)
              (goto-char target-pos)
              ;; Update last visited time
              (plist-put mark-info :last-visited (current-time))
              (puthash mark-name mark-info my/global-marks)
              (recenter)
              (message "Jumped to mark '%s'" mark-name)))))))))

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
          (message "Deleted mark '%s'" mark-name))))))

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
  ;; Skip non-mark lines (preview, timestamp, empty lines)
  (while (and (not (eobp))
              (or (looking-at "^[ \t]")  ; Lines starting with whitespace
                  (looking-at "^$")))    ; Empty lines
    (forward-line 1))
  (when (eobp)
    ;; If we hit end, go to first mark
    (goto-char (point-min))
    (while (and (not (eobp))
                (or (looking-at "^[ \t]")
                    (looking-at "^$")
                    (looking-at "^Global Marks")
                    (looking-at "^=====")))
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
                  (looking-at "^=====")))
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

(defvar my/marks-buffer-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'my/marks-buffer-jump-to-mark)
    (define-key map (kbd "j") #'my/marks-buffer-next-mark)
    (define-key map (kbd "k") #'my/marks-buffer-previous-mark)
    (define-key map (kbd "p") #'my/marks-buffer-preview-mark)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "g") #'my/list-marks)  ; Refresh
    map)
  "Keymap for marks buffer navigation.")

(define-minor-mode my/marks-buffer-mode
  "Minor mode for navigating marks buffer."
  :lighter " Marks"
  :keymap my/marks-buffer-mode-map)

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
          (insert (propertize "j/k: navigate  RET: jump  p: preview  q: quit  g: refresh\n\n" 'face 'font-lock-doc-face))
          
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
                             (propertize (file-name-nondirectory file-path) 
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

;; Keybindings for custom marks system
(map! :leader
      (:prefix ("j" . "jump/marks")
       :desc "Create mark" "m" #'my/create-mark
       :desc "Jump to mark" "j" #'my/jump-to-mark
       :desc "Delete mark" "d" #'my/delete-mark
       :desc "List marks" "l" #'my/list-marks))

;; Also bind to convenient keys
(map! :n "gm" #'my/create-mark
      :n "gj" #'my/jump-to-mark)

(provide 'my-navigation)

;;; my-navigation.el ends here
