;;; my-super-jumps.el --- Project-specific smart jump navigation with ring buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2024

;; Author: Your Name
;; Keywords: evil, jumps, navigation, project
;; Version: 1.0.0

;;; Commentary:

;; This module provides project-specific smart jump navigation with:
;; - Ring structure to keep max N jump points per project
;; - Ability to jump back and forward within project context
;; - Most recent usage order maintenance
;; - Async timer to reorder jumps after navigation settles
;; - Smart jump registration for file changes or significant line differences

;;; Code:

(require 'evil)
(require 'projectile)

;;; Customization

(defgroup my-super-jumps nil
  "Project-specific smart jump navigation."
  :group 'navigation
  :prefix "my-super-jumps-")

(defcustom my-super-jumps-max-length 100
  "Maximum number of jumps to keep in the ring per project."
  :type 'integer
  :group 'my-super-jumps)

(defcustom my-super-jumps-line-threshold 10
  "Minimum line difference to register a jump within the same file."
  :type 'integer
  :group 'my-super-jumps)

(defcustom my-super-jumps-reorder-delay 2
  "Delay in seconds before reordering jump after navigation."
  :type 'float
  :group 'my-super-jumps)

(defcustom my-super-jumps-async-settle-delay 1.5
  "Delay in seconds before registering async buffer jumps after they stop updating."
  :type 'float
  :group 'my-super-jumps)

;;; Internal variables

(defvar my-super-jumps--project-rings (make-hash-table :test 'equal)
  "Hash table mapping project roots to jump rings.")

(defvar my-super-jumps--current-index nil
  "Current index in the jump ring for active project.")

(defvar my-super-jumps--reorder-timer nil
  "Timer for delayed jump reordering.")

(defvar my-super-jumps--last-jump-time nil
  "Time of last jump navigation.")

(defvar my-super-jumps--jump-intention nil
  "Flag indicating that we intend to perform a jump and should register current position.")

(defvar my-super-jumps--async-buffers (make-hash-table :test 'equal)
  "Hash table mapping buffer IDs to their tracking data.")

(defvar my-super-jumps--async-timers (make-hash-table :test 'equal)
  "Hash table mapping buffer IDs to their settle timers.")

;;; Core data structures

(cl-defstruct my-super-jumps-entry
  "A single jump entry."
  file        ; File path
  position    ; Buffer position (marker or integer)
  line        ; Line number
  column      ; Column number
  timestamp   ; When this jump was created/accessed
  transient)  ; If non-nil, this is a transient jump (cleared on cross-buffer jumps)

;;; Utility functions

(defun my-super-jumps--get-project-root ()
  "Get the current project root, or current directory if not in a project."
  (or (when (bound-and-true-p projectile-mode)
        (ignore-errors (projectile-project-root)))
      default-directory))

(defun my-super-jumps--get-project-ring ()
  "Get or create the jump ring for the current project."
  (let* ((project-root (my-super-jumps--get-project-root))
         (ring (gethash project-root my-super-jumps--project-rings)))
    (unless ring
      (setq ring (make-ring my-super-jumps-max-length))
      (puthash project-root ring my-super-jumps--project-rings))
    ring))

(defun my-super-jumps--create-entry (&optional transient)
  "Create a jump entry for the current position.
If TRANSIENT is non-nil, mark this as a transient jump."
  (when-let ((file (buffer-file-name)))
    (make-my-super-jumps-entry
     :file (expand-file-name file)  ; Use full absolute path
     :position (point-marker)
     :line (line-number-at-pos)
     :column (current-column)
     :timestamp (float-time)
     :transient transient)))

(defun my-super-jumps--entry-equal-p (entry1 entry2)
  "Check if two jump entries represent the same location."
  (and entry1 entry2
       (equal (my-super-jumps-entry-file entry1)
              (my-super-jumps-entry-file entry2))
       (= (my-super-jumps-entry-line entry1)
          (my-super-jumps-entry-line entry2))))

(defun my-super-jumps--should-register-jump-p ()
  "Determine if current position should be registered as a jump."
  (and my-super-jumps--jump-intention  ; Only register if we intended to jump
       (let* ((ring (my-super-jumps--get-project-ring))
              (current-file (buffer-file-name))
              (current-line (line-number-at-pos)))
         
         (cond
          ;; Always register if ring is empty
          ((ring-empty-p ring) t)
          
          ;; Don't register if we're in a buffer without a file
          ((not current-file) nil)
          
          ;; Check against the most recent jump
          (t
           (let* ((last-entry (ring-ref ring 0))
                  (last-file (my-super-jumps-entry-file last-entry))
                  (last-line (my-super-jumps-entry-line last-entry))
                  (current-file-full (expand-file-name current-file)))
             
             (cond
              ;; Different file (using full paths) - always register
              ((not (equal current-file-full last-file)) t)
              
              ;; Same file - check line distance
              ((>= (abs (- current-line last-line)) 
                   my-super-jumps-line-threshold) t)
              
              ;; Too close - don't register
              (t nil))))))))

;;; Ring management

(defun my-super-jumps--add-jump (entry)
  "Add ENTRY to the current project's jump ring.
Don't replace solid jumps with transient ones at the same location."
  (let ((ring (my-super-jumps--get-project-ring))
        (found nil)
        (i 0))
    ;; Remove any existing entry for the same location
    (while (and (< i (ring-length ring)) (not found))
      (when (my-super-jumps--entry-equal-p entry (ring-ref ring i))
        (let ((existing (ring-ref ring i)))
          (if (and (my-super-jumps-entry-transient entry)
                   (not (my-super-jumps-entry-transient existing)))
              ;; New entry is transient but existing is solid - keep the solid one, skip adding
              (setq found 'keep-existing)
            ;; Otherwise remove the old one (will be replaced)
            (ring-remove ring i)
            (setq found t))))
      (unless found
        (setq i (1+ i))))

    ;; Only add new entry if we're not keeping an existing solid jump
    (unless (eq found 'keep-existing)
      (ring-insert ring entry)
      (setq my-super-jumps--current-index 0))))

(defun my-super-jumps--move-to-front (index)
  "Move the jump at INDEX to the front of the ring."
  (let ((ring (my-super-jumps--get-project-ring)))
    (when (and (>= index 0) (< index (ring-length ring)))
      (let ((entry (ring-ref ring index)))
        ;; Remove from current position
        (ring-remove ring index)
        ;; Insert at front
        (ring-insert ring entry)
        (setq my-super-jumps--current-index 0)))))

(defun my-super-jumps--clear-transient-jumps ()
  "Remove all transient jumps from the current project's ring."
  (let* ((ring (my-super-jumps--get-project-ring))
         (len (ring-length ring))
         (i 0)
         (removed 0))
    ;; Iterate backwards to safely remove elements
    (while (< i len)
      (let ((entry (ring-ref ring i)))
        (if (my-super-jumps-entry-transient entry)
            (progn
              (ring-remove ring i)
              (setq len (1- len))
              (setq removed (1+ removed)))
          (setq i (1+ i)))))
    (when (> removed 0)
      (message "Cleared %d transient jump(s)" removed)
      ;; Reset index if it's now out of bounds
      (when (and my-super-jumps--current-index
                 (>= my-super-jumps--current-index (ring-length ring)))
        (setq my-super-jumps--current-index
              (max 0 (1- (ring-length ring))))))))

(defun my-super-jumps--add-transient-jump ()
  "Add current position as a transient jump."
  (when (buffer-file-name)
    (let ((entry (my-super-jumps--create-entry t)))  ; t = transient
      (when entry
        (my-super-jumps--add-jump entry)
        (message "Registered transient jump: %s:%d"
                 (file-name-nondirectory (my-super-jumps-entry-file entry))
                 (my-super-jumps-entry-line entry))))))

;;; Navigation functions

(defun my-super-jumps--goto-entry (entry)
  "Navigate to the location specified by ENTRY."
  (when entry
    (let ((file (my-super-jumps-entry-file entry))
          (position (my-super-jumps-entry-position entry))
          (line (my-super-jumps-entry-line entry)))

      ;; Open file if different from current
      (unless (equal file (buffer-file-name))
        (find-file file))

      ;; Go to position - prefer marker, fallback to line number if position is just a line number
      (cond
       ((and (markerp position) (marker-buffer position)
             (eq (marker-buffer position) (current-buffer)))
        (goto-char (marker-position position)))
       ((and (numberp position) (> position (point-max)))
        ;; Position seems invalid (larger than buffer), use line number
        (goto-line line))
       ((numberp position)
        (goto-char position))
       (t
        ;; Fallback to line number
        (goto-line line)))

      ;; Update stale line number from actual position after navigation
      (setf (my-super-jumps-entry-line entry) (line-number-at-pos))
      (setf (my-super-jumps-entry-column entry) (current-column))
      ;; Update timestamp
      (setf (my-super-jumps-entry-timestamp entry) (float-time)))))

(defun my-super-jumps--schedule-reorder ()
  "Schedule reordering of jumps after navigation settles."
  (when my-super-jumps--reorder-timer
    (cancel-timer my-super-jumps--reorder-timer))
  
  (setq my-super-jumps--reorder-timer
        (run-with-timer my-super-jumps-reorder-delay nil
                        (lambda ()
                          (when my-super-jumps--current-index
                            (my-super-jumps--move-to-front my-super-jumps--current-index)
                            (message "Moved jump to front of ring"))
                          (setq my-super-jumps--reorder-timer nil)))))

;;; Async buffer tracking

(defun my-super-jumps--cancel-async-timer (buffer-id)
  "Cancel the async timer for BUFFER-ID if it exists."
  (when-let ((timer (gethash buffer-id my-super-jumps--async-timers)))
    (cancel-timer timer)
    (remhash buffer-id my-super-jumps--async-timers)))

(defun my-super-jumps--schedule-async-register (buffer-id)
  "Schedule async jump registration for BUFFER-ID after settle delay."
  ;; Cancel any existing timer for this buffer
  (my-super-jumps--cancel-async-timer buffer-id)
  
  ;; Create new timer
  (let ((timer (run-with-timer my-super-jumps-async-settle-delay nil
                               (lambda ()
                                 (my-super-jumps--process-async-buffer buffer-id)))))
    (puthash buffer-id timer my-super-jumps--async-timers)))

(defun my-super-jumps--process-async-buffer (buffer-id)
  "Process the async buffer for BUFFER-ID and register the jump.
Only registers if the async buffer file matches current file."
  (when-let ((buffer-data (gethash buffer-id my-super-jumps--async-buffers)))
    (let ((async-file (plist-get buffer-data :file))
          (line (plist-get buffer-data :line))
          (column (plist-get buffer-data :column))
          (transient (plist-get buffer-data :transient))
          (current-file (buffer-file-name)))

      ;; Only register if current file matches the async buffer file
      (if (and current-file (string-equal async-file current-file))
          (progn
            ;; Register the jump directly with transient flag
            (let ((buffer (find-file-noselect async-file)))
              (with-current-buffer buffer
                (save-excursion
                  (goto-char (point-min))
                  (forward-line (1- line))
                  (when column (move-to-column column))
                  (let ((entry (make-my-super-jumps-entry
                                :file (expand-file-name async-file)
                                :position (point-marker)
                                :line line
                                :column (or column (current-column))
                                :timestamp (float-time)
                                :transient transient)))
                    (my-super-jumps--add-jump entry)
                    (message "Async %s jump registered: %s:%d (ID: %s)"
                             (if transient "transient" "solid")
                             (file-name-nondirectory async-file) line buffer-id))))))
        (message "Skipped async jump: file mismatch (current: %s, async: %s, ID: %s)"
                 (if current-file (file-name-nondirectory current-file) "none")
                 (file-name-nondirectory async-file)
                 buffer-id))

      ;; Cleanup regardless of whether we registered
      (remhash buffer-id my-super-jumps--async-buffers)
      (remhash buffer-id my-super-jumps--async-timers))))

(defun my-super-jumps--update-async-buffer (buffer-id file line column &optional transient)
  "Update the async buffer BUFFER-ID with current position data.
If TRANSIENT is non-nil, the resulting jump will be transient."
  (puthash buffer-id
           (list :file file
                 :line line
                 :column column
                 :timestamp (float-time)
                 :transient transient)
           my-super-jumps--async-buffers)

  ;; Reschedule the timer
  (my-super-jumps--schedule-async-register buffer-id))

;;; Public API

;;;###autoload
(defun my-super-jumps-mark-intention ()
  "Mark that we intend to perform a jump, enabling jump registration."
  (interactive)
  (setq my-super-jumps--jump-intention t))

;;;###autoload
(defun my-super-jumps-clear-intention ()
  "Clear jump intention flag."
  (interactive)
  (setq my-super-jumps--jump-intention nil))

;;;###autoload
(defun my-super-jumps-register (&optional file line column)
  "Register position as a jump if it meets the criteria.
If FILE, LINE, and COLUMN are provided, register that position.
Otherwise, register current position."
  (interactive)
  (when (my-super-jumps--should-register-jump-p)
    (let ((entry (if file
                     ;; For remote positions, calculate actual buffer position
                     (let ((buffer (find-file-noselect file)))
                       (with-current-buffer buffer
                         (save-excursion
                           (goto-line line)
                           (when column (move-to-column column))
                           (make-my-super-jumps-entry
                            :file (expand-file-name file)
                            :position (point-marker)  ; Use actual position, not line number
                            :line line
                            :column (or column (current-column))
                            :timestamp (float-time)))))
                   (my-super-jumps--create-entry))))
      (when entry
        (my-super-jumps--add-jump entry)
        (message "Registered jump: %s:%d"
                 (file-name-nondirectory (my-super-jumps-entry-file entry))
                 (my-super-jumps-entry-line entry)))))
  ;; Clear intention after attempting to register
  (setq my-super-jumps--jump-intention nil))

(defun my-super-jumps--current-matches-entry-p (entry &optional exact)
  "Check if current position matches ENTRY.
If EXACT is non-nil, require exact line match (or marker match).
Otherwise, match if same file and within `my-super-jumps-line-threshold'."
  (and entry
       (buffer-file-name)
       (equal (expand-file-name (buffer-file-name))
              (my-super-jumps-entry-file entry))
       (let ((pos (my-super-jumps-entry-position entry)))
         (if exact
             ;; For exact match: use marker if available (immune to line drift),
             ;; fall back to line number comparison
             (or (and (markerp pos)
                      (marker-buffer pos)
                      (eq (marker-buffer pos) (current-buffer))
                      (= (point) (marker-position pos)))
                 (= (line-number-at-pos) (my-super-jumps-entry-line entry)))
           (< (abs (- (line-number-at-pos) (my-super-jumps-entry-line entry)))
              my-super-jumps-line-threshold)))))

;;;###autoload
(defun my-super-jumps-backward ()
  "Jump backward in the project-specific jump ring.
If current position matches the first entry, jump to second.
Otherwise, jump to the first entry."
  (interactive)
  (let* ((ring (my-super-jumps--get-project-ring))
         (ring-length (ring-length ring)))

    (cond
     ((ring-empty-p ring)
      (message "No jumps in ring for this project"))

     ((= ring-length 1)
      (let ((entry (ring-ref ring 0)))
        (if (my-super-jumps--current-matches-entry-p entry)
            (message "Already at only jump in ring")
          (my-super-jumps--goto-entry entry)
          (setq my-super-jumps--current-index 0)
          (message "Jump backward (1/1): %s:%d"
                   (file-name-nondirectory (my-super-jumps-entry-file entry))
                   (my-super-jumps-entry-line entry)))))

     (t
      ;; Check if we're actually still navigating (current pos EXACTLY matches indexed entry)
      ;; Use exact match so moving even a little resets navigation state
      (let ((actually-navigating
             (and my-super-jumps--current-index
                  (< my-super-jumps--current-index ring-length)
                  (my-super-jumps--current-matches-entry-p
                   (ring-ref ring my-super-jumps--current-index) t))))  ; t = exact match

        ;; If we moved away from the indexed entry, reset navigation state
        (unless actually-navigating
          (setq my-super-jumps--current-index nil))

        ;; Determine target index
        (let* ((first-entry (ring-ref ring 0))
               ;; Use EXACT match to decide if we should skip first entry
               ;; If we're exactly at first entry, skip to second
               ;; If we're close but not exact, go to first entry
               (current-exactly-at-first (my-super-jumps--current-matches-entry-p first-entry t))
               (target-index (if my-super-jumps--current-index
                                 ;; Actually navigating - move to next
                                 (min (1+ my-super-jumps--current-index) (1- ring-length))
                               ;; First backward press - skip only if EXACTLY at first entry
                               (if current-exactly-at-first 1 0))))

          (setq my-super-jumps--current-index target-index)

          (let ((entry (ring-ref ring target-index)))
            (my-super-jumps--goto-entry entry)
            (message "Jump backward (%d/%d): %s:%d"
                     (1+ target-index)
                     ring-length
                     (file-name-nondirectory (my-super-jumps-entry-file entry))
                     (my-super-jumps-entry-line entry))

            (my-super-jumps--schedule-reorder))))))))

;;;###autoload
(defun my-super-jumps-forward ()
  "Jump forward in the project-specific jump ring."
  (interactive)
  (let* ((ring (my-super-jumps--get-project-ring))
         (ring-length (ring-length ring)))
    
    (cond
     ((ring-empty-p ring)
      (message "No jumps in ring for this project"))
     
     ((not my-super-jumps--current-index)
      (message "Not currently navigating jumps"))
     
     ((= my-super-jumps--current-index 0)
      (message "Already at most recent jump"))
     
     (t
      ;; Move to previous jump (forward in time)
      (setq my-super-jumps--current-index
            (max (1- my-super-jumps--current-index) 0))
      
      (let ((entry (ring-ref ring my-super-jumps--current-index)))
        (my-super-jumps--goto-entry entry)
        (message "Jump forward (%d/%d): %s:%d"
                 (1+ my-super-jumps--current-index)
                 ring-length
                 (file-name-nondirectory (my-super-jumps-entry-file entry))
                 (my-super-jumps-entry-line entry))
        
        (my-super-jumps--schedule-reorder))))))

;;; Jump Preview Mode

(defvar-local my-super-jumps-preview--entries nil
  "List of (index . entry) pairs for the current preview.")

(defvar-local my-super-jumps-preview--selected 0
  "Currently selected jump block index (into visible entries).")

(defvar-local my-super-jumps-preview--search ""
  "Current search string.")

(defvar-local my-super-jumps-preview--visible nil
  "List of visible (index . entry) pairs after filtering.")

(defvar-local my-super-jumps-preview--block-positions nil
  "Alist mapping visible index to (start . end) buffer positions.")

(defvar-local my-super-jumps-preview--source-ring nil
  "Reference to the jump ring this preview was built from.")

(defconst my-super-jumps-preview--context-lines 3
  "Number of context lines above and below the jump line.")

(defface my-super-jumps-preview-header
  '((t :foreground "#ff7300" :weight bold))
  "Face for jump block headers.")

(defface my-super-jumps-preview-line-number
  '((t :foreground "#8d7c6a"))
  "Face for line numbers in preview.")

(defface my-super-jumps-preview-jump-line
  '((t :background "#2e1e13"))
  "Face for the highlighted jump line.")

(defface my-super-jumps-preview-selected
  '((t :background "#372413"))
  "Face for the currently selected jump block.")

(defface my-super-jumps-preview-search-match
  '((t :background "#5a3a15" :foreground "#ffb000" :weight bold))
  "Face for search matches.")

(defface my-super-jumps-preview-search-prompt
  '((t :foreground "#ffb000" :weight bold))
  "Face for the search prompt in header.")

(defun my-super-jumps-preview--get-fontified-lines (file line-start line-end)
  "Get fontified lines from FILE between LINE-START and LINE-END.
Returns list of propertized strings."
  (let ((buf (find-file-noselect file t)))
    (with-current-buffer buf
      (font-lock-ensure (point-min) (point-max))
      (let ((lines nil))
        (save-excursion
          (goto-char (point-min))
          (forward-line (1- (max 1 line-start)))
          (dotimes (_ (1+ (- (min line-end (line-number-at-pos (point-max))) (max 1 line-start))))
            (let ((bol (line-beginning-position))
                  (eol (line-end-position)))
              (push (buffer-substring bol eol) lines)
              (forward-line 1))))
        (nreverse lines)))))

(defun my-super-jumps-preview--render ()
  "Render the jump preview buffer."
  (let ((inhibit-read-only t)
        (selected my-super-jumps-preview--selected)
        (search my-super-jumps-preview--search)
        (block-positions nil)
        (visible-idx 0))
    (erase-buffer)

    ;; Header
    (insert (propertize "Super Jumps Preview" 'face 'my-super-jumps-preview-header))
    (when (> (length search) 0)
      (insert "  "
              (propertize (format " search: %s " search)
                          'face 'my-super-jumps-preview-search-prompt)))
    (insert "\n")
    (insert (propertize (make-string 60 ?─) 'face 'my-super-jumps-preview-line-number))
    (insert "\n\n")

    ;; Render each visible block
    (dolist (pair my-super-jumps-preview--visible)
      (let* ((entry (cdr pair))
             (file (my-super-jumps-entry-file entry))
             (jump-line (my-super-jumps-entry-line entry))
             (line-start (max 1 (- jump-line my-super-jumps-preview--context-lines)))
             (line-end (+ jump-line my-super-jumps-preview--context-lines))
             (fontified-lines (my-super-jumps-preview--get-fontified-lines file line-start line-end))
             (block-start (point))
             (is-selected (= visible-idx selected))
             (current-line line-start))

        ;; File header
        (insert (propertize (format "── %s:%d "
                                    (file-name-nondirectory file)
                                    jump-line)
                            'face 'my-super-jumps-preview-header))
        (insert (propertize (make-string (max 0 (- 58 (length (file-name-nondirectory file)) 5)) ?─)
                            'face 'my-super-jumps-preview-line-number))
        (insert "\n")

        ;; Context lines with syntax highlighting
        (dolist (line-text fontified-lines)
          (let* ((is-jump-line (= current-line jump-line))
                 (prefix (propertize (format "%s%4d│ "
                                            (if is-jump-line ">" " ")
                                            current-line)
                                    'face 'my-super-jumps-preview-line-number)))
            (insert prefix)
            (insert line-text)
            (when is-jump-line
              (let ((ov (make-overlay (line-beginning-position) (line-end-position))))
                (overlay-put ov 'face '(:background "#5a3a15"))
                (overlay-put ov 'my-super-jumps-preview t)))
            (insert "\n"))
          (setq current-line (1+ current-line)))

        (insert "\n")
        (let ((block-end (point)))
          ;; Apply selected overlay
          (when is-selected
            (let ((ov (make-overlay block-start block-end)))
              (overlay-put ov 'face 'my-super-jumps-preview-selected)
              (overlay-put ov 'my-super-jumps-preview t)))
          (push (cons visible-idx (cons block-start block-end)) block-positions))
        (setq visible-idx (1+ visible-idx))))

    (when (null my-super-jumps-preview--visible)
      (insert (propertize "\n  No matching jumps.\n" 'face 'my-super-jumps-preview-line-number)))

    (setq my-super-jumps-preview--block-positions (nreverse block-positions))

    ;; Highlight search matches
    (when (>= (length search) 2)
      (save-excursion
        (goto-char (point-min))
        (while (search-forward search nil t)
          (let ((ov (make-overlay (match-beginning 0) (match-end 0))))
            (overlay-put ov 'face 'my-super-jumps-preview-search-match)
            (overlay-put ov 'my-super-jumps-preview-search t)
            (overlay-put ov 'priority 10)))))

    ;; Scroll to selected block
    (when-let ((pos (cdr (assq selected my-super-jumps-preview--block-positions))))
      (goto-char (car pos)))))

(defun my-super-jumps-preview--filter ()
  "Filter entries based on current search string."
  (if (< (length my-super-jumps-preview--search) 2)
      ;; Show all entries
      (setq my-super-jumps-preview--visible
            (copy-sequence my-super-jumps-preview--entries))
    ;; Filter: keep only entries whose preview text contains the search string
    (let ((search (downcase my-super-jumps-preview--search))
          (result nil))
      (dolist (pair my-super-jumps-preview--entries)
        (let* ((entry (cdr pair))
               (file (my-super-jumps-entry-file entry))
               (jump-line (my-super-jumps-entry-line entry))
               (line-start (max 1 (- jump-line my-super-jumps-preview--context-lines)))
               (line-end (+ jump-line my-super-jumps-preview--context-lines))
               (lines (my-super-jumps-preview--get-fontified-lines file line-start line-end))
               (text (downcase (concat (file-name-nondirectory file) " "
                                       (mapconcat #'substring-no-properties lines " ")))))
          (when (string-match-p (regexp-quote search) text)
            (push pair result))))
      (setq my-super-jumps-preview--visible (nreverse result))))
  ;; Clamp selected index
  (when my-super-jumps-preview--visible
    (setq my-super-jumps-preview--selected
          (min my-super-jumps-preview--selected
               (1- (length my-super-jumps-preview--visible))))))

(defun my-super-jumps-preview--refresh ()
  "Filter and re-render the preview."
  (my-super-jumps-preview--filter)
  (my-super-jumps-preview--render))

(defun my-super-jumps-preview-next ()
  "Move to next jump block."
  (interactive)
  (when my-super-jumps-preview--visible
    (setq my-super-jumps-preview--selected
          (min (1+ my-super-jumps-preview--selected)
               (1- (length my-super-jumps-preview--visible))))
    (my-super-jumps-preview--render)))

(defun my-super-jumps-preview-prev ()
  "Move to previous jump block."
  (interactive)
  (when my-super-jumps-preview--visible
    (setq my-super-jumps-preview--selected
          (max (1- my-super-jumps-preview--selected) 0))
    (my-super-jumps-preview--render)))

(defun my-super-jumps-preview-select ()
  "Jump to the selected entry and close preview."
  (interactive)
  (when my-super-jumps-preview--visible
    (let* ((pair (nth my-super-jumps-preview--selected
                      my-super-jumps-preview--visible))
           (ring-idx (car pair))
           (entry (cdr pair))
           (ring-len (ring-length my-super-jumps-preview--source-ring)))
      (quit-window t)
      (my-super-jumps--goto-entry entry)
      (setq my-super-jumps--current-index ring-idx)
      (my-super-jumps--schedule-reorder)
      (message "Jump backward (%d/%d): %s:%d"
               (1+ ring-idx)
               ring-len
               (file-name-nondirectory (my-super-jumps-entry-file entry))
               (my-super-jumps-entry-line entry)))))

(defun my-super-jumps-preview-quit ()
  "Close the preview buffer."
  (interactive)
  (quit-window t))

(defun my-super-jumps-preview-search-input ()
  "Handle self-inserting character for search."
  (interactive)
  (let ((char (this-command-keys)))
    (setq my-super-jumps-preview--search
          (concat my-super-jumps-preview--search char))
    (setq my-super-jumps-preview--selected 0)
    (my-super-jumps-preview--refresh)))

(defun my-super-jumps-preview-search-delete ()
  "Delete last character from search string."
  (interactive)
  (when (> (length my-super-jumps-preview--search) 0)
    (setq my-super-jumps-preview--search
          (substring my-super-jumps-preview--search 0 -1))
    (setq my-super-jumps-preview--selected 0)
    (my-super-jumps-preview--refresh)))

(defvar my-super-jumps-preview-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Navigation
    (define-key map (kbd "<down>") #'my-super-jumps-preview-next)
    (define-key map (kbd "<up>") #'my-super-jumps-preview-prev)
    (define-key map (kbd "RET") #'my-super-jumps-preview-select)
    (define-key map (kbd "<escape>") #'my-super-jumps-preview-quit)
    (define-key map (kbd "DEL") #'my-super-jumps-preview-search-delete)
    (define-key map (kbd "<backspace>") #'my-super-jumps-preview-search-delete)
    ;; Bind all printable characters to search input
    (let ((i 32))
      (while (<= i 126)
        (define-key map (char-to-string i) #'my-super-jumps-preview-search-input)
        (setq i (1+ i))))
    map)
  "Keymap for super jumps preview mode.")

(define-derived-mode my-super-jumps-preview-mode special-mode "Jumps"
  "Major mode for viewing jump previews with inline search."
  (setq buffer-read-only t
        truncate-lines t
        cursor-type nil))

(evil-set-initial-state 'my-super-jumps-preview-mode 'emacs)

;;;###autoload
(defun my-super-jumps-list ()
  "Show all jumps for the current project in a preview buffer."
  (interactive)
  (let* ((ring (my-super-jumps--get-project-ring))
         (project-root (my-super-jumps--get-project-root))
         (current-file (and (buffer-file-name) (expand-file-name (buffer-file-name))))
         (current-line (line-number-at-pos)))

    (if (ring-empty-p ring)
        (message "No jumps for project: %s" project-root)
      ;; Build entries list, skip first entry if current position is within its context range
      (let ((entries nil)
            (skipped-first nil))
        (dotimes (i (ring-length ring))
          (let* ((entry (ring-ref ring i))
                 (entry-file (my-super-jumps-entry-file entry))
                 (entry-line (my-super-jumps-entry-line entry))
                 (in-context (and (= i 0)
                                  current-file
                                  (equal current-file entry-file)
                                  (<= (abs (- current-line entry-line))
                                      my-super-jumps-preview--context-lines))))
            (if in-context
                (setq skipped-first t)
              (push (cons i entry) entries))))
        (setq entries (nreverse entries))

        (if (null entries)
            (message "No other jumps for project: %s" project-root)
          ;; Create and populate buffer
          (let ((buf (get-buffer-create "*Super Jumps*")))
            (with-current-buffer buf
              (my-super-jumps-preview-mode)
              (setq my-super-jumps-preview--entries entries
                    my-super-jumps-preview--source-ring ring
                    my-super-jumps-preview--search ""
                    my-super-jumps-preview--selected 0)
              (my-super-jumps-preview--refresh))
            (pop-to-buffer buf '((display-buffer-full-frame)))))))))

;;;###autoload
(defun my-super-jumps-clear ()
  "Clear all jumps for the current project."
  (interactive)
  (let ((project-root (my-super-jumps--get-project-root)))
    (remhash project-root my-super-jumps--project-rings)
    (setq my-super-jumps--current-index nil)
    (message "Cleared jumps for project: %s" project-root)))

;;;###autoload
(defun my-super-jumps-postpone-async (buffer-id)
  "Update async buffer BUFFER-ID with current position (solid jump).
This will register a solid jump after settle delay.
Perfect for rapid navigation where you want only the final position registered."
  (interactive "sBuffer ID: ")
  (when (buffer-file-name)
    (my-super-jumps--update-async-buffer buffer-id
                                         (buffer-file-name)
                                         (line-number-at-pos)
                                         (current-column)
                                         nil)))  ; nil = solid jump

;;;###autoload
(defun my-super-jumps-postpone-async-transient (buffer-id)
  "Update async buffer BUFFER-ID with current position (transient jump).
This will register a transient jump after settle delay.
Transient jumps are cleared when cross-buffer navigation occurs.
Perfect for in-file navigation like jump-up/jump-down."
  (interactive "sBuffer ID: ")
  (when (buffer-file-name)
    (my-super-jumps--update-async-buffer buffer-id
                                         (buffer-file-name)
                                         (line-number-at-pos)
                                         (current-column)
                                         t)))  ; t = transient jump

;;;###autoload
(defun my-super-jumps-cancel-async (buffer-id)
  "Cancel async jump registration for BUFFER-ID."
  (interactive "sBuffer ID: ")
  (my-super-jumps--cancel-async-timer buffer-id)
  (remhash buffer-id my-super-jumps--async-buffers)
  (message "Cancelled async jump for buffer ID: %s" buffer-id))

;;;###autoload
(defun my-super-jumps-list-async ()
  "Show all pending async buffers."
  (interactive)
  (let ((buffers (hash-table-keys my-super-jumps--async-buffers)))
    (if buffers
        (message "Pending async buffers: %s" (string-join buffers ", "))
      (message "No pending async buffers"))))

;;; Mode definition

;;;###autoload
(define-minor-mode my-super-jumps-mode
  "Enable project-specific smart jump navigation."
  :global t
  :group 'my-super-jumps
  :lighter " SJumps"
  
  (if my-super-jumps-mode
      (progn
        ;; Only use command hooks (Evil-style approach)
        (my-super-jumps--setup-completion-hooks)
        (message "Super jumps mode enabled"))
    
    ;; Cleanup
    (my-super-jumps--remove-completion-hooks)
    (message "Super jumps mode disabled")))

;;; Selection-based jump registration

(defvar my-super-jumps--pre-selection-position nil
  "Store position before starting selection process.")

(defvar my-super-jumps--pre-selection-file nil
  "Store file before starting selection process.")

(defun my-super-jumps--store-pre-selection-position ()
  "Store current position before starting a selection process."
  (setq my-super-jumps--pre-selection-position (when (buffer-file-name) (point-marker)))
  (setq my-super-jumps--pre-selection-file (buffer-file-name)))

(defun my-super-jumps--register-on-selection ()
  "Register jump to current position when user makes a selection."
  (when (and my-super-jumps--pre-selection-position 
             my-super-jumps--pre-selection-file
             my-super-jumps-mode)
    (let ((current-file (buffer-file-name))
          (current-pos (point)))
      ;; Only register if we actually moved to a different location
      (when (or (not (equal current-file my-super-jumps--pre-selection-file))
                (and (equal current-file my-super-jumps--pre-selection-file)
                     (>= (abs (- (line-number-at-pos current-pos)
                                (line-number-at-pos my-super-jumps--pre-selection-position)))
                         my-super-jumps-line-threshold)))
        ;; Register the CURRENT position (where we landed) as a jump
        (setq my-super-jumps--jump-intention t)
        (my-super-jumps-register)))
    ;; Clear stored position
    (setq my-super-jumps--pre-selection-position nil)
    (setq my-super-jumps--pre-selection-file nil)))

;;; Simplified approach - just use manual registration

(defun my-super-jumps--before-find-file (&rest _args)
  "No-op."
  nil)

(defun my-super-jumps--after-find-file (&rest _args)
  "No-op."
  nil)

(defun my-super-jumps--before-switch-buffer (&rest _args)
  "No-op."
  nil)

(defun my-super-jumps--after-switch-buffer (&rest _args)
  "No-op."
  nil)

(defun my-super-jumps--before-goto-line (&rest _args)
  "Store position before goto-line."
  (when my-super-jumps-mode
    (my-super-jumps--store-pre-selection-position)))

(defun my-super-jumps--after-goto-line (&rest _args)
  "Register jump after goto-line."
  (when my-super-jumps-mode
    (my-super-jumps--register-on-selection)))

(defun my-super-jumps--before-lookup (&rest _args)
  "Store position before lookup commands."
  (when my-super-jumps-mode
    (my-super-jumps--store-pre-selection-position)))

;;; Enter key detection

(defvar my-super-jumps--enter-pressed nil
  "Flag to track if Enter was pressed in minibuffer.")

(defun my-super-jumps--track-enter-advice (&rest _)
  "Track when Enter is pressed in minibuffer."
  (when (and (minibufferp) my-super-jumps-mode)
    (setq my-super-jumps--enter-pressed t)))

(defun my-super-jumps--minibuffer-exit ()
  "Register jump only if Enter was pressed."
  (when (and my-super-jumps-mode my-super-jumps--enter-pressed)
    ;; Small delay to ensure the selection has taken effect
    (run-with-timer 0.1 nil #'my-super-jumps--register-on-selection))
  ;; Reset flag
  (setq my-super-jumps--enter-pressed nil))

;;;###autoload
(defun my-super-jumps-mark-and-register ()
  "Manually mark intention and register current position as jump."
  (interactive)
  (when my-super-jumps-mode
    (setq my-super-jumps--jump-intention t)
    (my-super-jumps-register)))

;;; Evil-style command tracking
(defvar my-super-jumps--last-command nil
  "Track the last command executed.")

(defvar my-super-jumps--pre-command-position nil
  "Position before the command.")

(defvar my-super-jumps--pre-command-file nil
  "File before the command.")

(defvar my-super-jumps--pre-command-line nil
  "Line number before the command.")

(defun my-super-jumps--pre-command-hook ()
  "Track commands and save position before navigation commands!."
  (when my-super-jumps-mode
    ;; Only process if this-command is a symbol (not a lambda)
    (when (symbolp this-command)
      (setq my-super-jumps--last-command this-command)
      ;; Save position if this is a navigation command
      (let ((cmd-name (symbol-name this-command))
            (prefix-arg (or current-prefix-arg
                            (and (boundp 'evil-this-motion-count) evil-this-motion-count)
                            1)))
        (when (or (string-match-p "consult-buffer" cmd-name)
                  (string-match-p "find-file" cmd-name)
                  (string-match-p "evil-goto-first-line" cmd-name)
                  (string-match-p "evil-goto-line" cmd-name)
                  (string-match-p "smart-enter" cmd-name)
                  (string-match-p "lsp-find-definition" cmd-name)
                  (string-match-p "xref-find-definitions" cmd-name)
                  (string-match-p "projectile" cmd-name)
                  (string-match-p "markdown-marks-jump" cmd-name)
                  ;; Evil line movements with significant digit arguments
                  (and (or (string-match-p "evil-next-line" cmd-name)
                           (string-match-p "evil-previous-line" cmd-name))
                       (>= prefix-arg my-super-jumps-line-threshold)))
          ;; Save current position before command executes
          (setq my-super-jumps--pre-command-position (point))
          (setq my-super-jumps--pre-command-file (buffer-file-name))
          (setq my-super-jumps--pre-command-line (line-number-at-pos))
          ;; Force register the BEFORE position (bypass normal check)
          (when (buffer-file-name)
            (let ((entry (my-super-jumps--create-entry)))
              (when entry
                (my-super-jumps--add-jump entry)
                (message "Registered BEFORE jump: %s:%d"
                         (file-name-nondirectory (my-super-jumps-entry-file entry))
                         (my-super-jumps-entry-line entry))))))))))

(defun my-super-jumps--post-command-hook ()
  "Register jump after certain commands complete, but only if movement is significant."
  (when (and my-super-jumps-mode
             my-super-jumps--last-command
             my-super-jumps--pre-command-file)  ; Only process if we saved a before position
    (let ((current-file (buffer-file-name))
          (current-line (line-number-at-pos))
          (is-cross-buffer nil))

      ;; Check if this is a cross-buffer jump
      (when (and current-file
                 (not (equal current-file my-super-jumps--pre-command-file)))
        (setq is-cross-buffer t)
        ;; Clear all transient jumps on cross-buffer navigation
        (my-super-jumps--clear-transient-jumps))

      ;; Only register AFTER position if we actually moved significantly
      (when (and current-file
                 (or
                  ;; Different file - always register
                  is-cross-buffer
                  ;; Same file but significant line difference
                  (and (equal current-file my-super-jumps--pre-command-file)
                       my-super-jumps--pre-command-line
                       (>= (abs (- current-line my-super-jumps--pre-command-line))
                           my-super-jumps-line-threshold))))
        ;; Force register the AFTER position (solid, not transient)
        (let ((entry (my-super-jumps--create-entry nil)))  ; nil = solid jump
          (when entry
            (my-super-jumps--add-jump entry)
            (message "Registered AFTER jump: %s:%d (moved %d lines from %s:%d)"
                     (file-name-nondirectory current-file)
                     current-line
                     (if my-super-jumps--pre-command-line
                         (abs (- current-line my-super-jumps--pre-command-line))
                       0)
                     (file-name-nondirectory my-super-jumps--pre-command-file)
                     my-super-jumps--pre-command-line))))))

  ;; Always clear tracking variables
  (setq my-super-jumps--last-command nil)
  (setq my-super-jumps--pre-command-position nil)
  (setq my-super-jumps--pre-command-file nil)
  (setq my-super-jumps--pre-command-line nil))

;; Store position before vertico opens
(defvar my-super-jumps--vertico-before-file nil
  "File before vertico opened.")
(defvar my-super-jumps--vertico-before-line nil
  "Line before vertico opened.")
(defvar my-super-jumps--vertico-before-entry nil
  "Jump entry captured before vertico opened.")

(defun my-super-jumps--on-vertico-setup (&rest _)
  "Capture position when vertico opens."
  (when (and my-super-jumps-mode (buffer-file-name (window-buffer (minibuffer-selected-window))))
    (with-selected-window (minibuffer-selected-window)
      (setq my-super-jumps--vertico-before-file (buffer-file-name))
      (setq my-super-jumps--vertico-before-line (line-number-at-pos))
      (setq my-super-jumps--vertico-before-entry (my-super-jumps--create-entry)))))

;; Named advice functions
(defun my-super-jumps--on-vertico-exit (&rest _)
  "Register jump after vertico selection."
  (when my-super-jumps-mode
    ;; Register BEFORE position if we captured one
    ;; Navigation hasn't happened yet, so just save it - we'll check distance later
    (when my-super-jumps--vertico-before-entry
      (my-super-jumps--add-jump my-super-jumps--vertico-before-entry)
      (message "Registered BEFORE (vertico): %s:%d"
               (file-name-nondirectory my-super-jumps--vertico-before-file)
               my-super-jumps--vertico-before-line))
    ;; Register AFTER position with timer (navigation happens after vertico-exit returns)
    (run-with-timer 0.15 nil #'my-super-jumps-mark-and-register)
    ;; Clear saved position
    (setq my-super-jumps--vertico-before-file nil)
    (setq my-super-jumps--vertico-before-line nil)
    (setq my-super-jumps--vertico-before-entry nil)))

(defun my-super-jumps--on-consult-read (&rest _)
  "Register jump after consult selection."
  (when my-super-jumps-mode
    ;; Register BEFORE position if vertico captured one
    (when my-super-jumps--vertico-before-entry
      (my-super-jumps--add-jump my-super-jumps--vertico-before-entry)
      (message "Registered BEFORE (consult): %s:%d"
               (file-name-nondirectory my-super-jumps--vertico-before-file)
               my-super-jumps--vertico-before-line))
    ;; Register AFTER position
    (run-with-timer 0.15 nil #'my-super-jumps-mark-and-register)
    ;; Clear saved position
    (setq my-super-jumps--vertico-before-file nil)
    (setq my-super-jumps--vertico-before-line nil)
    (setq my-super-jumps--vertico-before-entry nil)))

(defun my-super-jumps--on-ivy-done (&rest _)
  "Register jump after ivy selection."
  (when my-super-jumps-mode
    (run-with-timer 0.1 nil #'my-super-jumps-mark-and-register)))

(defun my-super-jumps--on-helm-exit (&rest _)
  "Register jump after helm selection."
  (when my-super-jumps-mode
    (run-with-timer 0.1 nil #'my-super-jumps-mark-and-register)))

(defun my-super-jumps--on-xref-goto (&rest _)
  "Register jump after xref navigation (used by lsp-find-references)."
  (when my-super-jumps-mode
    (run-with-timer 0.1 nil #'my-super-jumps-mark-and-register)))

;;; Insert mode exit tracking

(defun my-super-jumps--on-insert-exit ()
  "Register jump when exiting insert mode."
  (when (and my-super-jumps-mode
             (buffer-file-name))
    (let ((entry (my-super-jumps--create-entry)))
      (when entry
        ;; Check if this position is different enough from the last jump
        (let* ((ring (my-super-jumps--get-project-ring))
               (should-register
                (or (ring-empty-p ring)
                    (let* ((last-entry (ring-ref ring 0))
                           (last-file (my-super-jumps-entry-file last-entry))
                           (last-line (my-super-jumps-entry-line last-entry))
                           (current-file (expand-file-name (buffer-file-name)))
                           (current-line (line-number-at-pos)))
                      (or (not (equal current-file last-file))
                          (>= (abs (- current-line last-line))
                              my-super-jumps-line-threshold))))))
          (when should-register
            (my-super-jumps--add-jump entry)
            (message "Registered edit jump: %s:%d"
                     (file-name-nondirectory (my-super-jumps-entry-file entry))
                     (my-super-jumps-entry-line entry))))))))

;;; Evil-style command hooks setup
(defun my-super-jumps--setup-completion-hooks ()
  "Set up command hooks like Evil does."
  (add-hook 'pre-command-hook #'my-super-jumps--pre-command-hook)
  (add-hook 'post-command-hook #'my-super-jumps--post-command-hook)

  ;; Register jump when exiting insert mode
  (add-hook 'evil-insert-state-exit-hook #'my-super-jumps--on-insert-exit)

  ;; Add advice for completion frameworks - use eval-after-load for lazy loading
  (with-eval-after-load 'vertico
    (advice-add 'vertico--setup :before #'my-super-jumps--on-vertico-setup)
    (advice-add 'vertico-exit :after #'my-super-jumps--on-vertico-exit))
  (with-eval-after-load 'consult
    (advice-add 'consult--read :after #'my-super-jumps--on-consult-read))
  (with-eval-after-load 'ivy
    (advice-add 'ivy-done :after #'my-super-jumps--on-ivy-done))
  (with-eval-after-load 'helm
    (advice-add 'helm-exit-minibuffer :after #'my-super-jumps--on-helm-exit))

  ;; Also hook into xref for lsp-find-references
  (with-eval-after-load 'xref
    (advice-add 'xref-goto-xref :after #'my-super-jumps--on-xref-goto)))

(defun my-super-jumps--remove-completion-hooks ()
  "Remove command hooks."
  (remove-hook 'pre-command-hook #'my-super-jumps--pre-command-hook)
  (remove-hook 'post-command-hook #'my-super-jumps--post-command-hook)
  (remove-hook 'evil-insert-state-exit-hook #'my-super-jumps--on-insert-exit)

  ;; Remove advice for completion frameworks
  (when (featurep 'vertico)
    (advice-remove 'vertico--setup #'my-super-jumps--on-vertico-setup)
    (advice-remove 'vertico-exit #'my-super-jumps--on-vertico-exit))
  (when (featurep 'consult)
    (advice-remove 'consult--read #'my-super-jumps--on-consult-read))
  (when (featurep 'ivy)
    (advice-remove 'ivy-done #'my-super-jumps--on-ivy-done))
  (when (featurep 'helm)
    (advice-remove 'helm-exit-minibuffer #'my-super-jumps--on-helm-exit))
  (when (featurep 'xref)
    (advice-remove 'xref-goto-xref #'my-super-jumps--on-xref-goto)))

(provide 'my-super-jumps)
;;; my-super-jumps.el ends here
