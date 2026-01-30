;; -*- no-byte-compile: t; -*-
;;; $DOOMDIR/packages.el

;; To install a package:
;;
;;   1. Declare them here in a `package!' statement,
;;   2. Run 'doom sync' in the shell,
;;   3. Restart Emacs.
;;
;; Use 'C-h f package\!' to look up documentation for the `package!' macro.


;; To install SOME-PACKAGE from MELPA, ELPA or emacsmirror:
;; (package! some-package)

;; To install a package directly from a remote git repo, you must specify a
;; `:recipe'. You'll find documentation on what `:recipe' accepts here:
;; https://github.com/radian-software/straight.el#the-recipe-format
;; (package! another-package
;;   :recipe (:host github :repo "username/repo"))

;; If the package you are trying to install does not contain a PACKAGENAME.el
;; file, or is located in a subdirectory of the repo, you'll need to specify
;; `:files' in the `:recipe':
;; (package! this-package
;;   :recipe (:host github :repo "username/repo"
;;            :files ("some-file.el" "src/lisp/*.el")))

;; If you'd like to disable a package included with Doom, you can do so here
;; with the `:disable' property:
;; (package! builtin-package :disable t)

;; You can override the recipe of a built in package without having to specify
;; all the properties for `:recipe'. These will inherit the rest of its recipe
;; from Doom or MELPA/ELPA/Emacsmirror:
;; (package! builtin-package :recipe (:nonrecursive t))
;; (package! builtin-package-2 :recipe (:repo "myfork/package"))

;; Specify a `:branch' to install a package from a particular branch or tag.
;; This is required for some packages whose default branch isn't 'master' (which
;; our package manager can't deal with; see radian-software/straight.el#279)
;; (package! builtin-package :recipe (:branch "develop"))

;; Use `:pin' to specify a particular commit to install.
;; (package! builtin-package :pin "1a2b3c4d5e")

(package! inheritenv)

;; Add lsp-pyright for better pyright integration
(package! lsp-pyright)

;; Add pyvenv for virtual environment management
(package! pyvenv)

;; Add testrun.el from GitHub
(package! testrun
  :recipe (:host github :repo "martini97/testrun.el"))

;; Add debugging support
(package! dap-mode)
(package! with-venv)

(package! copilot
  :recipe (:host github :repo "copilot-emacs/copilot.el" :files ("*.el")))

;; Add all-the-icons for better icon support
;; (package! all-the-icons)

;; nerd-icons is required by Doom core (dashboard, etc.) - do not disable
;; (package! nerd-icons :disable t)

(package! lsp-treemacs)

;; (package! lsp-treemacs-nerd-icons
;;   :recipe (:host github :repo "Velnbur/lsp-treemacs-nerd-icons" :files ("*.el")))

(package! all-the-icons-nerd-fonts
  :recipe (:host github :repo "mohkale/all-the-icons-nerd-fonts" :files ("*.el")))

;; (package! monet
;;   :recipe (:host github :repo "stevemolitor/monet" :files ("*.el")))

;; (package! claude-code
;;   :recipe (:host github :repo "stevemolitor/claude-code.el" :files ("*.el")))

;; Local packages
(package! monet
  :recipe (:local-repo "modules/monet"))

(package! claude-code
  :recipe (:local-repo "modules/claude-code.el"))

;; WebSocket support for jump animations
(package! catppuccin-theme)
(package! websocket)

(package! ultra-scroll)
(package! eat)
(package! mistty)
(package! cape)
(package! telephone-line)

(package! evil-snipe :disable t)

;; (package! window-stool :recipe (:local-repo "modules/window-stool" :files ("*.el")))
(package! code-context :recipe (:local-repo "modules" :files ("code-context.el")))
;; Enhanced dired font-lock for better file listing colors
(package! diredfl)
;; Filter dired items interactively (like nnn)
(package! dired-narrow)

;; AI-powered git commit messages
(package! llm)
(package! magit-gptcommit
  :recipe (:host github :repo "douo/magit-gptcommit"))

;; Agent shell - AI coding agents in Emacs
(package! shell-maker)
(package! acp)
(package! agent-shell
  :recipe (:host github :repo "xenodium/agent-shell"))

;; Doom's packages are pinned to a specific commit and updated from release to
;; ?release. The `unpin!' macro allows you to unpin single packages... (unpin!
;; pinned-package) ...or multiple packages (unpin! pinned-package
;; another-pinned-package) ...Or *all* packages (NOT RECOMMENDED; will likely
;; break things) (unpin! t)
