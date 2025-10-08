;;; modules/my-font-management.el --- Smart font sizing: small by default, big for code -*- lexical-binding: t; -*-

;;; Commentary:
;; Simple font management:
;; - Small font everywhere by default
;; - Large font only for main code editing buffers

;;; Code:

;; You can customize these settings:
;; Previous font configurations:
;; (defcustom my/font-family "JetBrains Mono"
(defcustom my/font-family "DejaVu Sans Mono"
;; (defcustom my/font-family "Source Code Pro"
  "Font family to use. Available options: Source Code Pro, JetBrains Mono, DejaVu Sans Mono, monospace."
  :type 'string
  :group 'my-font-management)

(defcustom my/small-font-size 20
  "Small font size for auxiliary buffers."
  :type 'integer
  :group 'my-font-management)

(defcustom my/medium-font-scale 1.1
  "Font scale increase for main code buffers (via text-scale-set)."
  :type 'integer
  :group 'my-font-management)

(defcustom my/large-font-scale 1.6
  "Font scale increase for main code buffers (via text-scale-set)."
  :type 'integer
  :group 'my-font-management)

;; Set small font globally by default
;; Using customizable font family (JetBrains Mono by default)
(setq doom-font (font-spec :family my/font-family :size my/small-font-size))

(defun my/is-main-code-buffer-p ()
  "Check if current buffer is a main code editing buffer."
  (and buffer-file-name  ; Has an actual file
       (derived-mode-p 'prog-mode 'text-mode 'conf-mode 'markdown-mode)
       (not (string-match-p "^\\*" (buffer-name)))))  ; Not a special buffer

(defun my/apply-code-buffer-font ()
  "Apply large font to main code buffers and topsy headers."
  (when (and (display-graphic-p)
             (my/is-main-code-buffer-p))
    (text-scale-set my/large-font-scale)   ; Make code buffers bigger
    ;; Also apply large font to topsy sticky header if it exists
    (when (and (fboundp 'topsy-mode) topsy-mode)
      (my/apply-topsy-header-font))))

(defun my/apply-topsy-header-font ()
  "Apply large font to topsy sticky header line (same size as code buffer)."
  (when (display-graphic-p)
    ;; Calculate the same height as text-scale-set would produce
    (let ((scaled-height (round (* (face-attribute 'default :height) 
                                   (expt text-scale-mode-step my/large-font-scale)))))
      ;; Set topsy header line face to match code buffer size
      (set-face-attribute 'header-line nil
                          :family my/font-family
                          :height scaled-height)
      ;; Also set topsy-specific faces if they exist
      (when (facep 'topsy-line)
        (set-face-attribute 'topsy-line nil
                            :family my/font-family
                            :height scaled-height)))))

;; Apply large font when entering code buffers
(add-hook 'find-file-hook #'my/apply-code-buffer-font)
(add-hook 'prog-mode-hook #'my/apply-code-buffer-font)
(add-hook 'text-mode-hook #'my/apply-code-buffer-font)
(add-hook 'conf-mode-hook #'my/apply-code-buffer-font)
(add-hook 'markdown-mode-hook #'my/apply-code-buffer-font)

;; Apply font to topsy header when topsy-mode is enabled
(with-eval-after-load 'topsy
  (add-hook 'topsy-mode-hook #'my/apply-topsy-header-font))

(provide 'my-font-management)

;;; my-font-management.el ends here
