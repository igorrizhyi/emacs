;;; my-agent-shell-commands.el --- Interactive commands for agent-shell -*- lexical-binding: t; -*-

(defun my/toggle-researcher-backend ()
  "Select researcher agent backend from predefined options.
Changes take effect for newly spawned researcher agents."
  (interactive)
  (let* ((options '(("Claude Sonnet"          . (claude  . "claude-sonnet-4-6"))
                    ("Gemini 2.5 Flash"       . (gemini  . "gemini-2.5-flash"))
                    ("Gemini 2.5 Flash Lite"  . (gemini  . "gemini-2.5-flash-lite"))))
         (choice (completing-read "Researcher backend: " (mapcar #'car options) nil t))
         (entry (alist-get choice options nil nil #'equal))
         (backend (car entry))
         (model (cdr entry)))
    (setf (alist-get 'researcher agent-shell-team-role-backends) backend)
    (setf (alist-get 'researcher agent-shell-team-role-models) model)
    (message "Researcher backend: %s / %s" backend model)))

(defun my/request-research ()
  "Prompt for a research question and model, then send to the team lead."
  (interactive)
  (unless (bound-and-true-p agent-shell-team--session-id)
    (user-error "No active team session"))
  (let* ((question (read-string "Research question: "))
         (_ (when (string-empty-p (string-trim question))
              (user-error "Empty research question")))
         ;; All available models — default first
         (all-models '(("Claude Sonnet"          . "claude-sonnet-4-6")
                       ("Gemini 2.5 Pro"         . "gemini-2.5-pro")
                       ("Gemini 2.5 Flash"       . "gemini-2.5-flash")
                       ("Gemini 2.5 Flash Lite"  . "gemini-2.5-flash-lite")))
         ;; Look up current researcher model from config (supports both symbol and string keys)
         (raw-model (or (alist-get 'researcher agent-shell-team-role-models)
                        (cdr (assoc "researcher" agent-shell-team-role-models))))
         (backend (or (alist-get 'researcher agent-shell-team-role-backends)
                      (cdr (assoc "researcher" agent-shell-team-role-backends))))
         ;; Normalize to a full model ID that exists in all-models
         (current-model
          (or (and raw-model
                   (or ;; Exact match against full IDs
                       (and (seq-find (lambda (e) (equal (cdr e) raw-model)) all-models)
                            raw-model)
                       ;; Substring match for short names like "sonnet" → "claude-sonnet-4-6"
                       (cdr (seq-find (lambda (e) (string-match-p (regexp-quote raw-model) (cdr e)))
                                      all-models))))
              ;; Fallback: derive from backend
              (if (eq backend 'gemini) "gemini-2.5-flash" "claude-sonnet-4-6")))
         ;; Build "Default (<label>)" entry and prepend it
         (default-entry (seq-find (lambda (e) (equal (cdr e) current-model)) all-models))
         (default-label (format "Default (%s)" (or (car default-entry) current-model)))
         (models (cons (cons default-label current-model) all-models))
         (labels (mapcar #'car models))
         (choice (completing-read (format "Model [%s]: " default-label) labels nil t nil nil default-label))
         (model-id (alist-get choice models nil nil #'equal))
         ;; Find lead buffer and deliver
         (lead-buf (agent-shell-team--get-lead agent-shell-team--session-id))
         (message-text (format "[Research Request]\nModel: %s\nPrompt: %s" model-id question)))
    (unless lead-buf
      (user-error "No lead buffer found in session"))
    (if (eq (agent-shell-team--agent-status lead-buf) 'idle)
        (agent-shell-team--prompt-agent lead-buf message-text)
      (agent-shell-team--queue-message agent-shell-team--session-id lead-buf
                                       (list :from "user" :title "Research Request" :message message-text)))
    (message "Research request sent to lead (model: %s)" model-id)))

(provide 'my-agent-shell-commands)
;;; my-agent-shell-commands.el ends here
