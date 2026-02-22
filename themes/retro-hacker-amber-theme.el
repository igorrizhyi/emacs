;;; retro-hacker-amber-theme.el --- Retro Hacker Amber theme -*- lexical-binding: t; -*-

;; Copyright (C) 2025
;;
;; Author: Generated from VSCode Retro Hacker Amber theme
;; Version: 1.0.0
;; Package-Requires: ((emacs "24"))
;; URL: 

;;; Commentary:
;; A warm amber/orange cyberpunk theme ported from the VSCode Retro Hacker Amber theme.
;; Features warm amber tones on dark backgrounds for that nostalgic retro computer feel.

;;; Code:

(deftheme retro-hacker-amber
  "A warm amber cyberpunk theme inspired by retro terminals.")

(let ((class '((class color) (min-colors 89)))
      ;; Color palette based on Retro Hacker Amber
      (bg-main       "#1a1006")  ; Main background
      (bg-alt        "#261707")  ; Alternative background (sidebars)
      (bg-inactive   "#130c04")  ; Inactive elements
      (bg-active     "#2e1e13")  ; Active line highlight
      (bg-highlight  "#372413")  ; Selection/highlight
      (bg-selection  "#5a3a15") ; Selection background - brownish amber, like line highlight but more visible
      
      (fg-main       "#ffb000")  ; Main foreground (bright amber)
      (fg-alt        "#fcd498")  ; Alternative foreground (light golden)
      (fg-dim        "#c78021")  ; Dimmed text
      (fg-inactive   "#8d7c6a")  ; Inactive text
      
      ;; Syntax colors
      (amber-bright  "#ffb000")  ; Keywords, important
      (amber-gold    "#ffc677")  ; Keywords, control flow
      (amber-orange  "#ff7300")  ; Functions, methods
      (amber-light   "#fcd498")  ; Variables, properties
      (amber-cream   "#fbebd5")  ; Strings
      (amber-dark    "#e99f17")  ; Numbers, constants
      (amber-muted   "#8d7c6a")  ; Comments
      
      ;; UI colors
      ;; (border        "#ff9d00")  ; Borders, focus
      (border        "#1a1006")  ; Borders, focus
      (cursor        "#ffb000")  ; Cursor
      (error         "#ff0000")  ; Errors
      (warning       "#e99f17")  ; Warnings
      (success       "#ff9d00")  ; Success
      (link          "#ffb000")  ; Links
      
      ;; Special colors
      (violet        "#dda0dd")  ; Types, classes
      (blue          "#87ceeb")  ; Built-ins
      (cyan          "#00ced1")  ; Operators
      (green         "#ff9d00")  ; Modified (using amber for consistency)
      (red           "#ff0000")  ; Deleted, errors
      (yellow        "#ffff00")  ; Special highlighting
      )

  (custom-theme-set-faces
   'retro-hacker-amber
   
   ;; Base faces
   `(default ((,class (:background ,bg-main :foreground ,fg-main))))
   `(cursor ((,class (:background ,cursor))))
   `(region ((,class (:background "#5a3a15"))))
   `(highlight ((,class (:background ,bg-highlight))))
   `(secondary-selection ((,class (:background "#5a3a15"))))
   `(isearch ((,class (:background "#2a4d8a" :weight bold))))
   `(lazy-highlight ((,class (:background "#1a3b6b"))))
   `(trailing-whitespace ((,class (:background ,error))))
   
   ;; Font lock (syntax highlighting)
   `(font-lock-builtin-face ((,class (:foreground ,blue))))
   `(font-lock-comment-face ((,class (:foreground ,amber-muted :slant italic))))
   `(font-lock-comment-delimiter-face ((,class (:foreground ,amber-muted :slant italic))))
   `(font-lock-constant-face ((,class (:foreground ,amber-dark))))
   `(font-lock-doc-face ((,class (:foreground ,amber-muted :slant italic))))
   `(font-lock-function-name-face ((,class (:foreground ,amber-orange :weight bold))))
   `(font-lock-function-call-face ((,class (:foreground ,amber-orange :weight bold))))  ; Method calls - bold
   `(font-lock-keyword-face ((,class (:foreground ,amber-gold :weight bold))))
   `(font-lock-negation-char-face ((,class (:foreground ,error :weight bold))))
   `(font-lock-preprocessor-face ((,class (:foreground ,amber-bright))))
   `(font-lock-regexp-grouping-backslash ((,class (:foreground ,cyan))))
   `(font-lock-regexp-grouping-construct ((,class (:foreground ,cyan))))
   `(font-lock-string-face ((,class (:foreground ,amber-cream))))
   `(font-lock-type-face ((,class (:foreground ,violet :weight bold))))
   `(font-lock-variable-name-face ((,class (:foreground ,amber-light))))
   `(font-lock-warning-face ((,class (:foreground ,warning :weight bold))))
   
   ;; Python/LSP specific method calls (tree-sitter and lsp-mode)
   `(python-font-lock-operator-face ((,class (:foreground ,cyan))))
   `(lsp-face-semhl-method ((,class (:foreground ,amber-orange))))
   `(lsp-face-semhl-function ((,class (:foreground ,amber-orange))))
   `(tree-sitter-hl-face:method.call ((,class (:foreground ,amber-orange))))
   `(tree-sitter-hl-face:function.call ((,class (:foreground ,amber-orange))))
   
   ;; Additional LSP semantic highlighting faces
   `(lsp-face-semhl-method.call ((,class (:foreground ,amber-orange))))
   `(lsp-face-semhl-function.call ((,class (:foreground ,amber-orange))))
   `(lsp-face-semhl-member ((,class (:foreground ,amber-orange))))
   
   ;; Python-mode specific faces
   `(python-font-lock-method-call-face ((,class (:foreground ,amber-orange))))
   `(python-font-lock-builtin-face ((,class (:foreground ,blue))))
   
   ;; Line numbers
   `(line-number ((,class (:foreground ,fg-dim :background ,bg-main))))
   `(line-number-current-line ((,class (:foreground ,fg-main :background ,bg-active :weight bold))))
   
   ;; Mode line
   `(mode-line ((,class (:background ,bg-main :foreground ,fg-main :box (:line-width 1 :color ,border)))))
   `(mode-line-inactive ((,class (:background ,bg-inactive :foreground ,fg-dim))))
   `(mode-line-buffer-id ((,class (:foreground ,amber-bright :weight bold))))
   
   ;; Header line
   `(header-line ((,class (:background ,bg-alt :foreground ,fg-main))))
   
   ;; Minibuffer
   `(minibuffer-prompt ((,class (:foreground ,amber-bright :weight bold))))
   
   ;; Fringe
   `(fringe ((,class (:background ,bg-main :foreground ,fg-dim))))
   
   ;; Links
   `(link ((,class (:foreground ,link :underline t))))
   `(link-visited ((,class (:foreground ,violet :underline t))))
   
   ;; Matching parentheses
   `(show-paren-match ((,class (:background "#5a3a15"))))
   `(show-paren-mismatch ((,class (:background ,error :foreground ,bg-main :weight bold))))
   
   ;; Completions
   `(completions-annotations ((,class (:foreground ,fg-dim))))
   `(completions-common-part ((,class (:foreground ,amber-bright :weight bold))))
   `(completions-first-difference ((,class (:foreground ,amber-orange :weight bold))))
   
   ;; Dired
   `(dired-directory ((,class (:foreground ,amber-bright :weight bold))))
   `(dired-flagged ((,class (:foreground ,error))))
   `(dired-header ((,class (:foreground ,amber-orange :weight bold))))
   `(dired-ignored ((,class (:foreground ,fg-dim))))
   `(dired-mark ((,class (:foreground ,success))))
   `(dired-marked ((,class (:foreground ,success :weight bold))))
   `(dired-warning ((,class (:foreground ,warning))))
   
   ;; Org mode
   `(org-block ((,class (:background ,bg-alt))))
   `(org-block-begin-line ((,class (:foreground ,fg-dim :background ,bg-alt))))
   `(org-block-end-line ((,class (:foreground ,fg-dim :background ,bg-alt))))
   `(org-code ((,class (:foreground ,amber-orange))))
   `(org-date ((,class (:foreground ,amber-dark))))
   `(org-document-info ((,class (:foreground ,fg-alt))))
   `(org-document-title ((,class (:foreground ,amber-bright :weight bold))))
   `(org-done ((,class (:foreground ,success :weight bold))))
   `(org-headline-done ((,class (:foreground ,fg-dim))))
   `(org-level-1 ((,class (:foreground ,amber-bright :weight bold))))
   `(org-level-2 ((,class (:foreground ,amber-orange :weight bold))))
   `(org-level-3 ((,class (:foreground ,amber-gold))))
   `(org-level-4 ((,class (:foreground ,amber-light))))
   `(org-link ((,class (:foreground ,link :underline t))))
   `(org-special-keyword ((,class (:foreground ,fg-dim))))
   `(org-table ((,class (:foreground ,fg-alt))))
   `(org-tag ((,class (:foreground ,amber-dark))))
   `(org-todo ((,class (:foreground ,warning :weight bold))))
   `(org-verbatim ((,class (:foreground ,amber-cream))))
   
   ;; Magit
   `(magit-branch-local ((,class (:foreground ,amber-bright))))
   `(magit-branch-remote ((,class (:foreground ,amber-orange))))
   `(magit-diff-added ((,class (:background "#2a1a0a" :foreground ,success))))
   `(magit-diff-added-highlight ((,class (:background "#3a2a1a" :foreground ,success))))
   `(magit-diff-removed ((,class (:background "#2a0a0a" :foreground ,error))))
   `(magit-diff-removed-highlight ((,class (:background "#3a1a1a" :foreground ,error))))
   `(magit-diff-context ((,class (:foreground ,fg-dim))))
   `(magit-diff-context-highlight ((,class (:background ,bg-alt :foreground ,fg-alt))))
   `(magit-diff-hunk-header ((,class (:background ,bg-highlight :foreground ,fg-main))))
   `(magit-diff-hunk-header-highlight ((,class (:background ,bg-active :foreground ,fg-main))))
   `(magit-hash ((,class (:foreground ,amber-dark))))
   `(magit-section-heading ((,class (:foreground ,amber-orange :weight bold))))
   `(magit-section-highlight ((,class (:background ,bg-alt))))
   
   ;; Company
   `(company-tooltip ((,class (:background ,bg-highlight :foreground ,fg-main))))
   `(company-tooltip-selection ((,class (:background ,bg-active :foreground ,fg-main))))
   `(company-tooltip-common ((,class (:foreground ,amber-bright :weight bold))))
   `(company-tooltip-common-selection ((,class (:foreground ,amber-bright :weight bold))))
   `(company-tooltip-annotation ((,class (:foreground ,fg-dim))))
   `(company-scrollbar-bg ((,class (:background ,bg-alt))))
   `(company-scrollbar-fg ((,class (:background ,amber-dark))))
   `(company-preview ((,class (:foreground ,fg-dim :background nil))))
   `(company-preview-common ((,class (:foreground ,fg-dim :background nil))))

   ;; Corfu
   `(corfu-default ((,class (:background ,bg-highlight :foreground ,fg-main))))
   `(corfu-current ((,class (:background "#4a3018" :foreground ,amber-bright :weight bold))))
   `(corfu-bar ((,class (:background ,amber-dark))))
   `(corfu-border ((,class (:background ,border))))
   `(corfu-annotations ((,class (:foreground ,fg-dim))))
   `(corfu-deprecated ((,class (:foreground ,fg-dim :strike-through t))))
   `(corfu-popupinfo ((,class (:background ,bg-highlight :foreground ,fg-main))))

   ;; Orderless (matched characters in corfu/completions)
   `(orderless-match-face-0 ((,class (:foreground ,amber-orange :weight bold))))
   `(orderless-match-face-1 ((,class (:foreground ,amber-orange :weight bold))))
   `(orderless-match-face-2 ((,class (:foreground ,amber-orange :weight bold))))
   `(orderless-match-face-3 ((,class (:foreground ,amber-orange :weight bold))))

   ;; Flycheck
   `(flycheck-error ((,class (:underline (:style wave :color ,error)))))
   `(flycheck-info ((,class (:underline (:style wave :color ,amber-bright)))))
   `(flycheck-warning ((,class (:underline (:style wave :color ,warning)))))
   
   ;; LSP
   `(lsp-face-highlight-read ((,class (:background ,bg-highlight))))
   `(lsp-face-highlight-textual ((,class (:background ,bg-highlight))))
   `(lsp-face-highlight-write ((,class (:background ,bg-active))))
   
   ;; Treemacs
   `(treemacs-directory-face ((,class (:foreground ,amber-bright))))
   `(treemacs-file-face ((,class (:foreground ,fg-main))))
   `(treemacs-root-face ((,class (:foreground ,amber-orange :weight bold))))
   `(treemacs-tags-face ((,class (:foreground ,amber-light))))
   
   ;; Which-key
   `(which-key-command-description-face ((,class (:foreground ,fg-main))))
   `(which-key-group-description-face ((,class (:foreground ,amber-bright))))
   `(which-key-key-face ((,class (:foreground ,amber-orange))))
   `(which-key-separator-face ((,class (:foreground ,fg-dim))))
   
   ;; Ivy/Counsel
   `(ivy-current-match ((,class (:background ,bg-active :foreground ,fg-main))))
   `(ivy-highlight-face ((,class (:foreground ,amber-bright))))
   `(ivy-match-required-face ((,class (:foreground ,error))))
   `(ivy-minibuffer-match-face-1 ((,class (:foreground ,amber-light))))
   `(ivy-minibuffer-match-face-2 ((,class (:foreground ,amber-bright :weight bold))))
   `(ivy-minibuffer-match-face-3 ((,class (:foreground ,amber-orange :weight bold))))
   `(ivy-minibuffer-match-face-4 ((,class (:foreground ,amber-gold :weight bold))))
   
   ;; Vertico (if used)
   `(vertico-current ((,class (:background ,bg-active :foreground ,fg-main))))
   
   ;; Evil mode visual selections
   `(evil-visual-selection ((,class (:background "#5a3a15"))))
   
   ;; Terminal colors for vterm/ansi-term
   `(term-color-black ((,class (:background "#000000" :foreground "#000000"))))
   `(term-color-red ((,class (:background ,error :foreground ,error))))
   `(term-color-green ((,class (:background ,success :foreground ,success))))
   `(term-color-yellow ((,class (:background ,warning :foreground ,warning))))
   `(term-color-blue ((,class (:background ,blue :foreground ,blue))))
   `(term-color-magenta ((,class (:background ,violet :foreground ,violet))))
   `(term-color-cyan ((,class (:background ,cyan :foreground ,cyan))))
   `(term-color-white ((,class (:background ,fg-main :foreground ,fg-main))))

   ;; Window-stool sticky header
   `(window-stool-face ((,class (:background ,bg-highlight))))
   ))

(when (and (boundp 'custom-theme-load-path) load-file-name)
  (add-to-list 'custom-theme-load-path
               (file-name-as-directory (file-name-directory load-file-name))))

(provide-theme 'retro-hacker-amber)

;;; retro-hacker-amber-theme.el ends here
