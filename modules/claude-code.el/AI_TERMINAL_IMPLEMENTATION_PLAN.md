# AI Terminal Implementation Plan

## Overview

This document outlines the implementation plan for adding AI terminal features to the claude-code.el and monet ecosystem. The features include:

1. **AI Command Execution**: Execute commands from Claude chat via MCP → Emacs client → terminal injection
2. **Terminal Selection Support**: Enable text selection from terminal buffers for Claude context
3. **Single Terminal Connection**: Support one terminal connected to Claude chat (expandable to multiple later)

## Architecture Analysis

### Current Components

#### claude-code.el (Emacs Client)
- **Terminal Backends**: Abstract terminal interface supporting `eat` and `vterm` via `claude-code-terminal-backend`
- **Command Interface**: `claude-code--term-send-string` for sending commands to terminals
- **Buffer Management**: Comprehensive buffer tracking and process control
- **Key Abstractions**: 
  - `claude-code--term-make`: Create terminal instances
  - `claude-code--term-send-string`: Send commands to terminal
  - `claude-code--buffer-p`: Identify Claude buffers

#### monet.el (MCP Server)
- **MCP Bridge**: Websocket-based server connecting Claude to Emacs
- **Selection Tracking**: Already implemented for file buffers via `monet--send-selection`
- **Tool System**: Extensible MCP tool registration and handling
- **Communication**: `monet--send-notification` and response handling

## Implementation Plan

### Phase 1: Basic Command Execution Infrastructure

#### File: `claude-code.el`

Add core terminal command execution functions:

```elisp
;; Terminal AI Integration Variables
(defvar claude-code--ai-connected-terminal nil
  "Currently connected terminal buffer for AI interaction.")

(defvar claude-code--command-execution-timeout 30
  "Timeout in seconds for AI command execution.")

;; Core command execution function
(defun claude-code--execute-ai-command (command)
  "Execute AI-generated COMMAND in current terminal buffer.
Returns a plist with :success, :output, and :error-message."
  (if-let ((terminal-buffer claude-code--ai-connected-terminal))
      (with-current-buffer terminal-buffer
        (let ((start-marker (point-marker))
              (start-time (current-time)))
          ;; Inject command into terminal
          (claude-code--term-send-string claude-code-terminal-backend command)
          (claude-code--term-send-string claude-code-terminal-backend (kbd "RET"))
          
          ;; Wait for command completion and capture output
          (claude-code--wait-for-command-completion start-marker start-time)))
    (list :success nil :error-message "No AI-connected terminal available")))

(defun claude-code--wait-for-command-completion (start-marker start-time)
  "Wait for command completion and return results.
START-MARKER marks the beginning of command output.
START-TIME is when the command was initiated."
  ;; Implementation will monitor terminal for prompt return
  ;; Parse output between start-marker and command completion
  ;; Return structured response
  )

(defun claude-code--parse-command-output (start-pos end-pos)
  "Parse terminal output between START-POS and END-POS.
Returns parsed output with success/failure detection."
  ;; Extract text from terminal buffer
  ;; Detect command success/failure from exit codes or prompt patterns
  ;; Clean up terminal escape sequences
  )
```

#### File: `monet.el`

Add terminal execution MCP tool:

```elisp
;; Terminal execution tool definition
(defconst monet--terminal-tools
  '(((name . "terminal_execute")
     (description . "Execute command in connected Emacs terminal")
     (inputSchema . ((type . "object")
                    (properties . ((command . ((type . "string")
                                              (description . "Command to execute")))
                                  (timeout . ((type . "number")
                                            (description . "Timeout in seconds (optional)")
                                            (default . 30)))))
                    (required . ["command"]))))))

;; Tool handler
(defun monet--handle-terminal-execute-tool (params client)
  "Handle terminal command execution tool call."
  (let* ((command (alist-get 'command params))
         (timeout (or (alist-get 'timeout params) 30))
         (result (claude-code--execute-ai-command command)))
    (if (plist-get result :success)
        (list :content (list (list :type "text" 
                                  :text (format "Command executed successfully:\n%s" 
                                               (plist-get result :output)))))
      (list :isError t 
            :content (list (list :type "text" 
                                :text (format "Command failed: %s" 
                                             (plist-get result :error-message))))))))

;; Register terminal tools
(defun monet--register-terminal-tools ()
  "Register terminal-related MCP tools."
  (setq monet--available-tools 
        (append monet--available-tools monet--terminal-tools)))
```

