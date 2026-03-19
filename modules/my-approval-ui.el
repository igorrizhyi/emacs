;;; my-approval-ui.el --- Approval queue UI for lead agent options -*- lexical-binding: t; -*-

;; Author: Igor Rizhyi
;; Keywords: tools, ai, team

;;; Commentary:

;; Bottom split window for reviewing and approving lead agent options.
;; Supports checklist and choice request types with keyboard navigation.

;;; Code:

(require 'cl-lib)
(require 'notifications)

(declare-function shell-maker-submit "shell-maker")
(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")
(declare-function agent-shell-team--get-lead "agent-shell-team")
(declare-function agent-shell-team--queue-message "agent-shell-team")
(declare-function agent-shell-team--start-drain-timer "agent-shell-team")
(declare-function agent-shell-team--agent-status "agent-shell-team")
(defvar agent-shell-team--session-id)

;;; ---- Constants & Buffer Name ------------------------------------------------

(defconst my/approval-buffer-name " *approval-queue*"
  "Space-prefixed to hide from ibuffer.")

(defconst my/approval-window-height 14
  "Height of the approval window in lines.")

(defconst my/approval-left-panel-width 18
  "Width of the left request-list panel.")

;;; ---- Faces ------------------------------------------------------------------

(defface my/approval-title-face
  '((t :weight bold))
  "Face for request titles in the left panel.")

(defface my/approval-selected-title-face
  '((t :weight bold :inverse-video t))
  "Face for the currently selected request title.")

(defface my/approval-separator-face
  '((t :foreground "#555555"))
  "Face for the column separator.")

(defface my/approval-checkbox-checked-face
  '((t :foreground "#33ff33"))
  "Face for checked checkboxes.")

(defface my/approval-checkbox-unchecked-face
  '((t :foreground "#888888"))
  "Face for unchecked checkboxes.")

(defface my/approval-item-highlight-face
  '((t :background "#2a2a00"))
  "Face for the currently highlighted item.")

(defface my/approval-radio-selected-face
  '((t :foreground "#33ff33"))
  "Face for selected radio buttons.")

(defface my/approval-radio-unselected-face
  '((t :foreground "#888888"))
  "Face for unselected radio buttons.")

(defface my/approval-item-description-face
  '((t :foreground "#777777" :slant italic))
  "Face for item descriptions shown below labels.")

(defface my/approval-notes-face
  '((t :foreground "#aaaaaa" :slant italic))
  "Face for the notes block.")

(defface my/approval-hint-face
  '((t :foreground "#666666"))
  "Face for the submit hint.")

(defface my/approval-collapsed-face
  '((t :foreground "#bbbbbb" :background "#1a1a2e" :weight bold))
  "Face for the collapsed summary bar.")

;;; ---- Data -------------------------------------------------------------------

(defvar my/approval--requests nil
  "List of pending request plists.
Each has keys :request-id :title :description :type
:items :notes :refine :decisions :timestamp.
Checklist :items are plists (:id :label :checked).
Choice :items are plists (:id :label :selected).
:decisions is a list of (:decision :reaction) plists.")

;;; ---- Buffer-local State -----------------------------------------------------

(defvar-local my/approval--request-index 0
  "Index of the currently selected request in `my/approval--requests'.")

(defvar-local my/approval--item-index 0
  "Index of the currently highlighted item within the current request.")

(defvar-local my/approval--focus 'left
  "Which panel has focus: `left' or `center'.")

(defvar-local my/approval--collapsed nil
  "Non-nil when the approval window is in collapsed (single-line) mode.")

;;; ---- Keymap -----------------------------------------------------------------

(defvar my/approval-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<up>") #'my/approval-prev-request)
    (define-key map (kbd "<down>") #'my/approval-next-request)
    (define-key map "j" #'my/approval-next-item)
    (define-key map "k" #'my/approval-prev-item)
    (define-key map (kbd "RET") #'my/approval-toggle-item)
    (define-key map (kbd "<left>") #'my/approval-prev-choice)
    (define-key map (kbd "<right>") #'my/approval-next-choice)
    (define-key map "a" #'my/approval-add-item)
    (define-key map "i" #'my/approval-edit-notes)
    (define-key map "r" #'my/approval-edit-refine)
    (define-key map (kbd "C-<return>") #'my/approval-submit)
    (define-key map "q" #'my/approval-dismiss)
    (define-key map "Q" #'my/approval-hide)
    (define-key map "g" #'my/approval-refresh)
    (define-key map "l" #'my/approval-focus-center)
    (define-key map (kbd "ESC") #'my/approval-focus-left)
    (define-key map (kbd "C-k") #'my/approval-toggle-collapse)
    (define-key map "o" #'my/approval-open-review-file)
    map)
  "Keymap for `my/approval-mode'.")

;;; ---- Mode -------------------------------------------------------------------

(define-derived-mode my/approval-mode special-mode "Approval"
  "Major mode for the approval queue UI."
  :interactive nil
  (setq cursor-type 'bar
        truncate-lines t
        buffer-read-only t
        mode-line-format nil
        header-line-format (propertize " Approval Queue" 'face 'bold)))

;; Evil-mode integration: bind keys in normal state so they take priority
(when (fboundp 'evil-define-key*)
  (evil-set-initial-state 'my/approval-mode 'normal)
  (evil-define-key* 'normal my/approval-mode-map
    (kbd "<up>") #'my/approval-prev-request
    (kbd "<down>") #'my/approval-next-request
    "j" #'my/approval-next-item
    "k" #'my/approval-prev-item
    (kbd "RET") #'my/approval-toggle-item
    (kbd "<left>") #'my/approval-prev-choice
    (kbd "<right>") #'my/approval-next-choice
    "a" #'my/approval-add-item
    "i" #'my/approval-edit-notes
    "r" #'my/approval-edit-refine
    (kbd "C-<return>") #'my/approval-submit
    "q" #'my/approval-dismiss
    "Q" #'my/approval-hide
    "g" #'my/approval-refresh
    "l" #'my/approval-focus-center
    (kbd "ESC") #'my/approval-focus-left
    (kbd "C-k") #'my/approval-toggle-collapse
    "o" #'my/approval-open-review-file))

;;; ---- Helpers ----------------------------------------------------------------

(defun my/approval--current-request ()
  "Return the currently selected request plist, or nil."
  (when (and my/approval--requests
             (< my/approval--request-index (length my/approval--requests)))
    (nth my/approval--request-index my/approval--requests)))

(defun my/approval--clamp-indices ()
  "Ensure request-index and item-index are within valid bounds."
  (let ((req-count (length my/approval--requests)))
    (if (zerop req-count)
        (setq my/approval--request-index 0
              my/approval--item-index 0)
      (setq my/approval--request-index
            (max 0 (min my/approval--request-index (1- req-count))))
      (when-let ((req (my/approval--current-request)))
        (let ((item-count (length (plist-get req :items))))
          (if (zerop item-count)
              (setq my/approval--item-index 0)
            (setq my/approval--item-index
                  (max 0 (min my/approval--item-index (1- item-count))))))))))

;;; ---- Markdown File Helpers --------------------------------------------------

(defun my/approval--review-file-path (slug)
  "Return the full path to the review markdown file for SLUG."
  (expand-file-name (concat slug ".md")
                    (expand-file-name ".agent-shell/reviews/"
                                      (projectile-project-root))))

(defun my/approval--parse-review-file (file)
  "Parse a review markdown FILE into a request plist.
Returns a plist with :request-id :title :description :type
:items :notes :refine :decisions :timestamp :file-mtime."
  (when (file-exists-p file)
    (let ((slug (file-name-sans-extension (file-name-nondirectory file)))
          (mtime (float-time (file-attribute-modification-time
                              (file-attributes file))))
          title type description items notes refine decisions
          current-item current-section)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (cond
             ;; Section headers: ## Refine, ## Notes, ## Decisions
             ((string-match "^## Refine" line)
              (setq current-section 'refine current-item nil))
             ((string-match "^## Notes" line)
              (setq current-section 'notes current-item nil))
             ((string-match "^## Decisions" line)
              (setq current-section 'decisions current-item nil))
             ;; Any other ## heading ends the current section
             ((string-match "^## " line)
              (setq current-section nil current-item nil))
             ;; Inside ## Refine section — collect lines
             ((eq current-section 'refine)
              (unless (string-empty-p (string-trim line))
                (setq refine
                      (if refine
                          (concat refine "\n" line)
                        line))))
             ;; Inside ## Notes section — collect lines
             ((eq current-section 'notes)
              (unless (string-empty-p (string-trim line))
                (setq notes
                      (if notes
                          (concat notes "\n" line)
                        line))))
             ;; Inside ## Decisions section — parse table rows
             ((eq current-section 'decisions)
              (when (and (string-match "^| *\\([^|]+\\)| *\\([^|]*\\)|?" line)
                         (not (string-match "^|[-: ]" line))
                         (not (string-match "Decision" line)))
                (let ((decision (string-trim (match-string 1 line)))
                      (reaction (string-trim (match-string 2 line))))
                  (push (list :decision decision :reaction reaction) decisions))))
             ;; Title: # ...
             ((string-match "^# \\(.+\\)" line)
              (setq title (match-string 1 line)))
             ;; Type: <!-- type: ... -->
             ((string-match "<!-- *type: *\\([^ ]+\\) *-->" line)
              (setq type (match-string 1 line)))
             ;; Description: > ...
             ((string-match "^> \\(.*\\)" line)
              (setq description
                    (if description
                        (concat description " " (match-string 1 line))
                      (match-string 1 line))))
             ;; Item: - [x] or - [ ] with optional <!-- id: ... -->
             ((string-match "^- \\[\\([xX ]\\)\\] \\(.*\\)" line)
              (let* ((checked-str (match-string 1 line))
                     (rest (match-string 2 line))
                     (checked (not (string= checked-str " ")))
                     id label)
                (if (string-match "\\(.*?\\) *<!-- *id: *\\([^ ]+\\) *-->" rest)
                    (setq label (string-trim (match-string 1 rest))
                          id (match-string 2 rest))
                  (setq label (string-trim rest)
                        id (format "item-%d" (length items))))
                (setq current-item
                      (if (equal type "choice")
                          (list :id id :label label :selected checked)
                        (list :id id :label label :checked checked)))
                (push current-item items)))
             ;; Item description: 2-space indent after item
             ((and current-item (string-match "^  \\(.+\\)" line))
              (plist-put current-item :description (match-string 1 line)))
             ;; Legacy Notes: single-line format (fallback)
             ((string-match "^Notes: \\(.*\\)" line)
              (unless notes
                (setq notes (match-string 1 line))))
             ;; Separator line resets current-item context
             ((string-match "^---" line)
              (setq current-item nil))
             ;; Blank line resets current-item context
             ((string-empty-p (string-trim line))
              (setq current-item nil))))
          (forward-line 1)))
      (list :request-id slug
            :title (or title slug)
            :description (or description "")
            :type (or type "checklist")
            :items (nreverse items)
            :notes (or notes "")
            :refine (or refine "")
            :decisions (nreverse decisions)
            :timestamp (or mtime (float-time))
            :file-mtime mtime))))

(defun my/approval--write-review-file (req)
  "Write request plist REQ back to its markdown review file.
Full rewrite — files are small (5-30 lines)."
  (let* ((slug (plist-get req :request-id))
         (file (my/approval--review-file-path slug))
         (dir (file-name-directory file)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    (with-temp-file file
      ;; Title
      (insert (format "# %s\n" (or (plist-get req :title) slug)))
      ;; Type
      (insert (format "<!-- type: %s -->\n" (or (plist-get req :type) "checklist")))
      ;; Description
      (let ((desc (plist-get req :description)))
        (when (and desc (not (string-empty-p desc)))
          (insert (format "> %s\n" desc))))
      (insert "\n")
      ;; Items
      (dolist (item (plist-get req :items))
        (let* ((id (plist-get item :id))
               (label (or (plist-get item :label) "?"))
               (checked (if (equal (plist-get req :type) "choice")
                            (plist-get item :selected)
                          (plist-get item :checked)))
               (mark (if checked "x" " "))
               (desc (plist-get item :description)))
          (insert (format "- [%s] %s <!-- id: %s -->\n" mark label id))
          (when (and desc (not (string-empty-p desc)))
            (insert (format "  %s\n" desc)))))
      ;; Refine section
      (insert "\n## Refine\n")
      (let ((refine (plist-get req :refine)))
        (when (and refine (not (string-empty-p refine)))
          (insert (format "%s\n" refine))))
      ;; Notes section
      (insert "\n## Notes\n")
      (let ((notes (plist-get req :notes)))
        (when (and notes (not (string-empty-p notes)))
          (insert (format "%s\n" notes))))
      ;; Decisions section
      (insert "\n## Decisions\n")
      (insert "| Decision | Reaction |\n")
      (insert "|----------|----------|\n")
      (dolist (d (plist-get req :decisions))
        (insert (format "| %s | %s |\n"
                        (or (plist-get d :decision) "")
                        (or (plist-get d :reaction) "")))))
    ;; Update file-mtime on the plist
    (plist-put req :file-mtime
               (float-time (file-attribute-modification-time
                            (file-attributes file))))))

(defun my/approval--maybe-refresh-from-disk ()
  "Re-read current request's markdown if file changed externally."
  (when-let ((req (my/approval--current-request)))
    (let* ((slug (plist-get req :request-id))
           (file (my/approval--review-file-path slug)))
      (when (and (file-exists-p file)
                 (> (float-time (file-attribute-modification-time
                                 (file-attributes file)))
                    (or (plist-get req :file-mtime) 0)))
        (let ((updated (my/approval--parse-review-file file)))
          ;; Merge updated fields into existing request in-place
          (plist-put req :title (plist-get updated :title))
          (plist-put req :description (plist-get updated :description))
          (plist-put req :type (plist-get updated :type))
          (plist-put req :items (plist-get updated :items))
          (plist-put req :notes (plist-get updated :notes))
          (plist-put req :refine (plist-get updated :refine))
          (plist-put req :decisions (plist-get updated :decisions))
          (plist-put req :file-mtime (plist-get updated :file-mtime)))))))

(defun my/approval--delete-review-file (req)
  "Delete the markdown review file for REQ if it exists."
  (let ((file (my/approval--review-file-path (plist-get req :request-id))))
    (when (file-exists-p file)
      (delete-file file))))

;;; ---- Rendering --------------------------------------------------------------

(defun my/approval--render ()
  "Render the approval queue buffer contents."
  (let ((buf (get-buffer my/approval-buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (my/approval--clamp-indices)
        (let ((inhibit-read-only t)
              (saved-point (point)))
          (erase-buffer)
          (if my/approval--collapsed
              (my/approval--render-collapsed)
            (if (null my/approval--requests)
                (insert (propertize "  No pending requests." 'face 'my/approval-hint-face))
              (my/approval--render-panels)))
          (goto-char (min saved-point (point-max))))))))

(defun my/approval--render-panels ()
  "Render left panel (request list) and center panel (current request details)."
  (let* ((req (my/approval--current-request))
         (left-lines (my/approval--build-left-panel))
         (center-lines (when req (my/approval--build-center-panel req)))
         (max-lines (max (length left-lines) (length center-lines) 1)))
    (dotimes (i max-lines)
      (let ((left (or (nth i left-lines) ""))
            (center (or (nth i center-lines) "")))
        ;; Left panel: pad to fixed width
        (insert (truncate-string-to-width left my/approval-left-panel-width 0 ?\s))
        ;; Separator
        (insert (propertize "│" 'face 'my/approval-separator-face))
        ;; Center panel
        (insert " " center))
      (unless (= i (1- max-lines))
        (insert "\n")))))

(defun my/approval--build-left-panel ()
  "Build list of strings for the left panel (request titles)."
  (let ((lines nil)
        (idx 0))
    (dolist (req my/approval--requests)
      (let* ((title (or (plist-get req :title) "Untitled"))
             (selected (= idx my/approval--request-index))
             (indicator (if selected "▸ " "  "))
             (text (concat indicator (truncate-string-to-width
                                      title (- my/approval-left-panel-width 2) 0 ?\s)))
             (face (if selected 'my/approval-selected-title-face 'my/approval-title-face)))
        (push (propertize text 'face face) lines))
      (cl-incf idx))
    (nreverse lines)))

(defun my/approval--build-center-panel (req)
  "Build list of strings for the center panel showing REQ details."
  (let ((lines nil)
        (req-type (plist-get req :type))
        (items (plist-get req :items))
        (notes (plist-get req :notes))
        (desc (plist-get req :description)))
    ;; Description line
    (when (and desc (not (string-empty-p desc)))
      (push (propertize desc 'face 'font-lock-comment-face) lines)
      (push "" lines))
    ;; Items based on type
    (cond
     ((equal req-type "checklist")
      (let ((idx 0))
        (dolist (item items)
          (let* ((checked (plist-get item :checked))
                 (label (or (plist-get item :label) "?"))
                 (checkbox (if checked
                               (propertize "☑" 'face 'my/approval-checkbox-checked-face)
                             (propertize "☐" 'face 'my/approval-checkbox-unchecked-face)))
                 (highlighted (and (eq my/approval--focus 'center)
                                   (= idx my/approval--item-index)))
                 (text (concat " " checkbox " " label)))
            (when highlighted
              (setq text (propertize text 'face 'my/approval-item-highlight-face)))
            (push text lines))
          (cl-incf idx))))
     ((equal req-type "choice")
      (let ((idx 0))
        (dolist (item items)
          (let* ((selected (plist-get item :selected))
                 (label (or (plist-get item :label) "?"))
                 (desc (plist-get item :description))
                 (radio (if selected
                            (propertize "◉" 'face 'my/approval-radio-selected-face)
                          (propertize "○" 'face 'my/approval-radio-unselected-face)))
                 (highlighted (and (eq my/approval--focus 'center)
                                   (= idx my/approval--item-index)))
                 (text (concat " " radio " " label)))
            (when highlighted
              (setq text (propertize text 'face 'my/approval-item-highlight-face)))
            (push text lines)
            (when (and desc (not (string-empty-p desc)))
              (let ((desc-text (concat "   " desc)))
                (push (propertize desc-text 'face 'my/approval-item-description-face) lines))))
          (cl-incf idx)))))
    ;; Refine
    (let ((refine (plist-get req :refine)))
      (when (and refine (not (string-empty-p refine)))
        (push "" lines)
        (push (propertize (concat "Refine: " refine) 'face 'my/approval-notes-face) lines)))
    ;; Notes
    (when (and notes (not (string-empty-p notes)))
      (push "" lines)
      (push (propertize (concat "Notes: " notes) 'face 'my/approval-notes-face) lines))
    ;; Submit hint
    (push "" lines)
    (push (propertize "[RET toggle] [C-Ret submit] [q dismiss] [Q hide] [o open] [r refine] [C-k collapse]" 'face 'my/approval-hint-face) lines)
    (nreverse lines)))

(defun my/approval--render-collapsed ()
  "Render a single-line summary bar for the collapsed state."
  (let* ((count (length my/approval--requests))
         (latest-title (when my/approval--requests
                         (plist-get (car my/approval--requests) :title)))
         (summary (cond
                   ((zerop count)
                    "▶ No pending approvals")
                   (latest-title
                    (format "▶ %d pending approval%s — latest: \"%s\"  [C-k expand]"
                            count (if (= count 1) "" "s")
                            (truncate-string-to-width latest-title 50)))
                   (t
                    (format "▶ %d pending approval%s  [C-k expand]"
                            count (if (= count 1) "" "s"))))))
    (insert (propertize summary 'face 'my/approval-collapsed-face))))

(defun my/approval--display-window (height)
  "Display the approval buffer in a side window with HEIGHT lines."
  (let* ((buf (my/approval--get-or-create-buffer))
         (win (get-buffer-window buf t)))
    (when win (delete-window win))
    (let ((new-win (display-buffer-in-side-window
                    buf
                    `((side . bottom)
                      (slot . 0)
                      (window-height . ,height)
                      (dedicated . t)))))
      (when new-win
        (my/approval--set-window-params new-win))
      new-win)))

(defun my/approval-toggle-collapse ()
  "Toggle between expanded and collapsed approval window."
  (interactive)
  (let ((buf (get-buffer my/approval-buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq my/approval--collapsed (not my/approval--collapsed))
        (setq header-line-format
              (unless my/approval--collapsed
                (propertize " Approval Queue" 'face 'bold))))
      (let ((height (if (buffer-local-value 'my/approval--collapsed buf)
                        1
                      my/approval-window-height)))
        (my/approval--display-window height))
      (my/approval--render))))

;;; ---- Navigation Commands ----------------------------------------------------

(defun my/approval-prev-request ()
  "Move to the previous request in the left panel."
  (interactive)
  (when (> my/approval--request-index 0)
    (cl-decf my/approval--request-index)
    (setq my/approval--item-index 0)
    (my/approval--render)))

(defun my/approval-next-request ()
  "Move to the next request in the left panel."
  (interactive)
  (when (< my/approval--request-index (1- (length my/approval--requests)))
    (cl-incf my/approval--request-index)
    (setq my/approval--item-index 0)
    (my/approval--render)))

(defun my/approval-prev-item ()
  "Move to the previous item in the current request."
  (interactive)
  (my/approval--maybe-refresh-from-disk)
  (when-let ((req (my/approval--current-request)))
    (setq my/approval--focus 'center)
    (when (> my/approval--item-index 0)
      (cl-decf my/approval--item-index))
    (my/approval--render)))

(defun my/approval-next-item ()
  "Move to the next item in the current request."
  (interactive)
  (my/approval--maybe-refresh-from-disk)
  (when-let ((req (my/approval--current-request)))
    (setq my/approval--focus 'center)
    (when (< my/approval--item-index (1- (length (plist-get req :items))))
      (cl-incf my/approval--item-index))
    (my/approval--render)))

(defun my/approval-toggle-item ()
  "Toggle the current item.
When collapsed, expand instead.
For checklist: toggle checkbox on/off.
For choice: radio-select current item (deselect all others)."
  (interactive)
  (if my/approval--collapsed
      (my/approval-toggle-collapse)
    (when-let ((req (my/approval--current-request)))
      (let ((items (plist-get req :items))
            (req-type (plist-get req :type)))
        (cond
         ((equal req-type "checklist")
          (let ((item (nth my/approval--item-index items)))
            (when item
              (plist-put item :checked (not (plist-get item :checked))))))
         ((equal req-type "choice")
          (let ((item (nth my/approval--item-index items)))
            (when item
              (dolist (it items)
                (plist-put it :selected nil))
              (plist-put item :selected t)))))
        (my/approval--write-review-file req)
        (my/approval--render)))))

(defun my/approval-prev-choice ()
  "Select the previous choice in choice mode."
  (interactive)
  (my/approval--cycle-choice -1))

(defun my/approval-next-choice ()
  "Select the next choice in choice mode."
  (interactive)
  (my/approval--cycle-choice 1))

(defun my/approval--cycle-choice (delta)
  "Move choice selection by DELTA (+1 or -1)."
  (when-let ((req (my/approval--current-request)))
    (when (equal (plist-get req :type) "choice")
      (let* ((items (plist-get req :items))
             (count (length items))
             (current-idx (cl-position-if
                           (lambda (it) (plist-get it :selected))
                           items))
             (new-idx (if current-idx
                          (mod (+ current-idx delta) count)
                        0)))
        ;; Deselect all, select new
        (dolist (it items)
          (plist-put it :selected nil))
        (plist-put (nth new-idx items) :selected t)
        (my/approval--write-review-file req)
        (my/approval--render)))))

(defun my/approval-add-item ()
  "Add a new checklist item to the current request."
  (interactive)
  (when-let ((req (my/approval--current-request)))
    (when (equal (plist-get req :type) "checklist")
      (let ((label (read-string "New item: ")))
        (when (and label (not (string-empty-p label)))
          (let ((new-item (list :id (format "user-%d" (float-time))
                                :label label
                                :checked t)))
            (plist-put req :items (append (plist-get req :items) (list new-item)))
            (my/approval--write-review-file req)
            (my/approval--render)))))))

(defun my/approval-edit-notes ()
  "Add or edit notes for the current request."
  (interactive)
  (when-let ((req (my/approval--current-request)))
    (let* ((current (or (plist-get req :notes) ""))
           (new-notes (read-string "Notes: " current)))
      (plist-put req :notes new-notes)
      (my/approval--write-review-file req)
      (my/approval--render))))

(defun my/approval-edit-refine ()
  "Add or edit refine instructions for the current request."
  (interactive)
  (when-let ((req (my/approval--current-request)))
    (let* ((current (or (plist-get req :refine) ""))
           (new-refine (read-string "Refine: " current)))
      (plist-put req :refine new-refine)
      (my/approval--write-review-file req)
      (my/approval--render))))

(defun my/approval-focus-center ()
  "Switch focus to the center panel.  Expand if collapsed."
  (interactive)
  (if my/approval--collapsed
      (my/approval-toggle-collapse)
    (setq my/approval--focus 'center)
    (my/approval--render)))

(defun my/approval-focus-left ()
  "Switch focus back to the left panel."
  (interactive)
  (setq my/approval--focus 'left)
  (my/approval--render))

;;; ---- Submission -------------------------------------------------------------

(defun my/approval--format-submission (req)
  "Format REQ into a «TEAM» submission message string."
  (let* ((request-id (plist-get req :request-id))
         (title (or (plist-get req :title) "Untitled"))
         (req-type (or (plist-get req :type) "checklist"))
         (items (plist-get req :items))
         (notes (plist-get req :notes))
         (selected-lines
          (mapconcat
           (lambda (item)
             (let ((label (or (plist-get item :label) "?"))
                   (id (or (plist-get item :id) "?")))
               (cond
                ((equal req-type "checklist")
                 (format "- [%s] %s (%s)"
                         (if (plist-get item :checked) "x" " ")
                         label id))
                ((equal req-type "choice")
                 (format "- [%s] %s (%s)"
                         (if (plist-get item :selected) "x" " ")
                         label id)))))
           items "\n")))
    (concat "«TEAM»\n"
            (format "Approval Response [request-id: %s]\n" request-id)
            (format "Title: %s\n" title)
            (format "Type: %s\n" req-type)
            "\nSelected:\n"
            selected-lines "\n"
            (let ((refine (plist-get req :refine)))
              (when (and refine (not (string-empty-p refine)))
                (format "\nRefine:\n%s\n" refine)))
            (when (and notes (not (string-empty-p notes)))
              (format "\nNotes:\n%s\n" notes))
            (let ((decisions (plist-get req :decisions)))
              (when decisions
                (concat "\nDecisions:\n"
                        (mapconcat
                         (lambda (d)
                           (format "- %s → %s"
                                   (plist-get d :decision)
                                   (plist-get d :reaction)))
                         decisions "\n")
                        "\n")))
            "«/TEAM»")))

(defun my/approval--format-cancellation (req)
  "Format REQ into a «TEAM» cancellation message string."
  (let ((request-id (plist-get req :request-id))
        (title (or (plist-get req :title) "Untitled")))
    (concat "«TEAM»\n"
            (format "Approval Cancelled [request-id: %s]\n" request-id)
            (format "Title: %s\n" title)
            "«/TEAM»")))

(defun my/approval-submit ()
  "Submit the current request's approval response to the lead."
  (interactive)
  (let ((req (my/approval--current-request)))
    (unless req
      (user-error "No request selected"))
    (let* ((msg (my/approval--format-submission req))
           (lead-buf (agent-shell-team--get-lead agent-shell-team--session-id)))
      (unless (buffer-live-p lead-buf)
        (user-error "Lead buffer not found"))
      (let ((status (agent-shell-team--agent-status lead-buf)))
        (if (eq status 'idle)
            (with-current-buffer lead-buf
              (shell-maker-submit :input msg))
          (agent-shell-team--queue-message
           nil lead-buf
           (list :from "approval-ui"
                 :title "Approval Response"
                 :message msg))
          (agent-shell-team--start-drain-timer)))
      ;; Delete review file and remove submitted request from list
      (my/approval--delete-review-file req)
      (setq my/approval--requests
            (cl-remove-if (lambda (r)
                            (equal (plist-get r :request-id)
                                   (plist-get req :request-id)))
                          my/approval--requests))
      (my/approval--clamp-indices)
      (my/approval--render)
      (message "Approval submitted."))))

;;; ---- Window Management ------------------------------------------------------

(defun my/approval--get-or-create-buffer ()
  "Return the approval buffer, creating it if necessary."
  (or (get-buffer my/approval-buffer-name)
      (with-current-buffer (get-buffer-create my/approval-buffer-name)
        (my/approval-mode)
        (current-buffer))))

(defun my/approval--show ()
  "Display the approval queue in a bottom side window."
  (let ((buf (my/approval--get-or-create-buffer)))
    (unless (get-buffer-window buf)
      (let ((win (display-buffer-in-side-window
                  buf
                  `((side . bottom)
                    (slot . 0)
                    (window-height . ,my/approval-window-height)
                    (dedicated . t)))))
        (when win
          (my/approval--set-window-params win))))
    (my/approval--render)))

(defun my/approval--hide ()
  "Hide the approval window without killing the buffer."
  (let ((win (get-buffer-window my/approval-buffer-name t)))
    (when win
      (delete-window win))))

(defun my/approval--set-window-params (win)
  "Set protective window parameters on WIN."
  (when (window-live-p win)
    (set-window-parameter win 'no-delete-other-windows t)
    (set-window-parameter win 'no-other-window t)
    (set-window-parameter win 'dedicated t)
    (set-window-dedicated-p win t)))

(defun my/approval-dismiss ()
  "Cancel/dismiss the current request, keeping the window open.
Sends a cancellation message to the lead for the currently selected
request and removes it from the queue.  The window stays open showing
remaining requests or an empty state."
  (interactive)
  (let ((req (my/approval--current-request)))
    (when req
      (let* ((msg (my/approval--format-cancellation req))
             (lead-buf (agent-shell-team--get-lead agent-shell-team--session-id)))
        (when (buffer-live-p lead-buf)
          (let ((status (agent-shell-team--agent-status lead-buf)))
            (if (eq status 'idle)
                (with-current-buffer lead-buf
                  (shell-maker-submit :input msg))
              (agent-shell-team--queue-message
               nil lead-buf
               (list :from "approval-ui"
                     :title "Approval Cancelled"
                     :message msg))
              (agent-shell-team--start-drain-timer))))
        ;; Delete review file and remove cancelled request from list
        (my/approval--delete-review-file req)
        (setq my/approval--requests
              (cl-remove-if (lambda (r)
                              (equal (plist-get r :request-id)
                                     (plist-get req :request-id)))
                            my/approval--requests))))
    (my/approval--clamp-indices)
    (my/approval--render)
    (when req
      (message "Approval dismissed."))))

(defun my/approval-hide ()
  "Hide the approval window without cancelling any request."
  (interactive)
  (my/approval--hide))

(defun my/approval-refresh ()
  "Re-read from disk if changed, then re-render the approval buffer."
  (interactive)
  (my/approval--maybe-refresh-from-disk)
  (my/approval--render))

(defun my/approval-open-review-file ()
  "Open the current request's markdown file for editing."
  (interactive)
  (when-let ((req (my/approval--current-request)))
    (let ((file (my/approval--review-file-path (plist-get req :request-id))))
      (if (file-exists-p file)
          (find-file-other-window file)
        ;; File doesn't exist yet — create it first
        (my/approval--write-review-file req)
        (find-file-other-window file)))))

;;; ---- Entry Point ------------------------------------------------------------

(defun my/approval--receive-request (request)
  "Receive a new approval REQUEST plist and show it.
REQUEST keys: :request-id :title :description :type
:items :notes :timestamp."
  ;; Default timestamp if not provided
  (unless (plist-get request :timestamp)
    (plist-put request :timestamp (float-time)))
  ;; Check if review file exists on disk (TS server writes it first)
  (let* ((slug (plist-get request :request-id))
         (file (my/approval--review-file-path slug)))
    (when (file-exists-p file)
      ;; Re-parse from disk to get canonical state
      (let ((disk-req (my/approval--parse-review-file file)))
        (when disk-req
          (plist-put request :title (plist-get disk-req :title))
          (plist-put request :description (plist-get disk-req :description))
          (plist-put request :type (plist-get disk-req :type))
          (plist-put request :items (plist-get disk-req :items))
          (plist-put request :notes (plist-get disk-req :notes))
          (plist-put request :refine (plist-get disk-req :refine))
          (plist-put request :decisions (plist-get disk-req :decisions))
          (plist-put request :file-mtime (plist-get disk-req :file-mtime))))))
  ;; Ensure items have proper structure
  (when (equal (plist-get request :type) "checklist")
    (dolist (item (plist-get request :items))
      (unless (plist-member item :checked)
        (plist-put item :checked nil))))
  (when (equal (plist-get request :type) "choice")
    ;; Ensure at least one item is selected
    (let ((items (plist-get request :items)))
      (unless (cl-some (lambda (it) (plist-get it :selected)) items)
        (when items
          (plist-put (car items) :selected t)))))
  ;; Dedup: replace existing request with same :request-id, or push new
  (let ((existing (cl-find-if
                   (lambda (r)
                     (equal (plist-get r :request-id)
                            (plist-get request :request-id)))
                   my/approval--requests)))
    (if existing
        ;; Replace in-place
        (let ((pos (cl-position existing my/approval--requests :test #'eq)))
          (setf (nth pos my/approval--requests) request))
      ;; New request — push to front
      (push request my/approval--requests)))
  ;; Always expand on new request (exit collapsed mode)
  (when-let ((buf (get-buffer my/approval-buffer-name)))
    (with-current-buffer buf
      (setq my/approval--collapsed nil
            header-line-format (propertize " Approval Queue" 'face 'bold))))
  ;; Show window at full height and render
  (my/approval--display-window my/approval-window-height)
  ;; Select the newly added request (it's at index 0 after push)
  (when-let ((buf (get-buffer my/approval-buffer-name)))
    (with-current-buffer buf
      (setq my/approval--request-index 0
            my/approval--item-index 0
            my/approval--focus 'left)))
  (my/approval--render)
  ;; Auto-focus the approval window
  (when-let ((win (get-buffer-window my/approval-buffer-name t)))
    (select-window win))
  ;; Desktop notification
  (notifications-notify
   :title "Approval Request"
   :body (format "Approval needed: %s" (plist-get request :title))
   :urgency 'critical))

;;; ---- Auto-refresh on window focus -------------------------------------------

(defun my/approval--on-window-selection-change (_frame)
  "Refresh from disk when the approval window gains focus."
  (when (and (eq major-mode 'my/approval-mode)
             my/approval--requests)
    (my/approval--maybe-refresh-from-disk)
    (my/approval--render)))

(add-hook 'window-selection-change-functions #'my/approval--on-window-selection-change)

(provide 'my-approval-ui)
;;; my-approval-ui.el ends here
