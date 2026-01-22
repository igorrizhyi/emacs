;;; my-eshell-funcs.el --- Kubernetes helper functions for eshell -*- lexical-binding: t; -*-

;;; Commentary:
;; Command expansion triggered by space - replaces as you type.
;; Some commands expand to templates with cursor placement.
;; Output styling and eat integration is handled by claude-code-terminal.el

;;; Code:

(require 'eshell)

;; Forward declarations for claude-code-terminal functions
(declare-function claude-code-terminal-setup-eat "claude-code-terminal")
(declare-function claude-code-terminal--is-embedded-command-p "claude-code-terminal")
(declare-function claude-code-terminal--set-state "claude-code-terminal")

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

(defun my-eshell-enable-eat ()
  "Enable eat-eshell-mode globally if not already enabled."
  (when (fboundp 'claude-code-terminal-setup-eat)
    (claude-code-terminal-setup-eat)))

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
         (is-embedded nil))
    ;; Handle simple expansions
    (when simple-entry
      (let* ((data (cdr simple-entry))
             (is-plist (and (listp data) (plist-get data :cmd)))
             (replacement (if is-plist
                              (funcall (plist-get data :cmd))
                            (if (functionp data) (funcall data) data)))
             (eat (and is-plist (plist-get data :eat))))
        (when eat
          (setq is-embedded t))
        (delete-region eshell-last-output-end (point))
        (insert replacement)
        ;; Re-read input after expansion for embedded check
        (setq input (string-trim (my-eshell-get-current-input)))))
    ;; Check if command needs embedded mode (ssh, docker exec -it, etc)
    (when (and (fboundp 'claude-code-terminal--is-embedded-command-p)
               (claude-code-terminal--is-embedded-command-p input))
      (setq is-embedded t))
    ;; Set embedded mode state for output styling
    (when (fboundp 'claude-code-terminal--set-state)
      (claude-code-terminal--set-state :embedded-mode is-embedded)))
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

(provide 'my-eshell-funcs)
;;; my-eshell-funcs.el ends here
