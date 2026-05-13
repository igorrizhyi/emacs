;;; my-k8s-quick-actions.el --- K8s quick actions for eshell output -*- lexical-binding: t; -*-

;; When the user presses Enter (normal state) on a line inside a kubectl output
;; block, an inline action menu appears.  The pod name is auto-detected from the
;; first whitespace-delimited token on the current line.  Pressing an action key
;; launches the corresponding kubectl command.
;;
;; Non-streaming results (env, describe, top, deployment YAML) open in a
;; temporary read-only buffer in the same window.  Press `q` to return to
;; eshell.  Streaming commands (logs) run directly in eshell; interactive
;; commands (exec) are handled via claude-code-terminal-spawn-mistty.
;;
;; To activate, call `my-k8s-quick-actions-setup' from `eshell-mode-hook'
;; (already registered at the bottom of this file).

(require 'evil)
(declare-function claude-code-terminal--get-state "claude-code-emacs/claude-code-terminal" (key))
(declare-function claude-code-terminal--set-state "claude-code-emacs/claude-code-terminal" (key value))
(declare-function claude-code-terminal-spawn-mistty "claude-code-emacs/claude-code-terminal" (command))

;;; Buffer-local state

(defvar-local my-k8s--action-overlay nil
  "Overlay holding the inline action menu, or nil when not active.")

(defvar-local my-k8s--action-context nil
  "Plist (:type COMMAND-TYPE :namespace NAMESPACE :pod POD :kubeconfig KUBECONFIG) for the current session.")

(defvar-local my-k8s--source-buffer nil
  "The eshell buffer that spawned the current k8s result buffer.")

(defvar-local my-k8s--result-kubeconfig nil
  "KUBECONFIG path for the kubectl apply command in an editable result buffer.")

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Component 1 — K8s Output Detection
;;; ─────────────────────────────────────────────────────────────────────────────

(defun my-k8s--find-output-block-start ()
  "Return the start position of the kubectl output block at point, or nil.

Finds the earliest `claude-code-terminal-output' overlay at/before point,
then walks backward through contiguous output overlays to find the true
start of the block."
  (let ((block-start nil))
    ;; Find minimum overlay start among output overlays at point
    (dolist (ov (overlays-at (point)))
      (when (overlay-get ov 'claude-code-terminal-output)
        (let ((s (overlay-start ov)))
          (setq block-start (if block-start (min block-start s) s)))))
    (when block-start
      ;; Walk backward through contiguous output overlays
      (let ((check (1- block-start)))
        (while (and (> check (point-min))
                    (cl-some (lambda (ov)
                               (overlay-get ov 'claude-code-terminal-output))
                             (overlays-at check)))
          (setq block-start check)
          (setq check (1- check))))
      block-start)))

(defun my-k8s--find-command-for-output ()
  "Return the command text that produced the output block at point, or nil.

Locates the output block start, steps up one line (the eshell command line),
and strips the prompt prefix (everything up to and including `$ ' or `❯ ')."
  (let ((block-start (my-k8s--find-output-block-start)))
    (when block-start
      (save-excursion
        (goto-char block-start)
        (forward-line -1)
        (let ((line (string-trim
                     (buffer-substring-no-properties
                      (line-beginning-position)
                      (line-end-position)))))
          ;; Strip any prompt prefix before the command
          (if (string-match "[$❯]\\s-+" line)
              (string-trim (substring line (match-end 0)))
            line))))))

