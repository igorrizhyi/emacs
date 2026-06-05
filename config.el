;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; Place your private configuration here! Remember, you do not need to run 'doom
;; sync' after modifying this file!

;; Add modules and themes directories to load path
(add-load-path! "modules")
;; (add-load-path! "modules/monet")
;; (add-load-path! "modules/claude-code.el/")
;; (load-file (expand-file-name "modules/claude-code.el/claude-code.el" doom-user-dir))
;; (load-file (expand-file-name "modules/monet/monet.el" doom-user-dir))
(add-load-path! "themes")
(add-to-list 'load-path (expand-file-name "modules/monet" doom-user-dir))
(add-to-list 'load-path (expand-file-name "modules/claude-code-emacs" doom-user-dir))

;; Load custom modules
(require 'my-terminal)
(require 'my-testrun-debug)
(require 'my-python-debug)
(require 'my-font-management)
(require 'my-navigation)
(require 'my-goto-last-change)
;; (require 'my-smart-splits)
;; (require 'my-smart-autosave)
;; (require 'my-window-layout)
(require 'my-external-file-indicator)
(require 'my-jump-animation)
(require 'my-spacious-padding)
(require 'my-layout)
;; (require 'my-jumps)
(require 'my-super-jumps)
(require 'my-search)
(require 'my-request-human)
(require 'my-eshell-funcs)
(require 'my-k8s-quick-actions)
(require 'my-knowledge-browser)

;; Exclude .agent-shell from project searches and LSP file watchers
(after! projectile
  (add-to-list 'projectile-globally-ignored-directories ".agent-shell"))

(after! lsp-mode
  (add-to-list 'lsp-file-watch-ignored-directories "[/\\\\]\\.agent-shell\\'")
  (add-to-list 'lsp-file-watch-ignored-directories "[/\\\\]\\.claude\\'")
  (add-to-list 'lsp-file-watch-ignored-directories "[/\\\\]\\.venv\\'")
  (add-to-list 'lsp-file-watch-ignored-directories "[/\\\\]node_modules\\'"))

;; Add ~/.cargo/bin to PATH and exec-path (for rust toolchain in eshell/shell)
(let ((cargo-bin (expand-file-name "~/.cargo/bin")))
  (when (file-directory-p cargo-bin)
    (add-to-list 'exec-path cargo-bin)
    (setenv "PATH" (concat cargo-bin ":" (getenv "PATH")))))

;; Exclude .agent-shell from project-find-regexp (project.el VC backend)
(setq project-vc-ignores '(".agent-shell/"))

;; Also cover grep-based searches
(after! grep
  (add-to-list 'grep-find-ignored-directories ".agent-shell"))

;; Auto-revert agent-shell files modified by agent processes
(defun my/auto-revert-agent-shell-files ()
  "Enable `auto-revert-mode' for files under .agent-shell/, excluding reports."
  (when (and buffer-file-name
             (string-match-p "/\\.agent-shell/" buffer-file-name)
             (not (string-match-p "/\\.agent-shell/reports/" buffer-file-name)))
    (auto-revert-mode 1)))

(add-hook 'find-file-hook #'my/auto-revert-agent-shell-files)

(add-hook 'markdown-mode-hook
  (lambda ()
    (when (and buffer-file-name
               (string-match-p "/.agent-shell/knowledge/.*\\.md$" buffer-file-name))
      (my/knowledge-browser-mode 1))))
(after! eshell
  (require 'em-tramp)
  (setq eshell-history-size 10000
        eshell-save-history-on-exit nil  ; We handle this ourselves
        eshell-hist-ignoredups t
        password-cache t
        password-cache-expiry 28800)

  ;; Track the last command we saved to avoid duplicates
  (defvar-local my/eshell-last-saved-command nil
    "Last command saved to history file.")

  ;; Append ONLY the new command to history file (truly incremental)
  (defun my/eshell-append-history ()
    "Append only the latest command to history file (incremental, never overwrites)."
    (when (and eshell-history-ring
               (ring-p eshell-history-ring)
               (not (ring-empty-p eshell-history-ring)))
      (let* ((latest (ring-ref eshell-history-ring 0))
             (history-file (or eshell-history-file-name
                              (expand-file-name "history" eshell-directory-name))))
        ;; Only append if this is a new command
        (when (and latest
                   (not (string-empty-p (string-trim latest)))
                   (not (equal latest my/eshell-last-saved-command)))
          (setq my/eshell-last-saved-command latest)
          ;; Append to file
          (write-region (concat latest "\n") nil history-file 'append 'silent)))))

  (add-hook 'eshell-post-command-hook #'my/eshell-append-history)

  ;; Reload full history from file when opening eshell
  (defun my/eshell-reload-history ()
    "Reload history from file to get commands from other sessions."
    (eshell-read-history)
    ;; Mark the latest as already saved to avoid re-appending
    (when (and eshell-history-ring
               (ring-p eshell-history-ring)
               (not (ring-empty-p eshell-history-ring)))
      (setq my/eshell-last-saved-command (ring-ref eshell-history-ring 0))))

  (add-hook 'eshell-mode-hook #'my/eshell-reload-history)

  ;; Delete word backward without polluting kill-ring/clipboard
  (defun my/backward-delete-word (arg)
    "Delete word before point without adding it to the kill ring."
    (interactive "p")
    (delete-region (point) (progn (backward-word arg) (point))))

  (define-key eshell-mode-map (kbd "<C-backspace>") #'my/backward-delete-word))

;; Distrobox eshell integration — open eshell inside a container via TRAMP
(defun eshell-distrobox ()
  "Pick a distrobox container and open eshell inside it."
  (interactive)
  (let* ((output (shell-command-to-string "distrobox list --no-color 2>/dev/null"))
         (lines (cdr (split-string output "\n" t)))  ; skip header
         (containers
          (cl-loop for line in lines
                   for parts = (split-string line "|" t)
                   when (>= (length parts) 2)
                   collect (string-trim (nth 1 parts))))
         (choice (completing-read "Distrobox: " containers nil t)))
    (let ((default-directory (format "/podman:%s:%s" choice default-directory)))
      (eshell 'N))))

;; SSH eshell integration — open eshell on a remote host via TRAMP
(defun eshell-ssh ()
  "Pick an SSH host from ~/.ssh/config and open eshell on it."
  (interactive)
  (let* ((hosts
          (cl-loop for line in (split-string
                                (shell-command-to-string "grep -i '^Host ' ~/.ssh/config 2>/dev/null")
                                "\n" t)
                   for host = (string-trim (replace-regexp-in-string "^[Hh]ost " "" line))
                   unless (string-match-p "[*?]" host)
                   collect host))
         (choice (completing-read "SSH host: " hosts nil t)))
    (let ((default-directory (format "/ssh:%s:~/" choice)))
      (eshell 'N))))

(require 'my-magit-utils)
(require 'my-dired-extension)
(require 'my-org-sidebar)
(require 'text-functions)
(require' claude-code-emacs)

;; Suppress messages in echo area (still logged to *Messages* buffer)
;; Use advice to ensure messages only go to *Messages* buffer, not echo area
(defun my-suppress-echo-area-message (orig-fun format-string &rest args)
  "Log message to *Messages* buffer but don't show in echo area."
  (let ((inhibit-message t))
    (apply orig-fun format-string args)))

(advice-add 'message :around #'my-suppress-echo-area-message)

;; File associations
(add-to-list 'auto-mode-alist '("\\.jstxt\\'" . js-mode))
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(js-mode . "javascript"))
  (add-to-list 'lsp-language-id-configuration '(markdown-view-mode . "markdown")))

;; Disable automatic project switching when opening files
(setq projectile-track-known-projects-automatically nil)
(setq projectile-auto-discover nil)

;; Register project when using SPC p . (browse project)
(defun my/register-browsed-project-advice (orig-fn &rest args)
  "Register project after browsing to it."
  (let ((result (apply orig-fn args)))
    (when-let ((project-root (projectile-project-root default-directory)))
      (projectile-add-known-project project-root)
      (message "Registered project: %s" project-root))
    result))
(advice-add #'+default/browse-project :around #'my/register-browsed-project-advice)
(setq projectile-enable-caching nil)
(setq projectile-indexing-method 'alien)
(setq projectile-require-project-root nil)

;; Pin doom config as the project root for buffers inside ~/.config/doom
(after! projectile
  (remove-hook 'find-file-hook #'projectile-find-file-hook-function)

  (defvar my/doom-config-root (expand-file-name "~/.config/doom/")
    "Doom config directory, pinned as project root for buffers inside it.")

  (advice-add 'projectile-project-root :around
              (lambda (orig-fn &optional dir)
                (if (and (not dir)
                         (string-prefix-p my/doom-config-root
                                          (expand-file-name
                                           (or buffer-file-name default-directory ""))))
                    my/doom-config-root
                  (funcall orig-fn dir)))))

;; Disable Doom's workspace switching on file open
(after! persp-mode
  (setq persp-auto-save-opt 0)
  (setq persp-auto-resume-time -1)
  ;; Override workspaces module - open dired instead of find-file on project switch
  (setq projectile-switch-project-action #'projectile-dired))

;; Prevent persp-mode from killing eshell buffers as "foreign"
(add-hook 'eshell-mode-hook (lambda () (setq-local doom-real-buffer-p t)))

;; Keep HYPRLAND_INSTANCE_SIGNATURE current
(defun my/update-hyprland-signature ()
  "Update HYPRLAND_INSTANCE_SIGNATURE from /run/user/1000/hypr/."
  (interactive)
  (when-let ((sig (car (directory-files "/run/user/1000/hypr/" nil "^[^.]"))))
    (setenv "HYPRLAND_INSTANCE_SIGNATURE" sig)
    (message "Hyprland signature: %s" sig)))

;; Set DOCKER_HOST so devcontainer CLI (and other tools) use podman
(setenv "DOCKER_HOST" "unix:///run/user/1000/podman/podman.sock")

;; Strip CLAUDECODE so spawned claude-agent-acp processes don't hit the nesting guard
(setenv "CLAUDECODE")

;; Optimize general Emacs responsiveness
(setq gc-cons-threshold (* 100 1024 1024))  ; 100MB instead of 800KB
(setq read-process-output-max (* 1024 1024))  ; 1MB instead of 4KB

;; Prevent Emacs from automatically resizing windows
(setq window-combination-resize nil)
(setq even-window-sizes nil)
(setq window-resize-pixelwise t)  ; Optional: more precise resizing

(setq copilot-indent-offset-warning-disable 1)

;; Enable smart auto-save that respects Evil mode states
;; (setq my-smart-autosave-delay 2)  ; Wait 3 seconds after last change before saving
;; (my-smart-autosave-global-mode 1) ; Enable globally for all file buffers

;; Enable external file indicator to highlight dependency files
(my-external-file-indicator-mode 1)

;; Enable jump animations with overlay integration
(my-jump-animation-mode 1)

;; Enable smart jumps with 5-line threshold (after Evil loads)
;; (after! evil
;;   (my-smart-jumps-mode 1))

;; Enable super jumps (project-specific) with 10-line threshold
(after! evil
  (setq my-super-jumps-line-threshold 10)
  (my-super-jumps-mode 1))

;; Optional: Disable built-in auto-save to avoid conflicts
(setq auto-save-default nil)
(when (fboundp 'auto-save-visited-mode)
  (auto-save-visited-mode -1))

(use-package code-context
  :config
  (add-hook 'prog-mode-hook #'code-context-mode))

(use-package markdown-mode
  :hook (markdown-mode . lsp)
  :config
  (require 'lsp-marksman))

;; Configure DAP (Debug Adapter Protocol) for debugging
(use-package! dap-mode
  :after lsp-mode
  :commands dap-debug
  :hook ((python-mode . dap-ui-mode) (python-mode . dap-mode))
  :config
  (require 'dap-python)
  (require 'with-venv)
  (setq dap-python-debugger 'debugpy)
  (defun dap-python--pyenv-executable-find (command)
    (with-venv (executable-find "python")))

  (add-hook 'dap-stopped-hook
            (lambda (arg) (call-interactively #'dap-hydra))))

;; Global debug key bindings for Python (C-c d prefix)
(map! :map python-mode-map
      :prefix ("C-c d" . "debug")
      "d" #'my/debug-nearest-test      ; Debug nearest test
      "f" #'my/debug-test-file         ; Debug test file
      "a" #'my/debug-test-with-args    ; Debug with args
      "b" #'dap-breakpoint-toggle      ; Toggle breakpoint
      "B" #'dap-breakpoint-delete-all  ; Clear all breakpoints
      "n" #'dap-next                   ; Step over
      "s" #'dap-step-in                ; Step in
      "o" #'dap-step-out               ; Step out
      "c" #'dap-continue               ; Continue
      "r" #'dap-debug-restart          ; Restart
      "q" #'dap-disconnect             ; Quit/disconnect
      "v" #'dap-ui-locals              ; Show variables
      "h" #'dap-hydra                  ; Debug hydra
      )

;; Git/Magit key bindings
(map! :leader
      :desc "Copy branch name" "g Y" #'my/magit-copy-branch-name)

;; Magit section navigation and folding
(after! magit
  (map! :map magit-mode-map
        :n "<backtab>" #'magit-section-show-level-2-all))

;; AI-powered git commit messages with OpenAI
(after! magit
  (use-package! magit-gptcommit
    :init
    (require 'llm-openai)
    (setq llm-warn-on-nonfree nil)  ; Suppress "not free software" warning
    :config
    (setq magit-gptcommit-llm-provider
          (make-llm-openai
           :key (getenv "OPENAI_API_KEY")
           :chat-model "gpt-4o-mini"))
    ;; (magit-gptcommit-mode 1)  ; Disabled - enable with M-x magit-gptcommit-mode
    (magit-gptcommit-status-buffer-setup)))

;; Some functionality uses this to identify you, e.g. GPG configuration, email
;; clients, file templates and snippets. It is optional.
;; (setq user-full-name "John Doe"
;;       user-mail-address "john@doe.com")

;; Doom exposes five (optional) variables for controlling fonts in Doom:
;;
;; - `doom-font' -- the primary font to use
;; - `doom-variable-pitch-font' -- a non-monospace font (where applicable)
;; - `doom-big-font' -- used for `doom-big-font-mode'; use this for
;;   presentations or streaming.
;; - `doom-symbol-font' -- for symbols
;; - `doom-serif-font' -- for the `fixed-pitch-serif' face
;;
;; See 'C-h v doom-font' for documentation and more examples of what they
;; accept. For example:
;;
;;(setq doom-font (font-spec :family "Fira Code" :size 12 :weight 'semi-light)
;;      doom-variable-pitch-font (font-spec :family "Fira Sans" :size 13))
;;
;; If you or Emacs can't find your font, use 'M-x describe-font' to look them
;; up, `M-x eval-region' to execute elisp code, and 'M-x doom/reload-font' to
;; refresh your font settings. If Emacs still can't find your font, it likely
;; wasn't installed correctly. Font issues are rarely Doom issues!

;; There are two ways to load a theme. Both assume the theme is installed and
;; available. You can either set `doom-theme' or manually load a theme with the
;; `load-theme' function. This is the default:
;; (setq doom-theme 'doom-one)
;; (setq doom-theme 'doom-lantern)
(setq doom-theme 'retro-hacker-amber)  ; Revert to working version
;; (setq doom-theme 'catppuccin)
;; (setq doom-theme 'doom-retro-hacker-amber)  ; New version (has issues)

;; This determines the style of line numbers in effect. If set to `nil', line
;; numbers are disabled. For relative line numbers, set this to `relative'.
(setq display-line-numbers-type 'relative)
;; Show 0 on current line instead of absolute number for pure relative mode
(setq display-line-numbers-current-absolute nil)

;; If you use `org' and don't want your org files in the default location below,
;; change `org-directory'. It must be set before org loads!
(setq org-directory "~/org/")


;; Whenever you reconfigure a package, make sure to wrap your config in an
;; `after!' block, otherwise Doom's defaults may override your settings. E.g.
;;
;;   (after! PACKAGE
;;     (setq x y))
;;
;; The exceptions to this rule:
;;
;;   - Setting file/directory variables (like `org-directory')
;;   - Setting variables which explicitly tell you to set them before their
;;     package is loaded (see 'C-h v VARIABLE' to look up their documentation).
;;   - Setting doom variables (which start with 'doom-' or '+').
;;
;; Here are some additional functions/macros that will help you configure Doom.
;;
;; - `load!' for loading external *.el files relative to this one
;; - `use-package!' for configuring packages
;; - `after!' for running code after a package has loaded
;; - `add-load-path!' for adding directories to the `load-path', relative to
;;   this file. Emacs searches the `load-path' when you load packages with
;;   `require' or `use-package'.
;; - `map!' for binding new keys
;;
;; To get information about any of these functions/macros, move the cursor over
;; the highlighted symbol at press 'K' (non-evil users must press 'C-c c k').
;; This will open documentation for it, including demos of how they are used.
;; Alternatively, use `C-h o' to look up a symbol (functions, variables, faces,
;; etc).
;;
;; You can also try 'gd' (or 'C-c c d') to jump to their definition and see how
;; they are implemented.
;;
;; Python configuration - Use lsp-mode with lsp-pyright

;; Automatic virtual environment activation
(use-package! pyvenv
  :config
  ;; Function to automatically activate venv when opening Python files
  (defun my/auto-activate-venv ()
    "Automatically activate virtual environment if .venv exists in project root."
    (when (and (derived-mode-p 'python-mode 'python-ts-mode)
               (projectile-project-p))
      (let* ((project-root (projectile-project-root))
             (venv-path (expand-file-name ".venv" project-root)))
        (when (file-directory-p venv-path)
          (pyvenv-activate venv-path)
          (message "Activated venv: %s" venv-path)))))

  ;; Hook to auto-activate venv
  (add-hook 'python-mode-hook #'my/auto-activate-venv)
  (add-hook 'python-ts-mode-hook #'my/auto-activate-venv)

  ;; Also activate when switching projects
  (add-hook 'projectile-after-switch-project-hook #'my/auto-activate-venv))

;; Simple eshell venv activation for project-local .venv
(defun eshell/venv (&optional path)
  "Activate venv. Usage: venv [path]. Default: .venv in current dir."
  (let* ((venv-path (expand-file-name (or path ".venv")))
         (bin-dir (concat venv-path "/bin")))
    (if (file-directory-p bin-dir)
        (progn
          (setenv "VIRTUAL_ENV" venv-path)
          (setenv "PATH" (concat bin-dir ":" (getenv "PATH")))
          (eshell-set-path (getenv "PATH"))
          (format "Activated: %s" venv-path))
      (format "Not found: %s" venv-path))))

(defun eshell/deactivate ()
  "Deactivate current venv."
  (when-let ((venv (getenv "VIRTUAL_ENV")))
    (let* ((bin-dir (concat venv "/bin"))
           (paths (split-string (getenv "PATH") ":"))
           (new-path (string-join (remove bin-dir paths) ":")))
      (setenv "PATH" new-path)
      (setenv "VIRTUAL_ENV")
      (eshell-set-path new-path)
      "Deactivated")))

;; Configure lsp-pyright for faster completions
(after! lsp-pyright
  (setq lsp-pyright-auto-import-completions t
        lsp-pyright-auto-search-paths nil
        lsp-pyright-use-library-code-for-types t
        lsp-pyright-diagnostic-mode "openFilesOnly"  ;; Don't analyze entire workspace
        lsp-pyright-type-checking-mode "basic"))      ;; Lighter type checking = faster responses
(add-hook 'python-mode-hook #'lsp)

;; (use-package! lsp-pyright
;;   :after lsp-mode
;;   :config
;;   ;; Use system pyright-langserver
;;   ;; (setq lsp-pyright-langserver-command "/usr/bin/pyright-langserver")
;;   (setq lsp-pyright-langserver-command "basedpyright")
;;
;;   ;; Configure pyright settings for better type checking
;;   (setq lsp-pyright-diagnostic-mode "workspace"
;;         lsp-pyright-type-checking-mode "basic"
;;         lsp-pyright-auto-import-completions t
;;         lsp-pyright-auto-search-paths t
;;         lsp-pyright-use-library-code-for-types t
;;         lsp-pyright-report-missing-type-stubs nil))

;; Auto-start LSP for Python files
;; (add-hook! 'python-mode-hook #'lsp!)

;; Configure LSP to work optimally with Corfu
(after! lsp-mode
  (setq lsp-completion-provider :capf)  ;; Use completion-at-point-functions (Corfu)
  ;; Ultra-fast LSP responses
  (setq lsp-idle-delay 0.05             ;; Almost immediate LSP responses (50ms)
        lsp-response-timeout 3          ;; Faster timeout (3s instead of 30s)
        lsp-completion-show-detail t    ;; Show completion details
        lsp-completion-show-kind t      ;; Show completion kind icons
        lsp-signature-auto-activate nil ;; Disable auto-show signatures
        lsp-eldoc-enable-hover t        ;; Enable hover documentation
        lsp-signature-render-documentation nil  ; Disable for speed
        lsp-enable-file-watchers t
        lsp-file-watch-threshold 2000   ;; Faster file watching
        lsp-eldoc-render-all nil        ;; Don't render everything for speed
        lsp-completion-no-cache nil     ;; Cache completions locally (avoid re-requesting)
        lsp-completion-use-last-result t) ;; Reuse cached results for faster popup
  ;; ;; Breadcrumb configuration
  ;; (setq lsp-headerline-breadcrumb-enable t ;; Enable breadcrumb navigation in header
  ;;       lsp-headerline-breadcrumb-icons-enable nil ;; Disable icons for speed
  ;;       lsp-headerline-breadcrumb-enable-symbol-numbers nil
  ;;       lsp-headerline-breadcrumb-segments '(symbols) ;; Only show symbols, no path
  ;;       lsp-headerline-breadcrumb-enable-diagnostics nil ;; Disable diagnostics in breadcrumb
  ;;       lsp-headerline-breadcrumb-enable-project-prefix nil) ;; No project prefix

  ;; Enable LSP semantic highlighting for method calls and variables
  (setq lsp-semantic-tokens-enable t
        lsp-enable-semantic-highlighting t
        lsp-semantic-tokens-apply-modifiers t)

  ;; Map semantic tokens to faces for method call highlighting and bold variables
  (setq lsp-semantic-tokens-faces
        '(("method" . font-lock-function-call-face)
          ("function" . font-lock-function-call-face)
          ("member" . font-lock-function-call-face)
          ("variable" . (:weight bold))
          ("parameter" . (:weight bold)))))

;; Debug function to check what face is at point
(defun my/what-face ()
  "Show the face(s) at the current point."
  (interactive)
  (let* ((point (point))
         ;; Get text property faces
         (text-face (get-text-property point 'face))
         ;; Get font-lock faces
         (font-lock-face (get-text-property point 'font-lock-face))
         ;; Get overlay faces
         (overlay-faces (mapcar (lambda (ov) (overlay-get ov 'face))
                               (overlays-at point)))
         ;; Remove nils from overlay faces
         (overlay-faces (delq nil overlay-faces))
         ;; Get face at point using face-at-point
         (face-at-point (face-at-point t))
         ;; Collect all faces
         (all-faces (delq nil (list text-face font-lock-face face-at-point))))
    (when overlay-faces
      (setq all-faces (append all-faces overlay-faces)))
    (message "Faces at point: %s\nText property: %s\nFont-lock: %s\nOverlays: %s\nFace-at-point: %s"
             all-faces text-face font-lock-face overlay-faces face-at-point)))

;; Bind to F12 for easy access
(global-set-key (kbd "<f12>") 'my/what-face)

;; Additional function to check LSP semantic highlighting specifically
(defun my/what-lsp-face ()
  "Show LSP semantic token information at point."
  (interactive)
  (if (bound-and-true-p lsp-mode)
      (let* ((semantic-tokens (get-text-property (point) 'lsp-semantic-token))
             (lsp-face (get-text-property (point) 'lsp-face))
             (semantic-faces (get-text-property (point) 'lsp-semantic-faces)))
        (message "LSP semantic info: token=%s, lsp-face=%s, semantic-faces=%s"
                 semantic-tokens lsp-face semantic-faces))
    (message "LSP mode not active in this buffer")))

;; Bind to Shift-F12 for LSP-specific face info
(global-set-key (kbd "<S-f12>") 'my/what-lsp-face)

;; Tree-sitter face inspection function
(defun my/what-treesit-face ()
  "Show tree-sitter specific face information at point."
  (interactive)
  (if (and (fboundp 'treesit-available-p) (treesit-available-p)
           (treesit-parser-list))
      (let* ((node (treesit-node-at (point)))
             (node-type (when node (treesit-node-type node)))
             (node-text (when node (treesit-node-text node t)))
             (treesit-face (get-text-property (point) 'treesit-face))
             (font-lock-face (get-text-property (point) 'font-lock-face))
             (face-prop (get-text-property (point) 'face)))
        (message "Tree-sitter info:\nNode: %s\nType: %s\nText: %s\nTreesit face: %s\nFont-lock face: %s\nFace prop: %s"
                 node node-type (if (> (length node-text) 50)
                                   (concat (substring node-text 0 47) "...")
                                 node-text)
                 treesit-face font-lock-face face-prop))
    (message "Tree-sitter not active in this buffer")))

;; Bind to F11 for tree-sitter specific face info
(global-set-key (kbd "<f11>") 'my/what-treesit-face)


;; Add custom font-lock for Python function and method calls
;; (defun my/add-python-call-highlighting ()
;;   "Add font-lock rules for Python function and method calls (only with parentheses)."
;;   (font-lock-add-keywords
;;    nil
;;    '(
;;      ;; Method calls: obj.method()
;;      ("\\.[[:space:]]*\\([a-zA-Z_][a-zA-Z0-9_]*\\)[[:space:]]*[\\(]"
;;       1 'font-lock-function-call-face)
;;      ;; Regular function calls: function() - but NOT after a dot (to avoid double-matching methods)
;;      ;; Match functions that are at start of line, after whitespace, or after non-dot characters
;;      ("\\(?:^\\|[[:space:]]\\|[^.a-zA-Z0-9_]\\)\\([a-zA-Z_][a-zA-Z0-9_]*\\)[[:space:]]*[\\(]"
;;       1 'font-lock-function-call-face)
;;      )))

;; Apply to Python modes
;; (add-hook 'python-mode-hook #'my/add-python-call-highlighting)
;; (add-hook 'python-ts-mode-hook #'my/add-python-call-highlighting)

;; Make variable names medium weight and type names medium (lighter than bold)
(custom-set-faces
 '(font-lock-variable-name-face ((t (:weight medium))))
 '(font-lock-type-face ((t (:weight medium)))))

;; Define a custom face for keyword arguments (regular weight)
(defface my/keyword-argument-face
  '((t (:inherit default)))
  "Face for keyword arguments with regular weight."
  :group 'font-lock-faces)

;; Tree-sitter configuration
(use-package treesit
  :when (and (fboundp 'treesit-available-p) (treesit-available-p))
  :config
  ;; Set tree-sitter library directory for Doom Emacs
  (when (boundp 'treesit-extra-load-path)
    (add-to-list 'treesit-extra-load-path
                 (expand-file-name ".local/etc/tree-sitter/" doom-user-dir)))

  ;; Customize tree-sitter font-lock by overriding existing face mappings
  (defun my/customize-treesit-faces ()
    "Customize tree-sitter face mappings for keyword arguments."
    ;; Override the font-lock-variable-use-face for keyword arguments
    (when (treesit-parser-list)
      ;; Set custom face mapping for keyword_argument nodes
      (setq-local treesit-font-lock-feature-list
                  (append treesit-font-lock-feature-list '(custom)))
      ;; Add our custom rule with higher priority
      (setq-local treesit-font-lock-settings
                  (append treesit-font-lock-settings
                          (treesit-font-lock-rules
                           :language 'python
                           :feature 'custom
                           :override t
                           '((keyword_argument name: (identifier) @font-lock-constant-face)
                             (keyword_argument value: (integer) @font-lock-variable-name-face)
                             (keyword_argument value: (true) @font-lock-variable-name-face)
                             (keyword_argument value: (false) @font-lock-variable-name-face)
                             (keyword_argument value: (none) @font-lock-variable-name-face)
                             (assignment right: (integer) @font-lock-variable-name-face)
                             (assignment right: (true) @font-lock-variable-name-face)
                             (assignment right: (false) @font-lock-variable-name-face)
                             (assignment right: (none) @font-lock-variable-name-face)
                             (class_definition name: (identifier) @font-lock-keyword-face)))))))

  ;; Apply after tree-sitter mode is enabled
  (add-hook 'python-ts-mode-hook #'my/customize-treesit-faces)

  ;; Configure tree-sitter language sources
  (setq treesit-language-source-alist
        '((python "https://github.com/tree-sitter/tree-sitter-python")
          (javascript "https://github.com/tree-sitter/tree-sitter-javascript")
          (typescript "https://github.com/tree-sitter/tree-sitter-typescript" "master" "typescript/src")
          (tsx "https://github.com/tree-sitter/tree-sitter-typescript" "master" "tsx/src")
          (css "https://github.com/tree-sitter/tree-sitter-css")
          (html "https://github.com/tree-sitter/tree-sitter-html")
          (json "https://github.com/tree-sitter/tree-sitter-json")
          (yaml "https://github.com/ikatyang/tree-sitter-yaml")
          (bash "https://github.com/tree-sitter/tree-sitter-bash")
          (rust "https://github.com/tree-sitter/tree-sitter-rust")
          (go "https://github.com/tree-sitter/tree-sitter-go")
          (cpp "https://github.com/tree-sitter/tree-sitter-cpp")
          (elisp "https://github.com/Wilfred/tree-sitter-elisp")))

  ;; Auto-install missing grammars
  (defun my/treesit-install-all-languages ()
    "Install all tree-sitter language grammars."
    (interactive)
    (dolist (lang treesit-language-source-alist)
      (let ((lang-name (car lang)))
        (unless (treesit-language-available-p lang-name)
          (message "Installing tree-sitter grammar for %s..." lang-name)
          (treesit-install-language-grammar lang-name)))))

  ;; Enable tree-sitter modes automatically
  (add-to-list 'major-mode-remap-alist '(python-mode . python-ts-mode))
  (add-to-list 'major-mode-remap-alist '(javascript-mode . js-ts-mode))
  (add-to-list 'major-mode-remap-alist '(typescript-mode . typescript-ts-mode))
  (add-to-list 'major-mode-remap-alist '(css-mode . css-ts-mode))
  (add-to-list 'major-mode-remap-alist '(json-mode . json-ts-mode))
  (add-to-list 'major-mode-remap-alist '(yaml-mode . yaml-ts-mode))
  (add-to-list 'major-mode-remap-alist '(sh-mode . bash-ts-mode))
  (add-to-list 'major-mode-remap-alist '(rust-mode . rust-ts-mode))
  (add-to-list 'major-mode-remap-alist '(go-mode . go-ts-mode))
  (add-to-list 'major-mode-remap-alist '(c++-mode . c++-ts-mode))
  ;; Note: elisp-ts-mode doesn't exist by default, so we comment this out
  ;; (add-to-list 'major-mode-remap-alist '(emacs-lisp-mode . elisp-ts-mode))
  )

;; Set scroll margin - keep 10 lines above and below cursor
(setq scroll-margin 13                     ; Required for ultra-scroll smooth scrolling
      scroll-conservatively 130)          ; Scroll just enough to keep cursor visible
;; Configure all-the-icons for smaller sizes
;; (after! all-the-icons
;;   ;; Set default scale factor for all icons to be smaller
;;   (setq all-the-icons-scale-factor 0.7) ;; Make icons 70% of normal size
;;   ;; Additional adjustment for better alignment
;;   (setq all-the-icons-default-adjust -0.2))

;; Enable smooth pixel-based scrolling
;; (when (fboundp 'pixel-scroll-precision-mode)
;;   (pixel-scroll-precision-mode nil))

;; Set window title to project name
(defun my/set-frame-title ()
  "Set frame title to project name or buffer name."
  (let ((project-name (when (bound-and-true-p projectile-mode)
                        (projectile-project-name))))
    (setq frame-title-format
          (if project-name
              project-name
            "%b"))))

(add-hook 'projectile-after-switch-project-hook #'my/set-frame-title)
(add-hook '+workspace-switch-hook #'my/set-frame-title)

;; Set initial title
(my/set-frame-title)

;; Enable preview for consult-ripgrep
(after! consult
  ;; Enable preview for consult-ripgrep by default
  (consult-customize consult-ripgrep :preview-key 'any))

;; Configure corfu to work better with LSP
(after! corfu
  (setq corfu-cycle t           ;; Enable cycling for `corfu-next/previous'
        corfu-preselect 'prompt ;; Always preselect the prompt
        ;; Popup positioning controls
        corfu-min-width 50      ;; Minimum width of the popup
        corfu-max-width 100     ;; Maximum width of the popup
        corfu-count 5          ;; More candidates shown
        corfu-scroll-margin 2   ;; Number of lines at the top/bottom during scrolling
        ;; Ultra-fast completion settings
        corfu-auto t            ;; Enable automatic completion
        corfu-auto-delay 0.01   ;; Show completions almost immediately (50ms)
        corfu-auto-prefix 2     ;; Start after 1 character
        corfu-popupinfo-delay 0.0 ;; Show info immediately
        ;; Enable Tab completion
        tab-always-indent 'complete)

  ;; Key bindings for corfu
  (map! :map corfu-map
        :desc "Complete" "TAB" #'corfu-complete
        :desc "Complete" "<tab>" #'corfu-complete
        :desc "Previous" "S-TAB" #'corfu-previous
        :desc "Previous" "<backtab>" #'corfu-previous)

  ;; Guard against malformed posn from posn-at-point in eshell/comint.
  ;; posn-at-point can return a truncated 4-element posn (frame instead of
  ;; window, no object-width-height slot) when buffer output is being inserted
  ;; asynchronously.  corfu--popup-show calls (cdr (posn-object-width-height
  ;; pos)) which yields nil, then (max <n> nil) crashes.  Silently skip the
  ;; popup when the posn is malformed — post-command-hook retries next cycle.
  (define-advice corfu--popup-show (:around (fn pos &rest args) guard-posn)
    "Skip popup display when posn is malformed (e.g. from async eshell output)."
    (when (and pos (posn-x-y pos))
      (apply fn pos args))))

;; Smart window navigation function for C-h
(defun my/smart-move-left ()
  "Move to left window, or open Magit if already at leftmost window."
  (interactive)
  ;; Always register current location in Evil jump list before moving
  (evil-set-jump)
  (let ((current-window (selected-window))
        (left-window (windmove-find-other-window 'left)))
    (if left-window
        ;; There's a window to the left, move to it
        (windmove-left)
      ;; No window to the left (we're at leftmost), open Magit
      (magit-status))))

;; Window navigation keybindings - move focus between splits
(map! "C-h" #'my/smart-move-left   ; Smart left movement or Magit
      "C-l" #'windmove-right       ; Focus right window split
      "M-k" #'my-layout-smart-agent-shell
      "C-k" #'my-layout-smart-agent-shell) ; Smart agent-shell handler

;; Override evil-org's M-k (org-metaup) — advice the source function so it
;; can never set M-k without us immediately overriding it
(defun my/override-evil-org-meta-keys (&rest _)
  "Re-bind M-k and C-v after evil-org sets its additional bindings."
  (evil-define-key 'normal evil-org-mode-map (kbd "M-k") #'my-layout-smart-agent-shell)
  (evil-define-key 'insert evil-org-mode-map (kbd "M-k") #'my-layout-smart-agent-shell)
  (evil-define-key 'visual evil-org-mode-map (kbd "M-k") #'my-layout-smart-agent-shell)
  (evil-define-key 'normal evil-org-mode-map (kbd "C-v") #'yank)
  (evil-define-key 'insert evil-org-mode-map (kbd "C-v") #'yank)
  (evil-normalize-keymaps))
(after! evil-org
  (advice-add #'evil-org--populate-additional-bindings :after #'my/override-evil-org-meta-keys)
  (advice-add #'evil-org-set-key-theme :after #'my/override-evil-org-meta-keys)
  (my/override-evil-org-meta-keys))

;; Override evil-markdown's M-k (markdown-move-up) — same pattern as evil-org above
(defun my/override-evil-markdown-meta-keys (&rest _)
  "Re-bind M-k after evil-markdown sets its additional bindings."
  (evil-define-key 'normal evil-markdown-mode-map (kbd "M-k") #'my-layout-smart-agent-shell)
  (evil-define-key 'insert evil-markdown-mode-map (kbd "M-k") #'my-layout-smart-agent-shell)
  (evil-define-key 'visual evil-markdown-mode-map (kbd "M-k") #'my-layout-smart-agent-shell)
  (evil-normalize-keymaps))
(after! evil-markdown
  (advice-add #'evil-markdown--populate-additional-bindings :after #'my/override-evil-markdown-meta-keys)
  (advice-add #'evil-markdown-set-key-theme :after #'my/override-evil-markdown-meta-keys)
  (my/override-evil-markdown-meta-keys))

;; Don't pollute clipboard with deleted/replaced text
(setq evil-kill-on-visual-paste nil)  ; visual paste doesn't overwrite clipboard
(evil-define-operator evil-delete-without-register (beg end type register yank-handler)
  "Delete without yanking to clipboard."
  (interactive "<R><x><y>")
  (evil-delete beg end type ?_ yank-handler))
(evil-define-operator evil-change-without-register (beg end type register yank-handler)
  "Change without yanking to clipboard."
  (interactive "<R><x><y>")
  (evil-change beg end type ?_ yank-handler))
(defun evil-delete-char-without-register ()
  "Delete character under cursor without yanking to kill ring."
  (interactive)
  (delete-char 1))
(map! :map evil-normal-state-map
      "d" #'evil-delete-without-register
      "c" #'evil-change-without-register
      "x" #'evil-delete-char-without-register)
(map! :map evil-visual-state-map
      "d" #'evil-delete-without-register
      "c" #'evil-change-without-register)

;; Delete word backward in insert mode without touching clipboard
(defun my/delete-word-no-kill ()
  "Delete word backward without touching kill ring."
  (interactive)
  (let ((beg (save-excursion (backward-word) (point))))
    (delete-region beg (point))))
(define-key evil-insert-state-map (kbd "C-<backspace>") nil)
(add-hook 'prog-mode-hook
          (lambda () (evil-local-set-key 'insert (kbd "C-<backspace>") #'my/delete-word-no-kill)))
(add-hook 'text-mode-hook
          (lambda () (evil-local-set-key 'insert (kbd "C-<backspace>") #'my/delete-word-no-kill)))
(add-hook 'conf-mode-hook
          (lambda () (evil-local-set-key 'insert (kbd "C-<backspace>") #'my/delete-word-no-kill)))

;; Jump navigation keybindings - like browser back/forward
(map! :map evil-normal-state-map
      "H" #'my-super-jumps-backward   ; Project jump back
      "L" #'my-super-jumps-forward)   ; Project jump forward

;; Super jumps keybindings - project-specific jumps
(map! :map evil-normal-state-map
      "C-o" #'my-super-jumps-backward   ; Project jump back
      "C-i" #'my-super-jumps-forward    ; Project jump forward
      "C-S-<iso-lefttab>" #'my-super-jumps-list)  ; Jump preview

;; Leader keybindings for super jumps
(map! :leader
      (:prefix ("j" . "jumps")
       :desc "Jump backward" "b" #'my-super-jumps-backward
       :desc "Jump forward" "f" #'my-super-jumps-forward
       :desc "List jumps" "l" #'my-super-jumps-list
       :desc "Clear jumps" "c" #'my-super-jumps-clear
       :desc "Register jump" "r" #'my-super-jumps-register
       :desc "Mark intention" "m" #'my-super-jumps-mark-intention))

;; Leader keybindings for search
(map! :leader
      (:prefix ("s" . "search")
       :desc "Find class" "c" #'my-search-find-class
       :desc "Find function" "f" #'my-search-find-function
       :desc "Find symbol" "s" #'my-search-find-symbol))

;; Copy relative file path
(defun my/copy-relative-file-path ()
  "Copy the current buffer's file path relative to project root."
  (interactive)
  (if-let ((file (buffer-file-name))
           (root (projectile-project-root)))
      (let ((relative (file-relative-name file root)))
        (kill-new relative)
        (message "Copied: %s" relative))
    (user-error "Buffer is not visiting a file or not in a project")))

(map! :leader
      (:prefix ("c" . "code")
       :desc "Copy relative path" "p" #'my/copy-relative-file-path))

;; Make Evil word movement behave like Vim - custom word boundaries
(with-eval-after-load 'evil
  ;; Setup custom word boundaries: underscores = part of word, hyphens = separators
  (defun my/setup-word-boundaries ()
    "Set up word boundaries: underscores as word constituents, hyphens as separators."
    (modify-syntax-entry ?_ "w")  ; underscore = word constituent
    (modify-syntax-entry ?- ".")) ; hyphen = punctuation (separator)

  ;; Apply to all programming modes EXCEPT elisp
  (add-hook 'prog-mode-hook
            (lambda ()
              (unless (derived-mode-p 'emacs-lisp-mode 'lisp-interaction-mode)
                (my/setup-word-boundaries))))
  ;; Also apply to text/conf modes where underscores are common
  (add-hook 'conf-mode-hook #'my/setup-word-boundaries)
  (add-hook 'yaml-mode-hook #'my/setup-word-boundaries))

;; Smart Enter function with context-aware behavior
(defun my/smart-enter ()
  "Context-aware Enter behavior: go to definition except in special buffers."
  (interactive)
  (cond
   ;; In insert state, always do regular newline
   ((evil-insert-state-p)
    (newline))

   ;; In team sidebar, use sidebar's smart-enter
   ((derived-mode-p 'my/team-sidebar-mode)
    (call-interactively #'my/team-sidebar-switch-to-agent))

   ;; In agent-shell buffers, toggle sections or activate buttons
   ((derived-mode-p 'agent-shell-mode)
      ;; Simulate insert-mode RET so button keymaps fire correctly
      (let ((inhibit-read-only t))
        (evil-insert-state)
        (unwind-protect
            (let ((key (kbd "RET")))
              (call-interactively (key-binding key)))
          (evil-normal-state))))

   ;; In magit buffers, use magit's default Enter behavior
   ((derived-mode-p 'magit-mode 'magit-status-mode 'magit-log-mode 'magit-diff-mode)
    (call-interactively (key-binding (kbd "RET"))))

   ;; In help buffers, follow links/buttons — direct call avoids evil keymap shadowing
   ((derived-mode-p 'help-mode 'helpful-mode)
    (call-interactively #'push-button))

   ;; In compilation buffers, follow errors — direct call avoids evil keymap shadowing
   ((derived-mode-p 'compilation-mode)
    (call-interactively #'compile-goto-error))

   ;; In org mode, use org's default behavior
   ;; (evil-org binds RET at a higher priority than evil-normal-state-map, so key-binding works)
   ((derived-mode-p 'org-mode)
    (call-interactively (key-binding (kbd "RET"))))

   ;; In markdown mode, dispatch knowledge queries or follow links
   ;; Direct call avoids infinite recursion: evil-collection doesn't bind RET for markdown
   ((derived-mode-p 'markdown-mode 'gfm-mode)
    (if (and (bound-and-true-p my/knowledge-browser-mode)
             (my/at-knowledge-query-block-p))
        (my/execute-knowledge-query)
      (call-interactively #'markdown-follow-thing-at-point)))

   ;; In sqlite-mode, list table data — direct call avoids infinite recursion:
   ;; sqlite-mode has no evil-collection support, so key-binding resolves back to my/smart-enter
   ((derived-mode-p 'sqlite-mode)
    (call-interactively #'sqlite-mode-list-data))

   ;; In eshell output blocks, show K8s quick actions if applicable
   ((and (derived-mode-p 'eshell-mode)
         (not (evil-insert-state-p))
         (my-k8s-enter-action-mode))
    nil)  ;; my-k8s-enter-action-mode already handled it

   ;; Default: go to definition
   (t
    (call-interactively #'+lookup/definition))))

;; Ensure Enter works normally in insert mode for markdown
(map! :after markdown-mode
      :map markdown-mode-map
      :i "<return>" #'newline
      :i "RET" #'newline)

;; Remap go to definition from gd to ge, and Enter to smart behavior
(map! :map evil-normal-state-map
      "ge" #'+lookup/references   ; Go to definition with ge instead of gd
      "<return>" #'my/smart-enter  ; Smart Enter behavior (GUI)
      "RET" #'my/smart-enter      ; Smart Enter behavior (TTY)
      "<tab>" #'evilem-motion-find-char  ; Find char forward
      "<backtab>" #'evilem-motion-find-char-backward  ; Find char backward
      "S" #'diff-hl-show-hunk  ; Show diff hunk with S
      "U" #'evil-redo)  ; Redo with U (undo is u)

;; Global C-1 to open dired in current directory (override numeric arg)
(define-key global-map (kbd "C-1") nil)  ; Unbind numeric arg
(global-set-key (kbd "C-1") #'dired-jump)
;; Also override in Evil states
(after! evil
  (define-key evil-normal-state-map (kbd "C-1") #'dired-jump)
  (define-key evil-insert-state-map (kbd "C-1") #'dired-jump)
  (define-key evil-motion-state-map (kbd "C-1") #'dired-jump))

;; Configure treemacs to open files in existing splits (most recent window)
(after! treemacs
  ;; Always open files in the most recently used window (other than treemacs)
  (setq treemacs-default-visit-action 'treemacs-visit-node-in-most-recently-used-window)
  ;; Don't create new windows when opening files
  (setq treemacs-show-cursor nil
        treemacs-is-never-other-window t))

;; No manual advice needed - using command hooks approach

;; Keep original bindings - they'll now automatically register jumps
(map! :leader
      "SPC" #'projectile-find-file   ; SPC SPC
      "o" #'projectile-find-file     ; SPC o
      "n" (lambda () (interactive) (+lookup/definition (read-string "Find definition for: ")))     ; Go to symbol in workspace (like VSCode) - fallback option
      ;; "f" #'consult-ripgrep ; Search in project with preview
      "f" #'project-find-regexp ; Search in project with preview
      "e" #'treemacs               ; Toggle treemacs with SPC-e
      "r" #'my/run-nearest-test-with-class  ; Run nearest test with SPC-r (moved from SPC-e)
      "<escape>" #'my-window-layout-close-auxiliary  ; Close auxiliary windows with SPC-ESC
      (:prefix ("q" . "quit")
       :desc "Kill buffer" "k" #'kill-current-buffer))

;; Global C-v for paste (yank) functionality across all modes
(global-set-key (kbd "C-v") #'yank)

;; Also ensure C-v works in Evil states
(after! evil
  (define-key evil-insert-state-map (kbd "C-v") #'yank)
  (define-key evil-emacs-state-map (kbd "C-v") #'yank)
  ;; For normal state, we might want to enter insert mode and paste
  (define-key evil-normal-state-map (kbd "C-v")
    (lambda () (interactive) (evil-insert-state) (yank)))
  ;; Fix C-v in Evil search mode (/)
  (define-key evil-ex-search-keymap (kbd "C-v") #'yank)
  ;; Also fix for Evil ex command mode (:)
  (define-key evil-ex-completion-map (kbd "C-v") #'yank))

;; Enable C-c v and C-v paste in eat buffers
(with-eval-after-load 'eat
  (define-key eat-mode-map (kbd "C-c v") 'eat-yank)
  (define-key eat-mode-map (kbd "C-v") 'eat-yank))

;; Global keybinding for claude-code-terminal-create
(map! "C-c c" #'claude-code-terminal-create)
;; Global keybinding for claude-code-terminal-create-numbered
(map! "C-c n" #'claude-code-terminal-create-numbered)
(map! "C-c r" #'lsp-workspace-restart)
;; Send C-c to mistty subprocess (like C-q C-c)
(after! mistty
  (define-key mistty-mode-map (kbd "C-c C-c")
    (lambda () (interactive)
      (when mistty-proc
        (process-send-string mistty-proc "\C-c")))))
;; Global keybinding for switching to most recent claude terminal
(map! :n "C-f" #'claude-code-terminal-switch-recent
      :i "C-f" #'claude-code-terminal-switch-recent)

;; Smart Q function with context-aware behavior
(defun my/smart-q ()
  "Context-aware Q behavior: different actions based on current buffer/mode."
  (interactive)
  (cond
   ;; In magit commit buffer, save and exit
   ((and (string-match-p "COMMIT_EDITMSG" (buffer-name)))
    (progn
      (evil-ex "wq")))

   ;; In magit log buffer, quit magit
   ((derived-mode-p 'magit-log-mode 'magit-status-mode 'magit-diff-mode)
    (magit-mode-bury-buffer))

   ;; In help buffers, quit window
   ((derived-mode-p 'help-mode 'helpful-mode)
    (quit-window))

   ;; In compilation buffers, quit window
   ((derived-mode-p 'compilation-mode)
    (quit-window))

   ;; In special buffers (start with *), quit window
   ((string-match-p "^\\*" (buffer-name))
    (delete-window))

   ;; Default: delete window (like :q in Vim)
   (t
    (delete-window))))

;; Global keybinding for smart Q and kill buffer with q
(map! :map evil-normal-state-map
      "Q" #'my/smart-q
      "q" #'kill-current-buffer)

;; s = save-buffer, c = evil-substitute (native s behavior)
(after! evil
  (define-key evil-normal-state-map (kbd "s") #'save-buffer)
  (define-key evil-normal-state-map (kbd "c") #'evil-substitute))

;; Global C-t for magit and C-r for revert - works in ALL modes
(after! evil
  (define-key evil-normal-state-map (kbd "C-r") nil))

(map! :nvi "C-t" #'magit-status)
(map! :n "C-r" #'revert-buffer)

;; Window layout key bindings with SPC-w prefix (window management)
(map! :leader
      (:prefix ("w" . "window layout")
       :desc "Setup layout" "s" #'my-window-layout-setup
       :desc "Reset layout" "r" #'my-window-layout-reset
       :desc "Toggle left sidebar" "h" #'my-window-layout-toggle-left-sidebar
       :desc "Toggle right sidebar" "l" #'my-window-layout-toggle-right-sidebar
       :desc "Toggle bottom bar" "j" #'my-window-layout-toggle-bottom-bar
       :desc "Toggle top bar" "k" #'my-window-layout-toggle-top-bar
       :desc "Show with layout" "d" #'my-window-layout-show-with-layout
       :desc "Layout status" "?" #'my-window-layout-status
       ;; Convenience functions
       :desc "Pytest bottom" "p" #'my-window-layout-show-pytest-bottom
       :desc "Treemacs left" "t" #'my-window-layout-show-treemacs-left
       :desc "Terminal bottom" "T" #'my-window-layout-show-terminal-bottom
       :desc "Magit right" "g" #'my-window-layout-show-magit-right))

;; Configure testrun.el for running tests
(use-package! testrun
  :config
  ;; this will allow you to override the runners on your .dir-locals.el
  (put 'testrun-runners 'safe-local-variable #'listp)
  (put 'testrun-mode-alist 'safe-local-variable #'listp)

  ;; Configure testrun to use project root and local venv
  ;; (setq testrun-runners
  ;;       '((python-mode . ("python" "-m" "pytest" "-v"))
  ;;         (python-ts-mode . ("python" "-m" "pytest" "-v"))))
  ;;
  ;; ;; Function to find and activate local venv
  ;; (defun my/testrun-setup-venv ()
  ;;   "Setup virtual environment for testrun."
  ;;   (when-let* ((project-root (projectile-project-root))
  ;;               (venv-path (expand-file-name ".venv" project-root))
  ;;               (python-path (expand-file-name "bin/python" venv-path)))
  ;;     (when (file-exists-p python-path)
  ;;       (setq-local testrun-runners
  ;;                   `((python-mode . (,python-path "-m" "pytest" "-v"))
  ;;                     (python-ts-mode . (,python-path "-m" "pytest" "-v")))))))
  ;;
  ;; ;; Hook to setup venv when entering python files
  ;; (add-hook 'python-mode-hook #'my/testrun-setup-venv)
  ;; (add-hook 'python-ts-mode-hook #'my/testrun-setup-venv)

  ;; Global keybindings with C-c t prefix
  (global-set-key
   (kbd "C-c t")
   (define-keymap
     :prefix 'my/tests-key-map
     "t" 'my/run-nearest-test-with-class  ; Use fixed version
     "o" 'testrun-nearest                 ; Original version for comparison
     "d" 'my/debug-testrun-nearest        ; Debug current position
     "x" 'my/test-detection-at-point      ; Test detection functions
     "s" 'my/show-testrun-config          ; Show testrun config
     "c" 'testrun-namespace
     "f" 'testrun-file
     "a" 'my/testrun-all
     "l" 'testrun-last
     ;; Debug bindings
     "D" 'my/debug-nearest-test           ; Debug nearest test
     "F" 'my/debug-test-file              ; Debug current file
     "A" 'my/debug-test-with-args         ; Debug with custom args
     "b" 'dap-breakpoint-toggle           ; Toggle breakpoint (built-in)
     "B" 'dap-breakpoint-delete-all       ; Clear all breakpoints (built-in)
     "v" 'dap-ui-locals                   ; Show variables (built-in)
     "V" 'dap-ui-sessions                 ; Show debug sessions (built-in)
     "i" 'my/debug-session-info           ; Debug session info (custom)
     "h" 'dap-hydra                       ; Debug controls (built-in)
     "r" 'dap-debug-restart               ; Restart debug session (built-in)
     ))

  ;; Leader key mappings
  (map! :leader
        (:prefix ("t" . "test")
         :desc "Run test" "r" #'testrun
         :desc "Run all tests" "a" #'my/testrun-all)))

(use-package! copilot
  :hook ((prog-mode . copilot-mode)
         (markdown-mode . copilot-mode))
  :bind (:map copilot-completion-map
              ("<tab>" . 'copilot-accept-completion)
              ("TAB" . 'copilot-accept-completion)
              ("C-TAB" . 'copilot-accept-completion-by-word)
              ("C-<tab>" . 'copilot-accept-completion-by-word))
  :config
  ;; Increase max file size for Copilot completions (default is 100000)
  (setq copilot-max-char 1000000)  ; 1 million characters (~500-1000 lines of code)

  ;; Add indentation settings for modes that don't have them in copilot-indentation-alist
  (add-to-list 'copilot-indentation-alist '(prog-mode 4))
  (add-to-list 'copilot-indentation-alist '(text-mode 4))
  (add-to-list 'copilot-indentation-alist '(emacs-lisp-mode lisp-indent-offset))
  (add-to-list 'copilot-indentation-alist '(python-mode python-indent-offset))
  (add-to-list 'copilot-indentation-alist '(python-ts-mode python-indent-offset))
  (add-to-list 'copilot-indentation-alist '(js-mode js-indent-level))
  (add-to-list 'copilot-indentation-alist '(typescript-mode typescript-indent-level))
  (add-to-list 'copilot-indentation-alist '(typescript-ts-mode typescript-ts-mode-indent-offset))
  (add-to-list 'copilot-indentation-alist '(css-mode css-indent-offset))
  (add-to-list 'copilot-indentation-alist '(html-mode sgml-basic-offset))
  (add-to-list 'copilot-indentation-alist '(yaml-mode yaml-indent-offset))
  (add-to-list 'copilot-indentation-alist '(sh-mode sh-basic-offset)))

;; (use-package all-the-icons
;;   :if (display-graphic-p))


;; (use-package! lsp-treemacs-nerd-icons
;;   ;; HACK: Load after the `lsp-treemacs' created default themes
;;   :init (with-eval-after-load 'lsp-treemacs
;;           (require 'lsp-treemacs-nerd-icons)))
;;
;; (use-package! lsp-treemacs
;;   :custom
;;   (lsp-treemacs-theme "nerd-icons-ext"))

(use-package all-the-icons-nerd-fonts
  :after all-the-icons
  :demand t
  :config
  (all-the-icons-nerd-fonts-prefer))

;; (use-package inheritenv :demand t)
;; (use-package transient :demand t)

(use-package monet
  :defer t)

;; Telephone-line for colorful mode line segments
(use-package telephone-line
  :config
  (telephone-line-mode 1))

;; (use-package ultra-scroll
;;   ;:vc (:url "https://github.com/jdtsmith/ultra-scroll") ; if desired (emacs>=v30)
;;   :init
;;   (setq scroll-conservatively 3 ; or whatever value you prefer, since v0.4
;;         scroll-margin 0)        ; important: scroll-margin>0 not yet supported
;;   :config
;;   (ultra-scroll-mode 1)
;;   )

;; (use-package vterm :ensure t)
(use-package claude-code
  :init
  ;; Set terminal backend BEFORE package loads
  (setq claude-code-terminal-backend 'eat)
  :config
  ;; optional IDE integration with Monet
  (add-hook 'claude-code-process-environment-functions #'monet-start-server-function)
  (add-hook 'claude-code-process-environment-functions
            (lambda (_buffer-name dir)
              (list (format "PROJECT_ROOT=%s" (directory-file-name dir)))))
  (monet-mode 1)

  ;; Custom display function to use our window layout main center
  (defun my-claude-display-top-split (buffer)
    "Display Claude buffer in our window layout main center."
    ;; Use the layout system to show buffer in main center
    (my-layout-show-in-main-center buffer)
    ;; Return the main center window
    (my-layout--get-window 'main-center))

  ;; Configure claude-code to use our custom display function
  (setq claude-code-display-window-fn #'my-claude-display-top-split)

  ;; Override find-file behavior when called from claude-code contexts
  (defun my/claude-code-find-file-advice (orig-fun &rest args)
    "Advice to show files opened by claude-code in main center split."
    (let ((result (apply orig-fun args)))
      ;; If we're in a claude-code context and opened a file buffer
      (when (and result
                 (bufferp result)
                 (buffer-file-name result)
                 (or (string-match-p "claude" (buffer-name (current-buffer)))
                     (string-match-p "claude" (format "%s" (car args)))))
        ;; Show the file in main center split
        (my-layout-show-in-main-center result))
      result))

  (advice-add 'find-file :around #'my/claude-code-find-file-advice)
  (advice-add 'find-file-noselect :around #'my/claude-code-find-file-advice)

  ;; Override eat's semi-char-mode-map for claude-code buffers
  (add-hook 'claude-code-start-hook
            (lambda ()
              (define-key eat-semi-char-mode-map (kbd "M-k") #'my-layout-smart-agent-shell)
              (define-key eat-semi-char-mode-map (kbd "C-v") #'clipboard-yank)))

  (claude-code-mode)
  ;; :bind-keymap ("C-c c" . claude-code-terminal-create)

  :bind
  (:repeat-map my-claude-code-map ("M" . claude-code-cycle-mode)))

(spacious-padding-mode)

;; Agent shell - AI coding agents in Emacs (Claude Code, Gemini CLI, etc.)
(use-package! acp
  :defer t)

(use-package! agent-shell
  :after acp
  :commands (agent-shell agent-shell-with-config))

;; Bridge agent-shell with our Emacs MCP server
(add-to-list 'load-path (expand-file-name "modules" doom-user-dir))
(add-to-list 'load-path (expand-file-name "modules/agent-shell" doom-user-dir))
(autoload 'agent-shell-emacs-mcp "agent-shell-emacs-mcp" "Start Claude with Emacs MCP integration." t)
(autoload 'agent-shell-team "agent-shell-team" "Start multi-agent team session." t)
(autoload 'agent-shell-team-status "agent-shell-team" "Team dashboard." t)
(setq agent-shell-team-lead-quick-research-backend 'flash-lite)
(setq agent-shell-team-max-agents-per-role 8)
(after! agent-shell-team
  (add-to-list 'agent-shell-team-role-models '("dev" . "sonnet")))
;; (customize-set-variable 'agent-shell-team-backend 'python)

(defvar my/agent-shell-pending-worktree-path nil
  "Dynamic variable carrying worktree-path during agent-shell--start.
Used by `my/agent-shell-bwrap-prefix' to access the worktree path before
the buffer-local `agent-shell-team--worktree-path' is set.")

(defvar my/agent-shell-pending-role nil
  "Dynamic variable carrying role during agent-shell--start.
Used by `agent-shell-command-prefix' to determine role before
the buffer-local `agent-shell-team--role' is set.")

(defun my/agent-shell-bwrap-prefix (buffer)
  "Return bwrap command prefix for sandboxed dev agents.
If BUFFER has a worktree path (isolated dev agent), return a list of
strings for bubblewrap filesystem sandboxing.  Otherwise return nil
\(no sandboxing for lead, researcher, or neighbor agents).
All paths are resolved to their true filesystem paths to handle
Fedora atomic's /home -> /var/home symlink."
  (condition-case _err
      (let ((worktree-path (or (buffer-local-value 'agent-shell-team--worktree-path buffer)
                              my/agent-shell-pending-worktree-path)))
        (when worktree-path
          (let* ((worktree (file-truename (expand-file-name worktree-path)))
                 ;; Project root is 3 levels up: .agent-shell/worktrees/<name>
                 (project-root (file-truename (expand-file-name "../../.." worktree)))
                 (git-dir (expand-file-name ".git" project-root))
                 (reports-dir (expand-file-name ".agent-shell/reports" project-root))
                 (knowledge-dir (expand-file-name ".agent-shell/knowledge" project-root))
                 (home (file-truename (expand-file-name "~")))
                 (claude-data (expand-file-name ".local/share/claude" home))
                 (claude-config (expand-file-name ".claude" home))
                 (gitconfig (expand-file-name ".gitconfig" home))
                 (git-config-dir (expand-file-name ".config/git" home))
                 (linuxbrew "/var/home/linuxbrew/.linuxbrew"))
            `("bwrap"
              ;; System directories (read-only)
              "--ro-bind" "/usr" "/usr"
              "--ro-bind" "/lib64" "/lib64"
              "--ro-bind" "/etc" "/etc"
              ;; Fedora atomic desktop: /home is a symlink to /var/home.
              ;; Bind mounts use real paths (/var/home/...) but many tools
              ;; resolve $HOME as /home/... so we need this symlink inside
              ;; the sandbox for path resolution to work.
              "--symlink" "/var/home" "/home"
              ;; /bin and /sbin are symlinks to /usr/bin and /usr/sbin on Fedora.
              ;; Node.js execAsync uses /bin/sh, so these must exist in the sandbox.
              "--symlink" "usr/bin" "/bin"
              "--symlink" "usr/sbin" "/sbin"
              ;; Homebrew (read-only — provides node, claude-agent-acp)
              "--ro-bind" ,linuxbrew ,linuxbrew
              ;; Claude data and config (read-only)
              "--ro-bind" ,claude-data ,claude-data
              "--bind" ,claude-config ,claude-config
              ;; MCP settings (read-only — tells Claude Code about available MCP servers)
              ,@(let ((mcp-json (expand-file-name ".mcp.json" home)))
                  (when (file-exists-p mcp-json)
                    (list "--ro-bind" mcp-json mcp-json)))
              ;; Doom Emacs config (read-only — project root for agent-shell)
              "--ro-bind" ,(expand-file-name ".config/doom" home)
                          ,(expand-file-name ".config/doom" home)
              ;; Doom Emacs packages (read-only — needed for pre-commit byte-compilation)
              "--ro-bind" ,(expand-file-name ".config/emacs/.local/straight" home)
                          ,(expand-file-name ".config/emacs/.local/straight" home)
              ;; Git config (read-only)
              ,@(when (file-exists-p gitconfig)
                  (list "--ro-bind" gitconfig gitconfig))
              ,@(when (file-directory-p git-config-dir)
                  (list "--ro-bind" git-config-dir git-config-dir))
              ;; Git common dir (rw — agents need to update refs, logs for branch/commit)
              "--bind" ,git-dir ,git-dir
              ;; Worktree (read-write — agent's working directory)
              "--bind" ,worktree ,worktree
              ;; Reports directory (read-write — agents write reports here)
              "--bind" ,reports-dir ,reports-dir
              ;; Knowledge directory (read-only — agents read knowledge base)
              ,@(when (file-directory-p knowledge-dir)
                  (list "--ro-bind" knowledge-dir knowledge-dir))
              ;; Virtual filesystems
              "--dev" "/dev"
              "--proc" "/proc"
              "--tmpfs" "/tmp"
              ;; DNS resolver (Fedora uses systemd-resolved via symlink from /etc/resolv.conf)
              "--ro-bind" "/run/systemd/resolve" "/run/systemd/resolve"
              ;; Emacs server sockets (rw — emacsclient needs write access to Unix socket)
              "--bind" ,(format "/run/user/%d/emacs" (user-uid))
                       ,(format "/run/user/%d/emacs" (user-uid))
              ;; Network access (needed for MCP stdio, API calls)
              "--share-net"
              ;; Kill sandboxed process when parent dies
              "--die-with-parent"
              ;; Start in the worktree directory
              "--chdir" ,worktree
              "--"))))
    (error nil)))

(after! agent-shell
  ;; Sandbox dev agents with bubblewrap filesystem isolation
  ;; Only set bwrap prefix if agent-shell-team hasn't overwritten it
  (unless (featurep 'agent-shell-team)
    (setq agent-shell-command-prefix #'my/agent-shell-bwrap-prefix))
  ;; Disable the header entirely (set to nil); use 'graphical to restore later
  (setq agent-shell-header-style nil)
  ;; Require MCP tools for the stdio server
  (require 'claude-code-mcp-tools nil t)
  ;; Custom output styling for agent-shell body sections
  (require 'my-agent-shell-style)
  (add-hook 'agent-shell-section-functions #'my/agent-shell-style-sections)
  ;; Mark agent-shell buffers as "real" so Doom doesn't skip them in buffer switching
  (add-hook 'agent-shell-mode-hook #'doom-mark-buffer-as-real-h)
  ;; Custom keybindings for agent-shell buffers
  (require 'my-agent-shell-keybindings)
  ;; Stuck-busy prevention fixes (watchdog, force-reset, interrupt cleanup)
  (require 'my-agent-shell-stuck-busy-fixes)
  ;; Auto-recover from "Session not found" ACP errors
  (require 'my-agent-shell-session-recovery)
  ;; Animated sprite icon — disabled (user doesn't use it)
  ;; (require 'my-agent-shell-sprite)
  ;; Gemini transient error retry with exponential backoff
  (require 'my-agent-shell-gemini-retry)
  ;; Interactive commands (toggle-researcher-backend, request-research)
  (require 'my-agent-shell-commands)
  ;; Approval queue UI for lead agent options
  (require 'my-approval-ui)
  ;; Keybinding for quick access
  (map! :leader
        :desc "Claude (Emacs MCP)" "c c" #'agent-shell-emacs-mcp
        :desc "Claude Team" "c t" #'agent-shell-team
        :desc "Team Status" "c T" #'agent-shell-team-status))

;; Initial setup - enable for normal mode by default
(add-hook 'evil-mode-hook
          (lambda ()
            (when (evil-normal-state-p)
              (my/toggle-hl-line-on-evil-state))))

;; Enhanced dired colors with diredfl - retro amber theme
(use-package! diredfl
  :hook (dired-mode . diredfl-mode)
  :config
  ;; Amber palette for dired
  (set-face-attribute 'diredfl-dir-name nil :foreground "#ffb000" :weight 'bold)
  (set-face-attribute 'diredfl-file-name nil :foreground "#fcd498")
  (set-face-attribute 'diredfl-file-suffix nil :foreground "#c78021")
  (set-face-attribute 'diredfl-symlink nil :foreground "#00ced1" :slant 'italic)
  (set-face-attribute 'diredfl-date-time nil :foreground "#8d7c6a")
  (set-face-attribute 'diredfl-number nil :foreground "#e99f17")
  (set-face-attribute 'diredfl-dir-heading nil :foreground "#ff7300" :weight 'bold)
  (set-face-attribute 'diredfl-exec-priv nil :foreground "#ff9d00")
  (set-face-attribute 'diredfl-read-priv nil :foreground "#ffc677")
  (set-face-attribute 'diredfl-write-priv nil :foreground "#ff7300")
  (set-face-attribute 'diredfl-no-priv nil :foreground "#372413")
  (set-face-attribute 'diredfl-rare-priv nil :foreground "#dda0dd")
  (set-face-attribute 'diredfl-dir-priv nil :foreground "#ffb000")
  (set-face-attribute 'diredfl-deletion nil :foreground "#ff0000" :weight 'bold)
  (set-face-attribute 'diredfl-deletion-file-name nil :foreground "#ff0000")
  (set-face-attribute 'diredfl-flag-mark nil :foreground "#ff9d00" :weight 'bold)
  (set-face-attribute 'diredfl-flag-mark-line nil :background "#2e1e13")
  (set-face-attribute 'diredfl-ignored-file-name nil :foreground "#8d7c6a")
  (set-face-attribute 'diredfl-compressed-file-name nil :foreground "#e99f17")
  (set-face-attribute 'diredfl-compressed-file-suffix nil :foreground "#c78021"))

;; Dired keybindings and filtering (nnn-style)
(use-package! dired-narrow
  :after dired
  :config
  ;; Override dired-narrow to use our custom keymap with arrow navigation
  (advice-add 'dired-narrow--internal :around
              (lambda (orig-fun &rest args)
                (minibuffer-with-setup-hook
                    (lambda ()
                      (use-local-map my-dired-narrow-minibuffer-map))
                  (apply orig-fun args)))))

(defun my-dired-reset-filter ()
  "Reset dired-narrow filter by reverting buffer."
  (interactive)
  (revert-buffer))

(defun my-dired-narrow-exit-and-next ()
  "Exit dired-narrow minibuffer and move to next line."
  (interactive)
  (exit-minibuffer)
  (run-at-time 0.01 nil (lambda ()
                          (when (derived-mode-p 'dired-mode)
                            (dired-next-line 1)))))

(defun my-dired-narrow-exit-and-prev ()
  "Exit dired-narrow minibuffer and move to previous line."
  (interactive)
  (exit-minibuffer)
  (run-at-time 0.01 nil (lambda ()
                          (when (derived-mode-p 'dired-mode)
                            (dired-previous-line 1)))))

(defvar my-dired-narrow-minibuffer-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map minibuffer-local-map)
    (define-key map (kbd "<down>") 'my-dired-narrow-exit-and-next)
    (define-key map (kbd "<up>") 'my-dired-narrow-exit-and-prev)
    map)
  "Keymap for dired-narrow minibuffer with arrow navigation.")

(after! dirvish
  ;; Override dirvish 's' prefix with dired-narrow filter
  (evil-define-key 'normal dirvish-mode-map (kbd "s") 'dired-narrow)
  ;; ESC resets filter
  (evil-define-key 'normal dirvish-mode-map (kbd "<escape>") 'my-dired-reset-filter)
  ;; C-t for magit
  (evil-define-key 'normal dirvish-mode-map (kbd "C-t") 'magit-status)
  ;; Arrow keys for navigation
  (evil-define-key 'normal dirvish-mode-map (kbd "<right>") 'dired-find-file)
  (evil-define-key 'normal dirvish-mode-map (kbd "<left>") 'dired-up-directory)
  (evil-define-key 'normal dirvish-mode-map (kbd "<down>") 'dired-next-line)
  (evil-define-key 'normal dirvish-mode-map (kbd "<up>") 'dired-previous-line))

(after! dired
  ;; Sort by modification time, newest first
  (setq dired-listing-switches "-alht")  ; -t = sort by time, -h = human readable sizes
  ;; Fallback for non-dirvish dired buffers
  (evil-define-key 'normal dired-mode-map (kbd "s") 'dired-narrow)
  (evil-define-key 'normal dired-mode-map (kbd "<escape>") 'my-dired-reset-filter)
  (evil-define-key 'normal dired-mode-map (kbd "C-t") 'magit-status)
  (evil-define-key 'normal dired-mode-map (kbd "<right>") 'dired-find-file)
  (evil-define-key 'normal dired-mode-map (kbd "<left>") 'dired-up-directory)
  (evil-define-key 'normal dired-mode-map (kbd "<down>") 'dired-next-line)
  (evil-define-key 'normal dired-mode-map (kbd "<up>") 'dired-previous-line))

;; Dired modeline with CWD (same styling as terminal)
(defun my-dired-doom-modeline-cwd ()
  "Generate current directory segment for dired doom-modeline."
  (when (derived-mode-p 'dired-mode)
    (let ((cwd (abbreviate-file-name default-directory)))
      (propertize (format " %s " cwd)
                  'face 'claude-code-terminal-cwd-face))))

(with-eval-after-load 'doom-modeline
  (doom-modeline-def-segment dired-cwd
    "Display current directory in dired."
    (my-dired-doom-modeline-cwd))

  (doom-modeline-def-modeline 'my-dired
    '(bar workspace-name window-number matches dired-cwd)
    '(misc-info minor-modes major-mode))

  (add-hook 'dired-mode-hook
            (lambda ()
              (doom-modeline-set-modeline 'my-dired))))

(use-package! elsqlite
  :commands (elsqlite-open)
  :config (elsqlite-evil-setup))

;; Suppress org-persist gc-lock read errors (file gets corrupted during suspend)
(defadvice! my/silence-org-persist-read-errors (fn &rest args)
  :around #'org-persist-read
  (condition-case nil
      (apply fn args)
    (error nil)))
