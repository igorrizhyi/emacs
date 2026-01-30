# Plan: Hybrid agent-shell + MCP Bridge Integration

## Goal
Replace claude-code-emacs process management with agent-shell while keeping our valuable MCP server integration that provides Emacs tools to Claude.

## Current State
- **claude-code-emacs**: Manages Claude Code CLI process directly via eat/eshell
- **MCP Server**: WebSocket server providing 15+ tools (buffers, diagnostics, terminal, diffs)
- **Terminal**: Custom 144KB terminal management code

## Target State
- **agent-shell**: Manages Claude Code CLI process via ACP protocol
- **MCP Server**: Same WebSocket server, connected to agent-shell sessions
- **Terminal**: Simplified - leverage agent-shell's shell-maker infrastructure

---

## Phase 1: Create agent-shell-emacs-mcp Provider

### 1.1 New file: `agent-shell-emacs-mcp.el`

```elisp
;;; agent-shell-emacs-mcp.el --- Emacs MCP integration for agent-shell -*- lexical-binding: t; -*-

(require 'agent-shell)
(require 'claude-code-mcp-connection)

(defun agent-shell-emacs-mcp-make-config ()
  "Create agent-shell config with Emacs MCP integration."
  (agent-shell-make-agent-config
   :id 'claude-code-emacs-mcp
   :display-name "Claude Code (Emacs MCP)"
   :buffer-name "*claude-emacs*"
   :client-maker #'agent-shell-emacs-mcp--make-client
   :welcome-function #'agent-shell-emacs-mcp--welcome
   :on-start-hook #'agent-shell-emacs-mcp--on-start))

(defun agent-shell-emacs-mcp--make-client (buffer)
  "Create ACP client for Claude Code with MCP server env vars."
  ;; Ensure MCP server is running
  (claude-code-mcp-ensure-instance-server)
  ;; Get MCP server connection info
  (let* ((project-root (projectile-project-root))
         (mcp-port (claude-code-mcp-get-port project-root)))
    ;; Create client with MCP env vars
    (agent-shell-anthropic-make-client
     :buffer buffer
     :environment (agent-shell-make-environment-variables
                   `(("EMACS_MCP_PORT" . ,(number-to-string mcp-port))
                     ("EMACS_MCP_PROJECT" . ,project-root))))))

(defun agent-shell-emacs-mcp--on-start ()
  "Hook run when agent-shell session starts."
  ;; Ensure MCP WebSocket connection is established
  (claude-code-mcp-connect-for-project (projectile-project-root)))

(provide 'agent-shell-emacs-mcp)
```

### 1.2 Tasks
- [ ] Create `agent-shell-emacs-mcp.el` provider file
- [ ] Implement `agent-shell-emacs-mcp-make-config`
- [ ] Implement client maker that injects MCP server env vars
- [ ] Add startup hook to ensure MCP connection
- [ ] Register config with agent-shell

---

## Phase 2: Modify MCP Connection for agent-shell Integration

### 2.1 Changes to `claude-code-mcp-connection.el`

Current: MCP connection triggered by claude-code-emacs session start
New: MCP connection can be triggered independently or by agent-shell

```elisp
;; Add function to get MCP port for external use
(defun claude-code-mcp-get-port (project-root)
  "Get MCP server port for PROJECT-ROOT, starting if needed."
  (claude-code-mcp-ensure-instance-server)
  ;; Return port number
  claude-code-mcp-port)

;; Add function to connect without full claude-code session
(defun claude-code-mcp-connect-for-project (project-root)
  "Ensure MCP connection exists for PROJECT-ROOT."
  (unless (claude-code-mcp-project-connected-p project-root)
    (claude-code-mcp-register-port project-root)))
```

### 2.2 Tasks
- [ ] Add `claude-code-mcp-get-port` function
- [ ] Add `claude-code-mcp-connect-for-project` function
- [ ] Ensure MCP server can run independently of claude-code terminal
- [ ] Test MCP tools work when connected via agent-shell

---

## Phase 3: Configure Claude Code CLI for MCP

### 3.1 MCP Server Configuration

Claude Code needs to know about our Emacs MCP server. Two approaches:

**Option A: Environment Variables**
```bash
CLAUDE_MCP_SERVERS='{"emacs":{"command":"emacsclient","args":["--eval","(claude-code-mcp-stdio-handler)"]}}'
```

**Option B: ~/.claude.json config**
```json
{
  "mcpServers": {
    "emacs": {
      "command": "emacsclient",
      "args": ["--eval", "(claude-code-mcp-stdio-handler)"]
    }
  }
}
```

**Option C: agent-shell-mcp-servers variable**
```elisp
(setq agent-shell-mcp-servers
      '(((name . "emacs")
         (transport . stdio)
         (command . "emacsclient")
         (args . ("--eval" "(claude-code-mcp-stdio-handler)")))))