### Phase 2: Terminal Selection Support

#### File: `monet.el`

Extend buffer selection tracking to terminal buffers:

```elisp
;; Update buffer relevance checking
(defun monet--is-valid-buffer-for-selection (buffer)
  "Check if BUFFER is valid for selection tracking."
  (or (buffer-file-name buffer)          ; File buffers (existing)
      (claude-code--buffer-p buffer)))   ; Terminal buffers (new)

;; Terminal-specific selection tracking
(defun monet--track-terminal-selection (buffer)
  "Track selections in terminal BUFFER."
  (when (and (claude-code--buffer-p buffer)
             (use-region-p))
    (let ((selection-text (buffer-substring-no-properties 
                          (region-beginning) (region-end)))
          (buffer-name (buffer-name buffer)))
      (monet--send-selection-notification 
       :type "terminal"
       :buffer buffer-name
       :text selection-text
       :start (region-beginning)
       :end (region-end)))))

;; Update main selection tracking function
(defun monet--send-selection (client)
  "Send current selection to CLIENT if buffer has file/terminal and is live."
  (when (and (buffer-live-p (current-buffer))
             (monet--is-valid-buffer-for-selection (current-buffer))
             (use-region-p))
    (if (buffer-file-name)
        (monet--send-file-selection client)
      (monet--track-terminal-selection (current-buffer)))))
```

### Phase 3: Terminal Connection Management

#### File: `claude-code.el`

Add terminal AI connection management:

```elisp
;; Terminal connection management
(defun claude-code--connect-terminal-to-ai (&optional buffer)
  "Connect terminal BUFFER (or current buffer) to AI interaction."
  (interactive)
  (let ((target-buffer (or buffer (current-buffer))))
    (unless (claude-code--buffer-p target-buffer)
      (error "Buffer is not a Claude terminal buffer"))
    
    ;; Disconnect any existing terminal
    (when claude-code--ai-connected-terminal
      (claude-code--disconnect-terminal-from-ai))
    
    ;; Connect new terminal
    (setq claude-code--ai-connected-terminal target-buffer)
    
    ;; Add visual indicator
    (with-current-buffer target-buffer
      (setq mode-line-process " [AI-Connected]"))
    
    ;; Register MCP handlers if monet is available
    (when (featurep 'monet)
      (monet--register-terminal-tools))
    
    (message "Terminal connected to AI: %s" (buffer-name target-buffer))))

(defun claude-code--disconnect-terminal-from-ai ()
  "Disconnect current AI terminal."
  (interactive)
  (when claude-code--ai-connected-terminal
    (let ((terminal-buffer claude-code--ai-connected-terminal))
      ;; Remove visual indicator
      (when (buffer-live-p terminal-buffer)
        (with-current-buffer terminal-buffer
          (setq mode-line-process nil)))
      
      ;; Clear connection
      (setq claude-code--ai-connected-terminal nil)
      
      (message "Terminal disconnected from AI: %s" (buffer-name terminal-buffer)))))

(defun claude-code--toggle-terminal-ai-connection ()
  "Toggle AI connection for current terminal buffer."
  (interactive)
  (if (eq claude-code--ai-connected-terminal (current-buffer))
      (claude-code--disconnect-terminal-from-ai)
    (claude-code--connect-terminal-to-ai)))

;; Add to transient menu
(transient-define-prefix claude-code-ai-terminal-menu ()
  "AI Terminal integration menu."
  ["AI Terminal"
   ("c" "Connect terminal to AI" claude-code--connect-terminal-to-ai)
   ("d" "Disconnect terminal from AI" claude-code--disconnect-terminal-from-ai)
   ("t" "Toggle AI connection" claude-code--toggle-terminal-ai-connection)])
```

### Phase 4: Output Parsing and Error Handling

#### File: `claude-code.el`

Implement robust command output parsing:

