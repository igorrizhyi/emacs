;;; my-eshell-funcs.el --- Kubernetes helper functions for eshell -*- lexical-binding: t; -*-

;;; Commentary:
;; Command expansion triggered by space - replaces as you type.
;; Some commands expand to templates with cursor placement.
;; Interactive commands auto-enable eat-eshell-mode.

;;; Code:

(require 'eshell)

(defvar my-eshell-default-namespace "webpush"
  "Default Kubernetes namespace for kubectl commands.")

;; Simple expansions - just replace text, cursor at end
(defvar my-eshell-simple-expansions
  '(("kpods" . "kubectl -n webpush get pods")
    ("kkafka" . (:cmd my-eshell--kafka-cmd :eat t))
    ("kprod" . my-eshell--kprod)
    ("kstaging" . my-eshell--kstaging)
    ("kdev" . my-eshell--kdev)
    ("kctx" . my-eshell--kctx))
  "Commands that expand on enter or space.")

;; Template expansions - | marks cursor position
;; :eat t means enable eat-eshell-mode for this command
(defvar my-eshell-template-expansions
  '(("klogs" . (:template "kubectl logs -n webpush --tail=100 -f \"|\"" :eat nil))
    ("kbash" . (:template "kubectl -n webpush exec -it \"|\" -- /bin/bash" :eat t))
    ("ksh" . (:template "kubectl -n webpush exec -it \"|\" -- /bin/sh" :eat t))
    ("kdjan" . (:template "kubectl -n webpush exec -it \"|\" -- python manage.py shell" :eat t))
    ("kedit" . (:template "kubectl edit deployment/\"|\" -n webpush" :eat nil))
    ("ktop" . (:template "kubectl top pod \"|\"" :eat nil)))
  "Commands that expand to templates with cursor position marked by |.")


(defun my-eshell--kafka-cmd ()
  "Return kafka command based on KUBECONFIG."
  (let ((kubeconfig (getenv "KUBECONFIG")))
    (cond
     ((string= kubeconfig "/home/igorrizhyi/.kube/prod")
      "kubectl -n kafka -c kafka exec -it kafka-0 -- /bin/bash")
     ((string= kubeconfig "/home/igorrizhyi/.kube/staging")
      "kubectl -n kafka -c cp-kafka-broker exec -it cp-kafka-0-0 -- /bin/bash")
     (t
      "kubectl -n webpush-kafka -c cp-kafka-broker exec -it cp-kafka-0 -- /bin/bash"))))

(defun my-eshell--kprod ()
  (setenv "KUBECONFIG" "/home/igorrizhyi/.kube/prod")
  "echo 'Switched to PROD'")

(defun my-eshell--kstaging ()
  (setenv "KUBECONFIG" "/home/igorrizhyi/.kube/staging")
  "echo 'Switched to STAGING'")

(defun my-eshell--kdev ()
  (setenv "KUBECONFIG" "/home/igorrizhyi/.kube/dev")
  "echo 'Switched to DEV'")

(defun my-eshell--kctx ()
  (format "echo 'KUBECONFIG=%s'" (or (getenv "KUBECONFIG") "default")))

(defun my-eshell-get-current-input ()
  "Get current input text in eshell."
  (buffer-substring-no-properties eshell-last-output-end (point)))

;; Use eat functions from claude-code-terminal if available
(declare-function claude-code-terminal-enable-eat "claude-code-terminal")

