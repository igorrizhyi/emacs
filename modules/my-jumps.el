;;; my-jumps.el --- Smart Evil jump registration with distance threshold -*- lexical-binding: t; -*-

;; Copyright (C) 2024

;; Author: Your Name
;; Keywords: evil, jumps, navigation

;;; Commentary:

;; This module provides smart jump registration for Evil mode that only
;; registers jumps when moving more than a configurable distance threshold.
;; This prevents small movements from cluttering the jump list.

;;; Code:

(require 'evil)

(defvar my/evil-jump-threshold 5
  "Minimum line distance to register an evil jump.")

(defvar my/original-evil--jumps-push nil
  "Store the original evil--jumps-push function.")

(defun my/evil--jumps-push-with-threshold ()
  "Push jump to ring only if moving more than threshold lines from last jump."
  (let* ((current-line (line-number-at-pos))
         (jumps-struct (evil--jumps-get-current))
         (ring (when jumps-struct (evil-jumps-struct-ring jumps-struct)))
         (last-jump (when (and ring (> (ring-length ring) 0))
                     (ring-ref ring 0)))
         (should-jump (if last-jump
                         (let* ((last-pos (car last-jump))
                                (last-file (cadr last-jump))
                                (current-file (buffer-file-name))
                                (last-line (if (and last-file current-file
                                                   (string= last-file current-file))
                                              (save-excursion
                                                (goto-char (if (markerp last-pos)
                                                             (marker-position last-pos)
                                                             last-pos))
                                                (line-number-at-pos))
                                             nil)))
                           (if last-line
                               (>= (abs (- current-line last-line)) my/evil-jump-threshold)
                             t)) ; Different file, always jump
                       t))) ; Always set first jump
    (when should-jump
      (message "Registering jump at line %d" current-line)
      (funcall my/original-evil--jumps-push))
    (unless should-jump
      (message "Skipping jump at line %d (distance < %d)" current-line my/evil-jump-threshold))))

(defun my-jumps-set-threshold (threshold)
  "Set the jump distance threshold to THRESHOLD lines."
  (interactive "nJump threshold (lines): ")
  (setq my/evil-jump-threshold threshold)
  (message "Evil jump threshold set to %d lines" threshold))

;;;###autoload
(define-minor-mode my-smart-jumps-mode
  "Smart Evil jump registration with distance threshold."
  :global t
  :group 'evil
  (if my-smart-jumps-mode
      (progn
        ;; Store original function before overriding
        (unless my/original-evil--jumps-push
          (setq my/original-evil--jumps-push (symbol-function 'evil--jumps-push)))
        (advice-add 'evil--jumps-push :override #'my/evil--jumps-push-with-threshold)
        (message "Smart jumps enabled (threshold: %d lines)" my/evil-jump-threshold))
    (advice-remove 'evil--jumps-push #'my/evil--jumps-push-with-threshold)
    (message "Smart jumps disabled")))

(provide 'my-jumps)
;;; my-jumps.el ends here
