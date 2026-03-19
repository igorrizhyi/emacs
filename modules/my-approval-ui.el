;;; my-approval-ui.el --- Approval queue UI for lead agent options -*- lexical-binding: t; -*-

;; Author: Igor Rizhyi
;; Keywords: tools, ai, team

;;; Commentary:

;; Bottom split window for reviewing and approving lead agent options.
;; Supports checklist and choice request types with keyboard navigation.

;;; Code:

(require 'cl-lib)

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

;;; ---- Data -------------------------------------------------------------------

(defvar my/approval--requests nil
  "List of pending request plists.
Each has keys :request-id :title :description :type
:items :notes :timestamp.
Checklist :items are plists (:id :label :checked).
Choice :items are plists (:id :label :selected).")

;;; ---- Buffer-local State -----------------------------------------------------

(defvar-local my/approval--request-index 0
  "Index of the currently selected request in `my/approval--requests'.")

(defvar-local my/approval--item-index 0
  "Index of the currently highlighted item within the current request.")

(defvar-local my/approval--focus 'left
  "Which panel has focus: `left' or `center'.")

;;; ---- Keymap -----------------------------------------------------------------

(defvar my/approval-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<up>") #'my/approval-prev-request)
    (define-key map (kbd "<down>") #'my/approval-next-request)
    (define-key map "j" #'my/approval-next-item)
    (define-key map "k" #'my/approval-prev-item)
    (define-key map " " #'my/approval-toggle-item)
    (define-key map (kbd "<left>") #'my/approval-prev-choice)
    (define-key map (kbd "<right>") #'my/approval-next-choice)
    (define-key map "a" #'my/approval-add-item)
    (define-key map "i" #'my/approval-edit-notes)
    (define-key map (kbd "C-<return>") #'my/approval-submit)
    (define-key map "q" #'my/approval-quit)
    (define-key map "g" #'my/approval-refresh)
    (define-key map (kbd "RET") #'my/approval-focus-center)
    (define-key map (kbd "ESC") #'my/approval-focus-left)
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
    " " #'my/approval-toggle-item
    (kbd "<left>") #'my/approval-prev-choice
    (kbd "<right>") #'my/approval-next-choice
    "a" #'my/approval-add-item
    "i" #'my/approval-edit-notes
    (kbd "C-<return>") #'my/approval-submit
    "q" #'my/approval-quit
    "g" #'my/approval-refresh
    (kbd "RET") #'my/approval-focus-center
    (kbd "ESC") #'my/approval-focus-left))

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
          (if (null my/approval--requests)
              (insert (propertize "  No pending requests." 'face 'my/approval-hint-face))
            (my/approval--render-panels))
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
    ;; Notes
    (when (and notes (not (string-empty-p notes)))
      (push "" lines)
      (push (propertize (concat "Notes: " notes) 'face 'my/approval-notes-face) lines))
    ;; Submit hint
    (push "" lines)
    (push (propertize "[C-Ret to submit]" 'face 'my/approval-hint-face) lines)
    (nreverse lines)))

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
  (when-let ((req (my/approval--current-request)))
    (setq my/approval--focus 'center)
    (when (> my/approval--item-index 0)
      (cl-decf my/approval--item-index))
    (my/approval--render)))

(defun my/approval-next-item ()
  "Move to the next item in the current request."
  (interactive)
  (when-let ((req (my/approval--current-request)))
    (setq my/approval--focus 'center)
    (when (< my/approval--item-index (1- (length (plist-get req :items))))
      (cl-incf my/approval--item-index))
    (my/approval--render)))

(defun my/approval-toggle-item ()
  "Toggle the current item.
For checklist: toggle checkbox on/off.
For choice: radio-select current item (deselect all others)."
  (interactive)
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
      (my/approval--render))))

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
            (my/approval--render)))))))

(defun my/approval-edit-notes ()
  "Add or edit notes for the current request."
  (interactive)
  (when-let ((req (my/approval--current-request)))
    (let* ((current (or (plist-get req :notes) ""))
           (new-notes (read-string "Notes: " current)))
      (plist-put req :notes new-notes)
      (my/approval--render))))

(defun my/approval-focus-center ()
  "Switch focus to the center panel."
  (interactive)
  (setq my/approval--focus 'center)
  (my/approval--render))

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
            (when (and notes (not (string-empty-p notes)))
              (format "\nNotes:\n%s\n" notes))
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
      ;; Remove submitted request from list
      (setq my/approval--requests
            (cl-remove-if (lambda (r)
                            (equal (plist-get r :request-id)
                                   (plist-get req :request-id)))
                          my/approval--requests))
      (if my/approval--requests
          (progn
            (my/approval--clamp-indices)
            (my/approval--render))
        (my/approval-quit))
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

(defun my/approval-quit ()
  "Cancel the current request and hide the approval window.
Sends a cancellation message to the lead for the currently selected
request, removes it from the queue, and hides the window if empty."
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
        ;; Remove cancelled request from list
        (setq my/approval--requests
              (cl-remove-if (lambda (r)
                              (equal (plist-get r :request-id)
                                     (plist-get req :request-id)))
                            my/approval--requests))))
    (if my/approval--requests
        (progn
          (my/approval--clamp-indices)
          (my/approval--render))
      (my/approval--hide))
    (when req
      (message "Approval cancelled."))))

(defun my/approval-refresh ()
  "Re-render the approval buffer."
  (interactive)
  (my/approval--render))

;;; ---- Entry Point ------------------------------------------------------------

(defun my/approval--receive-request (request)
  "Receive a new approval REQUEST plist and show it.
REQUEST keys: :request-id :title :description :type
:items :notes :timestamp."
  ;; Default timestamp if not provided
  (unless (plist-get request :timestamp)
    (plist-put request :timestamp (float-time)))
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
  ;; Add to list
  (push request my/approval--requests)
  ;; Show window and render
  (my/approval--show)
  ;; Select the newly added request (it's at index 0 after push)
  (when-let ((buf (get-buffer my/approval-buffer-name)))
    (with-current-buffer buf
      (setq my/approval--request-index 0
            my/approval--item-index 0
            my/approval--focus 'left)))
  (my/approval--render))

(provide 'my-approval-ui)
;;; my-approval-ui.el ends here
