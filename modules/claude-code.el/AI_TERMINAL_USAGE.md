# AI Terminal Usage Guide

## Installation and Setup

### Prerequisites
- Emacs 30.0+
- claude-code.el package installed and working
- monet.el MCP server setup
- Claude Code CLI connected to monet

### Verification

1. **Check claude-code.el is loaded:**
   ```elisp
   (featurep 'claude-code)
   ```

2. **Check AI terminal functions are available:**
   ```elisp
   (fboundp 'claude-code--connect-terminal-to-ai)
   (fboundp 'claude-code--execute-ai-command)
   ```

3. **Check monet terminal tool is available:**
   ```elisp
   (fboundp 'monet--tool-terminal-execute-handler)
   ```

## Basic Usage

### 1. Connect a Terminal to AI

In **any terminal buffer** (vterm, eat, term, shell, eshell, or Claude terminal), run:
```
M-x claude-code--connect-terminal-to-ai
```

Or use the keyboard shortcut from the command map:
```
C-c c A  # Connect terminal to AI
C-c c T  # Toggle AI connection
C-c c D  # Disconnect terminal from AI
```

Or access via the transient menu:
```
C-c c m  # Open transient menu, then "A" for AI Terminal
```

### 2. Verify Connection

When a terminal is connected to AI, you should see `[AI-Connected]` in the mode line.

### 3. Test Command Execution

From Claude chat (via MCP), you can now execute commands like:
```
Can you run "ls -la" in the terminal?
```

Claude will use the `terminalExecute` MCP tool to:
1. Send the command to the connected terminal
2. Wait for completion
3. Return the output

### 4. Terminal Selection Support

You can now select text in terminal buffers and Claude will receive the selection context, just like with file buffers.

## Configuration

### Command Confirmation
```elisp
;; Require confirmation for all AI commands (default: t)
(setq claude-code-ai-command-confirmation t)

;; Disable confirmation for safe commands
(setq claude-code-ai-command-confirmation nil)
```

### Timeout Setting
```elisp
;; Set command execution timeout in seconds (default: 30)
(setq claude-code-ai-terminal-timeout 60)
```

### Dangerous Commands List
```elisp
;; Add more dangerous command patterns
(setq claude-code-ai-dangerous-commands 
      '("rm -rf" "sudo" "chmod 777" "mkfs" "dd" "fdisk" "parted" "format" "reboot" "shutdown"))
```

## Testing

### Manual Function Tests

1. **Test command validation:**
   ```elisp
   (claude-code--validate-ai-command "echo hello")     ; Should return t
   (claude-code--validate-ai-command "rm -rf /")       ; Should return nil or prompt
   ```

2. **Test terminal buffer detection:**
   ```elisp
   ;; In any terminal buffer (vterm, eat, term, shell, eshell):
   (claude-code--is-terminal-buffer-p (current-buffer))  ; Should return t
   
   ;; In a regular buffer:
   (claude-code--is-terminal-buffer-p (current-buffer))  ; Should return nil
   ```

3. **Test terminal connection:**
   ```elisp
   ;; In any terminal buffer:
   (claude-code--connect-terminal-to-ai)
   claude-code--ai-connected-terminal                   ; Should show connected buffer
   
   (claude-code--disconnect-terminal-from-ai)
   claude-code--ai-connected-terminal                   ; Should be nil
   ```

### End-to-End Testing

1. **Start any terminal:**
   ```
   M-x vterm          ; or
   M-x eat            ; or  
   M-x term           ; or
   M-x shell          ; or
   M-x eshell         ; or
   M-x claude-code    ; (original Claude terminal)
   ```

2. **Connect to AI:**
   ```
   C-c c A
   ```

3. **In Claude chat, ask to run a simple command:**
   ```
   "Please run 'echo Hello World' in the terminal"
   ```

4. **Verify the command executes and Claude receives the output**

## Troubleshooting

### Common Issues

1. **"No AI-connected terminal available"**
   - Ensure you've connected a terminal using `claude-code--connect-terminal-to-ai`
   - Check that the terminal buffer is still live

2. **"Command execution not available"**
   - Verify claude-code.el is loaded: `(featurep 'claude-code)`
   - Check that the AI terminal functions are available

3. **Commands time out**
   - Increase `claude-code-ai-terminal-timeout`
   - Check if the command actually finished (look for shell prompt)
   
4. **Selection not working in terminal**
   - Verify monet is running and connected
   - Check that the terminal buffer is recognized: `(claude-code--buffer-p (current-buffer))`

### Debug Information

```elisp
;; Check current AI terminal connection
claude-code--ai-connected-terminal

;; Check if buffer is valid for selection
(monet--is-valid-buffer-for-selection (current-buffer))

;; Check available MCP tools (should include "terminalExecute")
(monet--get-tools-list)
```

## Security Considerations

- The implementation includes command validation to prevent dangerous operations
- Commands in `claude-code-ai-dangerous-commands` require extra confirmation
- All commands can require user confirmation if `claude-code-ai-command-confirmation` is enabled
- Terminal execution is limited to the connected terminal buffer only

## Supported Terminal Types

The AI terminal integration now supports **any** terminal buffer type:

### Full Support
- **vterm**: Complete command execution and selection support
- **eat**: Complete command execution and selection support (via claude-code)  
- **term/ansi-term**: Basic command execution support
- **shell**: Basic command execution support
- **eshell**: Basic command execution support

### Command Execution Methods
- **vterm**: Uses `vterm-send-string` and `vterm-send-key`
- **eat**: Uses `eat-term-send-string`
- **term**: Uses `term-send-string` with process
- **shell/eshell**: Uses `insert` + `comint-send-input`/`eshell-send-input`

## Architecture Notes

- **claude-code.el**: Core terminal execution and connection management for ANY terminal
- **monet.el**: MCP bridge providing `terminalExecute` tool to Claude  
- **Terminal Selection**: Extended to support both file and terminal buffers of any type
- **Single Connection**: Only one terminal can be AI-connected at a time (expandable later)
- **Universal Support**: No longer limited to Claude terminals - works with vterm, eat, term, shell, eshell

The implementation now detects terminal buffer types automatically and uses the appropriate method for each terminal emulator.