(defun my-k8s--parse-kubectl-command (cmd)
  "Parse CMD as a kubectl invocation.
Return (COMMAND-TYPE . NAMESPACE) or nil if CMD is not a kubectl command.

COMMAND-TYPE is one of: pods, deployments, services, containers, generic.
NAMESPACE defaults to \"webpush\" when not found in CMD."
  (when (and cmd (string-match-p "\\`kubectl\\b" cmd))
    (let* ((ns (or (and (string-match
                         "\\(?:-n\\|--namespace\\)\\s-+\\(\\S-+\\)" cmd)
                        (match-string 1 cmd))
                   "webpush"))
           (type (cond
                  ((string-match-p "get pods?\\b" cmd)        'pods)
                  ((string-match-p "get deployments?\\b" cmd) 'deployments)
                  ((string-match-p "get services?\\b\\|get svc\\b" cmd) 'services)
                  ((string-match-p "get containers?\\b" cmd)  'containers)
                  (t                                           'generic))))
      (cons type ns))))

(defun my-k8s--in-k8s-output-p ()
  "Return (COMMAND-TYPE . NAMESPACE) if point is inside a kubectl output block.
Return nil otherwise."
  (when (cl-some (lambda (ov)
                   (overlay-get ov 'claude-code-terminal-output))
                 (overlays-at (point)))
    (my-k8s--parse-kubectl-command (my-k8s--find-command-for-output))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Component 2 — Pod Auto-Detection
;;; ─────────────────────────────────────────────────────────────────────────────

(defun my-k8s--detect-pod-at-line ()
  "Extract pod name from the current line in kubectl output.
Matches the first whitespace-delimited token that looks like a k8s resource name
(contains at least one hyphen and one alphanumeric segment)."
  (let* ((line (string-trim (buffer-substring-no-properties
                              (line-beginning-position) (line-end-position))))
         (first-token (car (split-string line))))
    (when (and first-token (string-match-p "-" first-token))
      first-token)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Component 3 — Inline Action Overlay
;;; ─────────────────────────────────────────────────────────────────────────────

(defun my-k8s--make-menu-string ()
  "Return a propertized string for the inline action menu."
  (let ((face (list :font (font-spec :family "SF Mono" :weight 'semibold)
                    :height 0.75 :inherit nil :background "#372413")))
    (propertize
     (concat "\n"
             "  e — Environment variables   (kubectl exec ... env)\n"
             "  d — Deployment YAML         (kubectl get deployment ... -o yaml)\n"
             "  l — Tail logs               (kubectl logs --tail=100 -f ...)\n"
             "  x — Exec into pod           (kubectl exec -it ... bash)\n"
             "  D — Describe pod            (kubectl describe pod ...)\n"
             "  t — Resource usage          (kubectl top pod ...)\n")
     'face face)))

(defun my-k8s--show-action-overlay ()
  "Place the action menu overlay at the end of the current line."
  (my-k8s--remove-action-overlay)
  (let* ((pos (line-end-position))
         (ov (make-overlay pos pos (current-buffer) nil t)))
    (overlay-put ov 'after-string (my-k8s--make-menu-string))
    (overlay-put ov 'evaporate nil)
    (overlay-put ov 'priority 100)
    (overlay-put ov 'my-k8s-action-overlay t)
    (setq my-k8s--action-overlay ov)))

(defun my-k8s--remove-action-overlay ()
  "Delete the k8s action menu overlay."
  (when (and my-k8s--action-overlay (overlayp my-k8s--action-overlay))
    (delete-overlay my-k8s--action-overlay))
  (setq my-k8s--action-overlay nil))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Component 4 — Transient Keymap
;;; ─────────────────────────────────────────────────────────────────────────────

(defun my-k8s--install-transient-keymap ()
  "Install a transient keymap for k8s actions.  Auto-deactivates on unbound key."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "e") #'my-k8s-action-env)
    (define-key map (kbd "d") #'my-k8s-action-deployment)
    (define-key map (kbd "l") #'my-k8s-action-logs)
    (define-key map (kbd "x") #'my-k8s-action-exec)
    (define-key map (kbd "D") #'my-k8s-action-describe)
    (define-key map (kbd "t") #'my-k8s-action-top)
    (define-key map (kbd "<escape>") #'my-k8s--dismiss)
    (define-key map (kbd "q") #'my-k8s--dismiss)
    (set-transient-map map t #'my-k8s--dismiss)))

(defun my-k8s--dismiss ()
  "Remove the action overlay and clean up."
  (interactive)
  (my-k8s--remove-action-overlay)
  (setq my-k8s--action-context nil))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Component 5 — Enter Action Mode Entry Point
;;; ─────────────────────────────────────────────────────────────────────────────

;;;###autoload
(defun my-k8s-enter-action-mode ()
  "Show K8s quick actions for the pod on the current line.
Called from `my/smart-enter' when cursor is inside kubectl output.
Returns t if actions were shown, nil otherwise."
  (interactive)
  (let ((ctx (my-k8s--in-k8s-output-p))
        (pod (my-k8s--detect-pod-at-line)))
    (message "[k8s] enter-action-mode: ctx=%S pod=%S" ctx pod)
    (when (and ctx pod)
      (setq my-k8s--action-context
            (list :type (car ctx) :namespace (cdr ctx) :pod pod
                  :kubeconfig (if (fboundp 'eshell-get-variable)
                                  (eshell-get-variable "KUBECONFIG")
                                (getenv "KUBECONFIG"))))
      (my-k8s--show-action-overlay)
      (my-k8s--install-transient-keymap)
      t)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Component 6 — Embedded Result Buffer
;;; ─────────────────────────────────────────────────────────────────────────────

(defun my-k8s--show-result-buffer (cmd &optional mode-fn short-desc kubeconfig editable)
  "Run CMD asynchronously and display the output in a dedicated buffer.

MODE-FN, when provided, is called (no arguments) to set the buffer's major
mode after erasure.  SHORT-DESC is used in the buffer name; it defaults to
a truncated version of CMD.  KUBECONFIG, when non-nil, is prepended to
`process-environment' so the subprocess inherits the eshell session's value.

When EDITABLE is non-nil the buffer is left writable after the process
finishes, a `C-c C-c' binding is installed to run `kubectl apply -f -' with
the buffer contents, and a header line explains how to apply changes.

The result buffer opens in the same window as the calling eshell buffer.
Press `q' to kill it and return to eshell."
  (let* ((desc (or short-desc (truncate-string-to-width cmd 40)))
         (buf-name (format "*k8s: %s*" desc))
         (src-buf (current-buffer))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (fundamental-mode)
        (when mode-fn (funcall mode-fn))
        (insert (propertize (format "# %s\n\n" cmd) 'face 'font-lock-comment-face)))
      (setq-local my-k8s--source-buffer src-buf)
      (setq buffer-read-only nil)
      ;; Install quit binding on a copy of the current local map
      (use-local-map (copy-keymap (or (current-local-map)
                                      (make-sparse-keymap))))
      (local-set-key (kbd "q") #'my-k8s--close-result-buffer)
      (when editable
        (setq-local my-k8s--result-kubeconfig kubeconfig)
        (local-set-key (kbd "C-c C-c") #'my-k8s--apply-yaml-buffer)
        (local-set-key (kbd "C-x C-s") #'my-k8s--apply-yaml-buffer)
        (setq header-line-format
              (propertize "  Edit YAML then C-c C-c to kubectl apply  |  q to close"
                          'face 'font-lock-comment-face))))
    (switch-to-buffer buf)
    ;; Launch async process; output appends into buf
    (let* ((process-environment
            (if kubeconfig
                (cons (format "KUBECONFIG=%s" kubeconfig) process-environment)
              process-environment))
           (proc (start-process-shell-command
                  (format "k8s:%s" desc)
                  buf
                  cmd)))
      (set-process-sentinel
       proc
       (lambda (p _event)
         (when (buffer-live-p (process-buffer p))
           (with-current-buffer (process-buffer p)
             (unless editable
               (let ((inhibit-read-only t))
                 (goto-char (point-max))
                 (insert (propertize "\n\n-- done --\n"
                                     'face 'font-lock-comment-face)))
               (setq buffer-read-only t)))))))
    buf))

(defun my-k8s--apply-yaml-buffer ()
  "Pipe the current buffer's contents to `kubectl apply -f -'.
Uses the KUBECONFIG stored when the deployment buffer was opened."
  (interactive)
  (let* ((kubeconfig (bound-and-true-p my-k8s--result-kubeconfig))
         (yaml (buffer-substring-no-properties (point-min) (point-max)))
         (process-environment
          (if kubeconfig
              (cons (format "KUBECONFIG=%s" kubeconfig) process-environment)
            process-environment))
         (out-buf (get-buffer-create "*k8s: apply output*")))
    (with-current-buffer out-buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "# kubectl apply -f -\n\n" 'face 'font-lock-comment-face))))
    (display-buffer out-buf)
    (let ((proc (start-process-shell-command
                 "k8s:apply" out-buf "kubectl apply -f -")))
      (process-send-string proc yaml)
      (process-send-eof proc)
      (set-process-sentinel
       proc
       (lambda (p _event)
         (when (buffer-live-p (process-buffer p))
           (with-current-buffer (process-buffer p)
             (let ((inhibit-read-only t))
               (goto-char (point-max))
               (insert (propertize "\n-- done --\n" 'face 'font-lock-comment-face)))
             (setq buffer-read-only t)))))
      (message "[k8s] kubectl apply started"))))

(defun my-k8s--close-result-buffer ()
  "Kill the k8s result buffer (and any running process) and restore eshell."
  (interactive)
  (let ((src (bound-and-true-p my-k8s--source-buffer)))
    (when-let ((proc (get-buffer-process (current-buffer))))
      (kill-process proc))
    (kill-buffer (current-buffer))
    (when (and src (buffer-live-p src))
      (switch-to-buffer src))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Component 7 — Buffer-Tie Auto-Hide/Show
;;; ─────────────────────────────────────────────────────────────────────────────

(defun my-k8s--window-buffer-change (win)
  "Toggle overlay visibility based on whether this eshell buffer is in WIN.
Added to `window-buffer-change-functions' when the module is active."
  (when (and my-k8s--action-overlay
             (overlayp my-k8s--action-overlay))
    ;; Hide if the window that changed is no longer showing this buffer
    (overlay-put my-k8s--action-overlay 'invisible
                 (not (eq (window-buffer win) (current-buffer))))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Component 8 — Action Helpers and Actions
;;; ─────────────────────────────────────────────────────────────────────────────

(defun my-k8s--infer-deployment (pod-name)
  "Strip the trailing ReplicaSet and pod hash suffixes from POD-NAME.

Example: \"webpush-api-7f8b9c-xz4k2\" → \"webpush-api\".
Matches the pattern: -<5+alnum>-<5alnum> at end of string."
  (replace-regexp-in-string
   "-[a-z0-9]\\{5,\\}-[a-z0-9]\\{5\\}$" "" pod-name))

(defun my-k8s--send-eshell-command (cmd)
  "Clear any pending eshell input, insert CMD, and send it."
  (delete-region eshell-last-output-end (point-max))
  (goto-char eshell-last-output-end)
  (insert cmd)
  (eshell-send-input))

;;; Actions ────────────────────────────────────────────────────────────────────

(defun my-k8s-action-env ()
  "Show sorted environment variables for the pod on the current line."
  (interactive)
  (let* ((pod (plist-get my-k8s--action-context :pod))
         (ns (or (plist-get my-k8s--action-context :namespace) "webpush"))
         (kubeconfig (plist-get my-k8s--action-context :kubeconfig)))
    (message "[k8s] action: env pod=%s ns=%s" pod ns)
    (my-k8s--dismiss)
    (when (and pod (not (string-empty-p pod)))
      (my-k8s--show-result-buffer
       (format "kubectl exec %s -n %s -- env | sort" pod ns)
       nil
       (format "env %s" pod)
       kubeconfig))))

(defun my-k8s-action-deployment ()
  "Show YAML for the deployment inferred from the pod on the current line."
  (interactive)
  (let* ((pod (plist-get my-k8s--action-context :pod))
         (ns (or (plist-get my-k8s--action-context :namespace) "webpush"))
         (deploy (when pod (my-k8s--infer-deployment pod)))
         (kubeconfig (plist-get my-k8s--action-context :kubeconfig)))
    (message "[k8s] action: deployment pod=%s ns=%s deploy=%s" pod ns deploy)
    (my-k8s--dismiss)
    (when (and pod (not (string-empty-p pod)))
      (my-k8s--show-result-buffer
       (format "kubectl get deployment %s -n %s -o yaml" deploy ns)
       (lambda () (when (fboundp 'yaml-mode) (yaml-mode)))
       (format "deploy %s" deploy)
       kubeconfig
       t))))

(defun my-k8s-action-logs ()
  "Tail logs for the pod on the current line, running the command in eshell."
  (interactive)
  (let* ((pod (plist-get my-k8s--action-context :pod))
         (ns (or (plist-get my-k8s--action-context :namespace) "webpush")))
    (message "[k8s] action: logs pod=%s ns=%s" pod ns)
    (my-k8s--dismiss)
    (when (and pod (not (string-empty-p pod)))
      (my-k8s--send-eshell-command
       (format "kubectl logs -n %s --tail=100 -f %s" ns pod)))))

(defun my-k8s-action-exec ()
  "Exec into the pod on the current line via mistty (falls back to eshell)."
  (interactive)
  (let* ((pod (plist-get my-k8s--action-context :pod))
         (ns (or (plist-get my-k8s--action-context :namespace) "webpush"))
         (cmd (format "kubectl exec -it %s -n %s -- /bin/bash" pod ns)))
    (message "[k8s] action: exec pod=%s ns=%s" pod ns)
    (my-k8s--dismiss)
    (when (and pod (not (string-empty-p pod)))
      (if (fboundp 'claude-code-terminal-spawn-mistty)
          (claude-code-terminal-spawn-mistty cmd)
        (my-k8s--send-eshell-command cmd)))))

(defun my-k8s-action-describe ()
  "Describe the pod on the current line."
  (interactive)
  (let* ((pod (plist-get my-k8s--action-context :pod))
         (ns (or (plist-get my-k8s--action-context :namespace) "webpush"))
         (kubeconfig (plist-get my-k8s--action-context :kubeconfig)))
    (message "[k8s] action: describe pod=%s ns=%s" pod ns)
    (my-k8s--dismiss)
    (when (and pod (not (string-empty-p pod)))
      (my-k8s--show-result-buffer
       (format "kubectl describe pod %s -n %s" pod ns)
       nil
       (format "describe %s" pod)
       kubeconfig))))

(defun my-k8s-action-top ()
  "Show resource usage for the pod on the current line."
  (interactive)
  (let* ((pod (plist-get my-k8s--action-context :pod))
         (ns (or (plist-get my-k8s--action-context :namespace) "webpush"))
         (kubeconfig (plist-get my-k8s--action-context :kubeconfig)))
    (message "[k8s] action: top pod=%s ns=%s" pod ns)
    (my-k8s--dismiss)
    (when (and pod (not (string-empty-p pod)))
      (my-k8s--show-result-buffer
       (format "kubectl top pod %s -n %s" pod ns)
       nil
       (format "top %s" pod)
       kubeconfig))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Setup
;;; ─────────────────────────────────────────────────────────────────────────────

;;;###autoload
(defun my-k8s-quick-actions-setup ()
  "Enable K8s quick actions in the current eshell buffer.
Add to `eshell-mode-hook'."
  (add-hook 'window-buffer-change-functions #'my-k8s--window-buffer-change nil t))

(add-hook 'eshell-mode-hook #'my-k8s-quick-actions-setup)

(provide 'my-k8s-quick-actions)
;;; my-k8s-quick-actions.el ends here