```elisp
;; Command output parsing
(defun claude-code--detect-command-completion (buffer start-marker)
  "Detect when command has completed in BUFFER since START-MARKER."
  ;; Look for prompt patterns indicating command completion
  ;; Different strategies for eat vs vterm backends
  ;; Return marker position of completion or nil if still running
  )

(defun claude-code--extract-command-output (buffer start-marker end-marker)
  "Extract and clean command output between markers."
  (with-current-buffer buffer
    (let ((raw-output (buffer-substring-no-properties start-marker end-marker)))
      ;; Clean terminal escape sequences
      ;; Remove command echo
      ;; Detect exit codes
      (claude-code--clean-terminal-output raw-output))))

(defun claude-code--clean-terminal-output (output)
  "Clean terminal escape sequences and formatting from OUTPUT."
  ;; Remove ANSI escape codes
  ;; Remove carriage returns
  ;; Normalize whitespace
  )

;; Error handling and validation
(defun claude-code--validate-command (command)
  "Validate COMMAND before execution."
  ;; Check for dangerous commands
  ;; Prompt user for confirmation if needed
  ;; Return t if command is safe to execute
  )

(defun claude-code--handle-command-error (error-type details)
  "Handle command execution errors."
  ;; Log errors
  ;; Provide user feedback
  ;; Attempt recovery if possible
  )
```

### Phase 5: Integration and Testing

#### File: `monet.el`

Complete MCP integration:

```elisp
;; Route terminal requests in main message handler
(defun monet--handle-call-tool (params client)
  "Enhanced tool call handler with terminal support."
  (let ((tool-name (alist-get 'name params)))
    (cond
     ((string= tool-name "terminal_execute")
      (monet--handle-terminal-execute-tool params client))
     ;; ... existing tool handlers
     )))

;; Initialize terminal features
(defun monet--initialize-terminal-features ()
  "Initialize terminal-related features."
  (when (featurep 'claude-code)
    (monet--register-terminal-tools)
    (add-hook 'post-command-hook #'monet--track-terminal-selections)))
```

## Implementation Steps

### Step 1: Core Infrastructure (Week 1)
- [ ] Implement `claude-code--execute-ai-command`
- [ ] Add basic MCP terminal tool to monet.el
- [ ] Test command injection with simple commands

### Step 2: Selection Support (Week 1)
- [ ] Extend monet buffer filtering for terminal buffers
- [ ] Implement terminal selection tracking
- [ ] Test text selection from terminal to Claude

### Step 3: Connection Management (Week 2)
- [ ] Add terminal connection/disconnection functions
- [ ] Implement visual indicators
- [ ] Add transient menu for AI terminal features

### Step 4: Output Parsing (Week 2)
- [ ] Implement command completion detection
- [ ] Add output parsing and cleaning
- [ ] Implement error handling and validation

### Step 5: Integration & Testing (Week 3)
- [ ] Complete MCP request routing
- [ ] End-to-end testing: Claude → MCP → Terminal → Response
- [ ] Performance optimization and edge case handling

## Configuration

### User Configuration Options

```elisp
;; Add to claude-code.el customization
(defcustom claude-code-ai-terminal-timeout 30
  "Default timeout for AI terminal command execution."
  :type 'integer
  :group 'claude-code)

(defcustom claude-code-ai-command-confirmation t
  "Whether to require confirmation for AI-generated commands."
  :type 'boolean
  :group 'claude-code)

(defcustom claude-code-ai-dangerous-commands
  '("rm -rf" "sudo" "chmod 777" "mkfs" "dd")
  "List of command patterns requiring extra confirmation."
  :type '(repeat string)
  :group 'claude-code)
```

### Keybindings

```elisp
;; Add to claude-code-command-map
(define-key claude-code-command-map (kbd "T") 'claude-code-ai-terminal-menu)
(define-key claude-code-command-map (kbd "C-t") 'claude-code--toggle-terminal-ai-connection)
```

## Security Considerations

1. **Command Validation**: Implement whitelist/blacklist for dangerous commands
2. **User Confirmation**: Require explicit confirmation for potentially destructive operations
3. **Sandboxing**: Consider implementing command execution in isolated environments
4. **Audit Trail**: Log all AI-executed commands for security review
5. **Permission Model**: Implement granular permissions for different command types

## Future Enhancements

1. **Multiple Terminal Support**: Extend to support multiple connected terminals
2. **Command History**: Integrate with terminal command history
3. **Smart Parsing**: Improve output parsing with command-specific handlers
4. **Interactive Commands**: Handle commands requiring user input
5. **Terminal Multiplexing**: Support for tmux/screen sessions

## Testing Strategy

1. **Unit Tests**: Test individual functions in isolation
2. **Integration Tests**: Test MCP communication flow
3. **Manual Testing**: Test with various terminal backends (eat/vterm)
4. **Edge Cases**: Test error conditions, timeouts, malformed commands
5. **Performance**: Test with large outputs and concurrent operations

## Conclusion

This implementation plan provides a comprehensive approach to adding AI terminal features while leveraging the existing architecture. The phased approach allows for incremental development and testing, ensuring stability and maintainability.