```

### 3.2 Tasks
- [ ] Decide on MCP server configuration approach
- [ ] Implement stdio transport handler if needed
- [ ] Test MCP tools are available to Claude via agent-shell

---

## Phase 4: Verify Terminal Integration Works with agent-shell

### 4.1 Important Clarification

**Two completely separate systems:**

1. **Claude Code CLI process** (what agent-shell manages)
   - The AI agent subprocess
   - Currently spawned by claude-code-core.el via eat
   - Will be replaced by agent-shell's ACP management

2. **Emacs terminal buffers** (claude-code-terminal.el - UNCHANGED)
   - eshell/mistty buffers that Claude controls via MCP
   - MCP tool receives command → sends to eshell → C-enter captures output → returns to MCP → Claude
   - This is the MCP↔Emacs terminal bridge
   - **NO CHANGES NEEDED HERE**

### 4.2 What Stays the Same
- All of `claude-code-terminal.el` (144KB) - terminal enhancements for MCP
- executeTerminalCommandInEmacs flow
- C-enter output capture mechanism
- eshell/mistty session management
- Terminal ID tracking
- Async command monitoring

### 4.3 Architecture Diagram
```
┌─────────────────────────────────────────────────────────────┐
│                    agent-shell (NEW)                        │
│    Manages Claude Code CLI subprocess via ACP protocol      │
└─────────────────────┬───────────────────────────────────────┘
                      │ ACP (stdio)
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                   Claude Code CLI                           │
│              (AI agent, runs commands, etc.)                │
└─────────────────────┬───────────────────────────────────────┘
                      │ MCP Protocol (WebSocket)
                      ▼
┌─────────────────────────────────────────────────────────────┐
│              claude-code-mcp-*.el (UNCHANGED)               │
│    MCP server providing Emacs tools to Claude               │
└─────────────────────┬───────────────────────────────────────┘
                      │ MCP Tool Calls
                      ▼
┌─────────────────────────────────────────────────────────────┐
│            claude-code-terminal.el (UNCHANGED)              │
│    Terminal enhancements for MCP compatibility              │
│    - executeTerminalCommandInEmacs                          │
│    - C-enter output capture                                 │
│    - eshell/mistty session management                       │
└─────────────────────────────────────────────────────────────┘
```

### 4.4 Tasks
- [ ] Verify MCP terminal tools work when Claude is spawned via agent-shell
- [ ] Test executeTerminalCommandInEmacs end-to-end
- [ ] Test C-enter capture flow
- [ ] Confirm no changes needed to terminal.el

---

## Phase 5: Integration & Testing

### 5.1 User-Facing Changes
- `M-x agent-shell` with "Claude Code (Emacs MCP)" option
- OR `M-x agent-shell-emacs-mcp` dedicated command
- Same MCP tools available (buffers, diagnostics, terminal, diffs)
- Multi-agent capability (can also use Gemini, Codex, etc.)

### 5.2 Keybinding Migration
```elisp
;; Old
(map! "C-c c" #'claude-code-terminal-create)

;; New
(map! "C-c c" #'agent-shell-emacs-mcp)
```

### 5.3 Tasks
- [ ] Create `agent-shell-emacs-mcp` command
- [ ] Update keybindings
- [ ] Test all MCP tools work:
  - [ ] getOpenBuffers
  - [ ] getCurrentSelection
  - [ ] getDiagnostics
  - [ ] getDefinition
  - [ ] findReferences
  - [ ] executeTerminalCommandInEmacs
  - [ ] getTerminalContent
  - [ ] createTerminal
  - [ ] openDiffFile
  - [ ] sendNotification
- [ ] Test with different project roots
- [ ] Test multi-session scenarios

---

## Phase 6: Cleanup & Documentation

### 6.1 Deprecate Old Code
- Mark old `claude-code-run` as deprecated
- Keep for backwards compatibility initially
- Remove after transition period

### 6.2 Tasks
- [ ] Add deprecation warnings to old functions
- [ ] Update README with new usage
- [ ] Document MCP server configuration
- [ ] Create migration guide

---

## File Changes Summary

| File | Action |
|------|--------|
| `agent-shell-emacs-mcp.el` | NEW - agent-shell provider |
| `claude-code-mcp-connection.el` | MODIFY - add external connection API |
| `claude-code-mcp-tools.el` | KEEP - MCP tool handlers |
| `claude-code-mcp-protocol.el` | KEEP - JSON-RPC protocol |
| `claude-code-mcp-events.el` | KEEP - event notifications |
| `claude-code-terminal.el` | **KEEP UNCHANGED** - MCP↔terminal bridge |
| `claude-code-core.el` | DEPRECATE - replace with agent-shell |
| `claude-code-ui.el` | MODIFY - adapt for agent-shell (transient menus) |
| `claude-code-emacs.el` | MODIFY - conditional loading |

---

## Risk Mitigation

1. **Keep old code working** - Don't break existing users during transition
2. **Feature parity testing** - Verify all MCP tools work before deprecating
3. **Incremental rollout** - Phase 1-2 first, test, then continue
4. **Fallback option** - Easy to revert to direct process management

---

## Timeline Estimate

- Phase 1: 2-3 hours (provider creation)
- Phase 2: 1-2 hours (MCP connection API)
- Phase 3: 1-2 hours (MCP server config)
- Phase 4: 1 hour (verification only - terminal.el unchanged)
- Phase 5: 2-3 hours (testing)
- Phase 6: 1-2 hours (cleanup)

**Total: ~8-12 hours of focused work**

---

## Questions to Resolve

1. **MCP Transport**: Should we use stdio or WebSocket for MCP?
   - Current: WebSocket (per-project connections)
   - agent-shell default: stdio
   - Recommendation: Keep WebSocket for now, simpler integration

2. **Session Isolation**: How to handle multiple agent-shell sessions?
   - Need unique MCP connections per session
   - Current hash table approach should work

3. **Terminal Ownership**: ✅ RESOLVED
   - agent-shell: manages Claude Code CLI process only
   - claude-code-terminal.el: manages Emacs terminals for MCP tools (UNCHANGED)
   - These are completely separate - no conflict
