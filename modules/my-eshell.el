;;; my-eshell.el --- Custom eshell functions -*- lexical-binding: t; -*-

(defun eshell/kpods (&optional namespace)
  "Get Kubernetes pods, optionally for a specific namespace.
If no namespace is provided, defaults to 'webpush'.
When used interactively, displays output in a view buffer.
When piped, returns string output for further processing."
  (let ((ns (or namespace "webpush")))
    (if (and (boundp 'eshell-output-handle)
             (eq eshell-output-handle 'eshell-output-handle))
        ;; Interactive use - show in buffer
        (message "Fetching pods in namespace: %s" ns)
        (let ((output (shell-command-to-string 
                       (format "kubectl -n %s get pods" ns))))
          (with-current-buffer (get-buffer-create "*kubectl-pods*")
            (erase-buffer)
            (insert output)
            (goto-char (point-min))
            (view-mode 1)
            (pop-to-buffer (current-buffer)))
          nil) ; Don't print anything to eshell
      ;; Non-interactive (piped) - return string
      (shell-command-to-string (format "kubectl -n %s get pods" ns)))))

(defun eshell/klogs (&optional pod-name namespace)
  "Get logs for a Kubernetes pod.
Usage: klogs [pod-name] [namespace]
If no pod-name provided, prompts for selection.
If no namespace provided, defaults to 'webpush'."
  (let* ((ns (or namespace "webpush"))
         (pod (or pod-name
                  (let ((pods-output (shell-command-to-string 
                                      (format "kubectl -n %s get pods --no-headers -o custom-columns=\":metadata.name\"" ns))))
                    (completing-read "Select pod: " 
                                     (split-string pods-output "\n" t))))))
    (if (and (boundp 'eshell-output-handle)
             (eq eshell-output-handle 'eshell-output-handle))
        ;; Interactive use
        (let ((output (shell-command-to-string 
                       (format "kubectl -n %s logs %s" ns pod))))
          (with-current-buffer (get-buffer-create (format "*kubectl-logs-%s*" pod))
            (erase-buffer)
            (insert output)
            (goto-char (point-min))
            (view-mode 1)
            (pop-to-buffer (current-buffer)))
          nil)
      ;; Piped use
      (shell-command-to-string (format "kubectl -n %s logs %s" ns pod)))))

(defun eshell/kdesc (&optional resource-type resource-name namespace)
  "Describe a Kubernetes resource.
Usage: kdesc [resource-type] [resource-name] [namespace]
Examples: kdesc pod my-pod, kdesc deployment my-app production"
  (let* ((ns (or namespace "webpush"))
         (type (or resource-type "pod"))
         (name (or resource-name
                   (let ((resources-output (shell-command-to-string 
                                            (format "kubectl -n %s get %s --no-headers -o custom-columns=\":metadata.name\"" ns type))))
                     (completing-read (format "Select %s: " type)
                                      (split-string resources-output "\n" t))))))
    (if (and (boundp 'eshell-output-handle)
             (eq eshell-output-handle 'eshell-output-handle))
        ;; Interactive use
        (let ((output (shell-command-to-string 
                       (format "kubectl -n %s describe %s %s" ns type name))))
          (with-current-buffer (get-buffer-create (format "*kubectl-describe-%s-%s*" type name))
            (erase-buffer)
            (insert output)
            (goto-char (point-min))
            (view-mode 1)
            (pop-to-buffer (current-buffer)))
          nil)
      ;; Piped use
      (shell-command-to-string (format "kubectl -n %s describe %s %s" ns type name)))))

(provide 'my-eshell)
;;; my-eshell.el ends here
