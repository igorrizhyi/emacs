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
(declare-function claude-code-terminal--get-state "claude-code-terminal")
(declare-function claude-code-terminal-spawn-mistty "claude-code-terminal")
(declare-function claude-code-terminal-has-active-mistty-p "claude-code-terminal")
(declare-function claude-code-terminal-send-command-to-mistty "claude-code-terminal")

(defvar my-eshell-default-namespace "webpush"
  "Default Kubernetes namespace for kubectl commands.")

;; Simple expansions - just replace text, cursor at end
(defvar my-eshell-simple-expansions
  '(("kpods" . "kubectl -n webpush get pods")
    ("kkafka" . (:cmd my-eshell--kafka-cmd :eat t))
    ("prod" . my-eshell--kprod)
    ("stage" . my-eshell--kstaging)
    ("bts00" . my-eshell--kbts00)
    ("hel02" . my-eshell--khel02)
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

(defun my-eshell--kbts00 ()
  (setenv "KUBECONFIG" "/home/igorrizhyi/.kube/bts_00")
  "echo 'Switched to BTS00'")

(defun my-eshell--khel02 ()
  (setenv "KUBECONFIG" "/home/igorrizhyi/.kube/hel02")
  "echo 'Switched to HEL02'")

(defun my-eshell--kdev ()
  (setenv "KUBECONFIG" "/home/igorrizhyi/.kube/dev")
  "echo 'Switched to DEV'")

(defun my-eshell--kctx ()
  (format "echo 'KUBECONFIG=%s'" (or (getenv "KUBECONFIG") "default")))

(defun eshell/grep (&rest args)
  "Run external grep with -h to suppress filename prefix."
  (throw 'eshell-replace-command
         (eshell-parse-command "*grep" (cons "-h" args))))

;; Alias for grep in pipelines (eshell/grep only works for direct calls)
(add-hook 'eshell-mode-hook
          (lambda ()
            (eshell/alias "grep" "*grep -h $*")))

(defvar my-eshell-dired-return-info nil
  "Plist with :buffer for eshell to return to after dired quit.")

(defun eshell/d (&optional dir)
  "Open dired in DIR (default: current directory).
On quit, return to eshell and cd to dired's final directory."
  (setq my-eshell-dired-return-info (list :buffer (current-buffer)))
  (dired (or dir default-directory)))

(defun my-dired-return-to-eshell-advice (orig-fn &rest args)
  "Advice for dirvish-quit to return to eshell with new directory."
  (let ((info my-eshell-dired-return-info)
        (new-dir default-directory))
    (setq my-eshell-dired-return-info nil)
    (apply orig-fn args)
    (when-let* ((eshell-buf (plist-get info :buffer))
                ((buffer-live-p eshell-buf)))
      (switch-to-buffer eshell-buf)
      (goto-char (point-max))
      (eshell/cd new-dir)
      (eshell-emit-prompt))))

(when (fboundp 'dirvish-quit)
  (advice-add 'dirvish-quit :around #'my-dired-return-to-eshell-advice))
(with-eval-after-load 'dirvish
  (advice-add 'dirvish-quit :around #'my-dired-return-to-eshell-advice))

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
  "Expand and execute on enter.
For embedded commands (ssh, kubectl exec -it, etc.), spawns mistty in a split."
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

    ;; For embedded commands, spawn mistty instead of running in eshell
    (if (and is-embedded
             (not (string-empty-p input))
             (fboundp 'claude-code-terminal-spawn-mistty))
        (progn
          ;; Clear the input line (don't execute in eshell)
          (delete-region eshell-last-output-end (point))
          ;; Add a note to eshell showing what was spawned
          (insert (format "# Spawning in mistty: %s" input))
          (eshell-send-input)
          ;; Spawn mistty with the command
          (claude-code-terminal-spawn-mistty input))
      ;; Regular command - run in eshell
      (when (fboundp 'claude-code-terminal--set-state)
        (claude-code-terminal--set-state :embedded-mode is-embedded))
      (eshell-send-input))))

;; Set up keybindings
(defun my-eshell-smart-history-search ()
  "Search history - use terminal C-r if in embedded mode, else consult-history."
  (interactive)
  (let ((embedded (and (fboundp 'claude-code-terminal--get-state)
                       (claude-code-terminal--get-state :embedded-mode))))
    (if (and embedded (bound-and-true-p eat-eshell-mode))
        ;; In embedded mode (ssh, etc) - send C-r to terminal
        (eat-self-input 1 ?\C-r)
      ;; Normal eshell - use consult-history
      (if (fboundp 'consult-history)
          (consult-history)
        (eshell-previous-matching-input-from-input "")))))

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