(defun my-eshell-enable-eat ()
  "Enable eat-eshell-mode if available."
  (if (fboundp 'claude-code-terminal-enable-eat)
      (claude-code-terminal-enable-eat)
    (when (and (fboundp 'eat-eshell-mode)
               (not (bound-and-true-p eat-eshell-mode)))
      (eat-eshell-mode 1))))

(defun my-eshell-expand-template (template &optional enable-eat)
  "Insert TEMPLATE and place cursor at | marker.
If ENABLE-EAT is non-nil, enable eat-eshell-mode."
  (when enable-eat
    (my-eshell-enable-eat))
  (let ((cursor-marker "|"))
    (delete-region eshell-last-output-end (point))
    (let ((start (point)))
      (insert template)
      (goto-char start)
      (when (search-forward cursor-marker nil t)
        (delete-char -1)))))

(defun my-eshell-expand-on-space ()
  "Expand command aliases when space is pressed."
  (interactive)
  (let* ((input (my-eshell-get-current-input))
         (template-entry (assoc input my-eshell-template-expansions))
         (simple-entry (assoc input my-eshell-simple-expansions)))
    (cond
     ;; Template expansion
     (template-entry
      (let* ((data (cdr template-entry))
             (template (plist-get data :template))
             (eat (plist-get data :eat)))
        (my-eshell-expand-template template eat)))
     ;; Simple expansion
     (simple-entry
      (let* ((data (cdr simple-entry))
             (is-plist (and (listp data) (plist-get data :cmd)))
             (replacement (if is-plist
                              (funcall (plist-get data :cmd))
                            (if (functionp data) (funcall data) data)))
             (eat (and is-plist (plist-get data :eat))))
        (when eat
          (my-eshell-enable-eat))
        (delete-region eshell-last-output-end (point))
        (insert replacement)
        (insert " ")))
     ;; No expansion - just insert space
     (t
      (insert " ")))))

(defun my-eshell-expand-on-enter ()
  "Expand and execute on enter."
  (interactive)
  (let* ((input (string-trim (my-eshell-get-current-input)))
         (simple-entry (assoc input my-eshell-simple-expansions))
         (cmd (car (split-string input))))
    ;; Handle simple expansions
    (when simple-entry
      (let* ((data (cdr simple-entry))
             (is-plist (and (listp data) (plist-get data :cmd)))
             (replacement (if is-plist
                              (funcall (plist-get data :cmd))
                            (if (functionp data) (funcall data) data)))
             (eat (and is-plist (plist-get data :eat))))
        (when eat
          (my-eshell-enable-eat))
        (delete-region eshell-last-output-end (point))
        (insert replacement)))
    ;; Check if raw command needs eat mode (ssh, docker exec, etc)
    (when (and (fboundp 'claude-code-terminal-check-eat-command)
               (claude-code-terminal-check-eat-command cmd))
      (my-eshell-enable-eat)))
  (eshell-send-input))

;; Set up keybindings
(defun my-eshell-smart-history-search ()
  "Search history - use terminal C-r if in eat mode, else consult-history."
  (interactive)
  (if (bound-and-true-p eat-eshell-mode)
      ;; In eat mode (ssh, etc) - send C-r to terminal
      (eat-self-input 1 ?\C-r)
    ;; Normal eshell - use consult-history
    (if (fboundp 'consult-history)
        (consult-history)
      (eshell-previous-matching-input-from-input ""))))

(defun my-eshell-setup-expansion-keys ()
  "Set up expansion keybindings in eshell."
  (local-set-key (kbd "SPC") #'my-eshell-expand-on-space)
  (local-set-key (kbd "RET") #'my-eshell-expand-on-enter)
  ;; C-r for smart history search
  (local-set-key (kbd "C-r") #'my-eshell-smart-history-search)
  ;; Override evil bindings
  (when (fboundp 'evil-local-set-key)
    (evil-local-set-key 'insert (kbd "C-r") #'my-eshell-smart-history-search)
    (evil-local-set-key 'normal (kbd "C-r") #'my-eshell-smart-history-search)
    (evil-local-set-key 'emacs (kbd "C-r") #'my-eshell-smart-history-search)))

(add-hook 'eshell-mode-hook #'my-eshell-setup-expansion-keys)

;;; Font size customization - smaller output, normal prompt
(defface my-eshell-output-face
  '((t (:height 0.75)))
  "Face for eshell output (smaller than prompt).")

(defvar-local my-eshell--in-command nil
  "Non-nil when a command is executing.")

(defvar-local my-eshell--first-output t
  "Non-nil before first output chunk of a command.")

(defvar-local my-eshell--output-start-pos nil
  "Position where command output started.")

;; Vertical padding height (0.5 = half line)
(defvar my-eshell-vertical-padding-height 0.5
  "Height of vertical padding as fraction of line height.")

(defun my-eshell-make-vpad ()
  "Create vertical padding string."
  (propertize "\n" 'display `(height ,my-eshell-vertical-padding-height)))

(defun my-eshell-mark-command-start ()
  "Mark that we're executing a command."
  (setq my-eshell--in-command t
        my-eshell--first-output t
        my-eshell--output-start-pos nil))

(defun my-eshell-mark-command-end ()
  "Mark that command finished and add bottom padding."
  ;; Add newline after output
  (when my-eshell--output-start-pos
    (let ((end (marker-position eshell-last-output-start)))
      (when (and end (> end my-eshell--output-start-pos))
        (let ((ov (make-overlay (1- end) end nil nil nil)))
          (overlay-put ov 'after-string "\n")
          (overlay-put ov 'my-eshell-output t)))))
  (setq my-eshell--in-command nil))

(defun my-eshell-fontify-output ()
  "Apply smaller font to command output using overlays."
  (when my-eshell--in-command
    (let ((start (marker-position eshell-last-output-start))
          (end (marker-position eshell-last-output-end)))
      (when (and start end (< start end))
        (let ((text (buffer-substring-no-properties start end)))
          ;; Skip if this looks like a prompt (ends with "$ " or "# ")
          (unless (string-match-p "[$#] $" text)
            ;; Create overlay with fixed boundaries (no extending)
            (let ((ov (make-overlay start end nil nil nil))
                  ;; Make padding have same small height
                  (padding (propertize "  " 'face '(:height 0.85 :inherit nil))))
              (overlay-put ov 'face '(:height 0.85 :inherit nil))
              (overlay-put ov 'line-prefix padding)
              (overlay-put ov 'wrap-prefix padding)
              (overlay-put ov 'evaporate nil)
              (overlay-put ov 'my-eshell-output t)
              ;; Apply line-height t to use actual text height, not inherited
              (let ((inhibit-read-only t))
                (with-silent-modifications
                  (add-text-properties start end '(line-height t))))
              ;; Add newline before first output chunk
              (when my-eshell--first-output
                (overlay-put ov 'before-string "\n")
                (setq my-eshell--first-output nil
                      my-eshell--output-start-pos start)))))))))

(add-hook 'eshell-pre-command-hook #'my-eshell-mark-command-start)
;; Use -90 depth to run BEFORE prompt is emitted
(add-hook 'eshell-post-command-hook #'my-eshell-mark-command-end -90)
(add-hook 'eshell-output-filter-functions #'my-eshell-fontify-output)

(provide 'my-eshell-funcs)
;;; my-eshell-funcs.el ends here
