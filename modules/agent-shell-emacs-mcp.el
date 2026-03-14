;;; agent-shell-emacs-mcp.el --- Bridge agent-shell to Emacs MCP server -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Igor Rizhyi
;; Keywords: tools, ai, mcp
;; Version: 0.1.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; This module bridges agent-shell with the existing claude-code-emacs MCP server.
;; It allows using agent-shell to manage Claude Code CLI while keeping
;; the full MCP integration (buffer access, diagnostics, terminal commands, etc.)
;;
;; Architecture:
;;   agent-shell (ACP) → Claude Code CLI → MCP (Node.js server) → WebSocket → Emacs
;;
;; The MCP server is configured globally in ~/.claude.json and provides tools like:
;;   - getOpenBuffers, getCurrentSelection
;;   - getDiagnostics, getDefinition, findReferences
;;   - executeTerminalCommandInEmacs, createTerminal
;;   - openDiffFile, sendNotification
;;
;; No special configuration needed - Claude Code CLI reads ~/.claude.json which
;; has the emacs MCP server configured globally.

;;; Code:

(require 'agent-shell)
(require 'agent-shell-anthropic)
(require 'projectile)

;; Forward declarations for MCP functions
(declare-function claude-code-mcp-ensure-instance-server "claude-code-mcp-connection")
(declare-function claude-code-mcp-register-port "claude-code-mcp-connection")
(declare-function claude-code-mcp-get-connection-info "claude-code-mcp-connection")

(defgroup agent-shell-emacs-mcp nil
  "Agent-shell integration with Emacs MCP server."
  :group 'agent-shell
  :prefix "agent-shell-emacs-mcp-")

(defvar agent-shell-emacs-mcp--active-sessions (make-hash-table :test 'equal)
  "Track active agent-shell sessions with MCP integration.")

(defun agent-shell-emacs-mcp--ensure-mcp-ready ()
  "Ensure MCP server infrastructure is ready.
This ensures the Emacs server is running so the MCP Node.js server
can connect via emacsclient."
  ;; Load MCP modules if not already loaded
  (require 'claude-code-mcp-connection nil t)
  (require 'claude-code-mcp-tools nil t)
  ;; Ensure Emacs server is running with instance-specific name
  (when (fboundp 'claude-code-mcp-ensure-instance-server)
    (claude-code-mcp-ensure-instance-server)))

;;; Agent Configuration

(defun agent-shell-emacs-mcp-make-config ()
  "Create agent-shell config with Emacs MCP integration.
Returns a Claude Code config that includes our Emacs MCP server."
  ;; Ensure MCP is ready
  (agent-shell-emacs-mcp--ensure-mcp-ready)
  ;; Create config based on anthropic's claude-code config
  (agent-shell-make-agent-config
   :identifier 'claude-code-emacs-mcp
   :mode-line-name "Claude (Emacs MCP)"
   :buffer-name "Claude Emacs MCP"
   :shell-prompt "Claude> "
   :shell-prompt-regexp "Claude> "
   :icon-name "anthropic.png"
   :welcome-function #'agent-shell-emacs-mcp--welcome-message
   :client-maker #'agent-shell-emacs-mcp--make-client
   :default-model-id (lambda () agent-shell-anthropic-default-model-id)
   :default-session-mode-id (lambda () agent-shell-anthropic-default-session-mode-id)
   :install-instructions "See https://github.com/zed-industries/claude-code-acp for installation."))

(defun agent-shell-emacs-mcp--make-client (buffer)
  "Create ACP client for Claude Code with Emacs MCP server in BUFFER."
  ;; Ensure MCP is ready before creating client
  (agent-shell-emacs-mcp--ensure-mcp-ready)
  ;; Track this session
  (puthash (buffer-name buffer) (current-time) agent-shell-emacs-mcp--active-sessions)
  ;; Create the anthropic client with EMACS_INSTANCE_ID for session isolation
  (let ((agent-shell-anthropic-claude-environment
         (cons (format "EMACS_INSTANCE_ID=%d" (emacs-pid))
               agent-shell-anthropic-claude-environment)))
    (agent-shell-anthropic-make-claude-client :buffer buffer)))

(defun agent-shell-emacs-mcp--welcome-message (config)
  "Welcome message for Emacs MCP integrated Claude in CONFIG."
  (let ((base-welcome (agent-shell-anthropic--claude-code-welcome-message config)))
    (concat base-welcome
            "\n"
            (propertize "    [Emacs MCP Integration Active]"
                        'face '(:foreground "#00ff00" :weight bold))
            "\n"
            (propertize (format "    Server: emacs-%d | Project: %s"
                               (emacs-pid)
                               (or (projectile-project-name) "none"))
                        'face '(:foreground "#888888")))))

;;; Interactive Commands

;;;###autoload
(defun agent-shell-emacs-mcp ()
  "Start Claude Code with Emacs MCP integration.
This provides Claude with access to Emacs tools via MCP:
- Buffer operations (getOpenBuffers, getCurrentSelection)
- LSP integration (getDiagnostics, getDefinition, findReferences)
- Terminal commands (executeTerminalCommandInEmacs, createTerminal)
- Diff viewing (openDiffFile, openCurrentChanges)

The MCP server is configured globally in ~/.claude.json - no special
setup needed here. We just ensure the Emacs server is running."
  (interactive)
  ;; Ensure MCP infrastructure is ready (Emacs server running)
  (agent-shell-emacs-mcp--ensure-mcp-ready)
  ;; Start agent-shell with our config
  (agent-shell--dwim :config (agent-shell-emacs-mcp-make-config)
                     :new-shell current-prefix-arg))

;;; Cleanup

(defun agent-shell-emacs-mcp-cleanup-session (buffer-name)
  "Clean up MCP session for BUFFER-NAME."
  (remhash buffer-name agent-shell-emacs-mcp--active-sessions))

;; Hook into buffer kill to clean up
(defun agent-shell-emacs-mcp--buffer-kill-hook ()
  "Clean up when agent-shell buffer is killed."
  (when (and (boundp 'agent-shell--state)
             agent-shell--state
             (gethash (buffer-name) agent-shell-emacs-mcp--active-sessions))
    (agent-shell-emacs-mcp-cleanup-session (buffer-name))))

(add-hook 'kill-buffer-hook #'agent-shell-emacs-mcp--buffer-kill-hook)

(provide 'agent-shell-emacs-mcp)
;;; agent-shell-emacs-mcp.el ends here
