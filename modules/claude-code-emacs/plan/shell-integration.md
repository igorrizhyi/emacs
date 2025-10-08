# Shell Integration Implementation Plan

## Overview
Add a new MCP tool `executeTerminalCommandInEmacsInEmacs` that allows Claude Code to run terminal commands through Emacs, providing Claude with the ability to execute shell commands in the project context when editor integration is desired.

## Architecture
```
Claude Code → MCP Server → WebSocket → Emacs → Terminal → Response
```

The tool leverages the existing WebSocket bridge pattern used by other tools like `sendNotification`.

## Implementation Steps

### Phase 1: MCP Server Side (This Repository)

#### 1.1 Create Schema & Types
**File:** `src/schemas/terminal-schema.ts`
```typescript
// Input schema
interface TerminalCommandArgs {
  command: string;           // The shell command to execute
  workingDirectory?: string; // Optional working directory (defaults to project root)
  timeout?: number;         // Optional timeout in seconds (default: 30, max: 300)
}

// Output schema  
interface TerminalCommandResult {
  stdout: string;           // Standard output
  stderr: string;           // Standard error
  exitCode: number;         // Process exit code
  success: boolean;         // true if exitCode === 0
  timeout: boolean;         // true if command timed out
  workingDirectory: string; // Actual working directory used
}
```

#### 1.2 Implement Tool Handler
**File:** `src/tools/terminal-tools.ts`
- Create `handleExecuteTerminalCommand` function
- Follow existing pattern:
  1. Check bridge connection
  2. Validate input parameters
  3. Send request to Emacs via WebSocket
  4. Format and return response
- Add security validations:
  - Command length limits
  - Working directory validation (must be within project)
  - Timeout enforcement (30s default, 300s max)

#### 1.3 Register Tool
**File:** `src/index.ts`
- Add tool registration in `registerTools()` function
- Include proper input/output schema validation

**File:** `src/tools/index.ts`
- Export the handler function

### Phase 2: Emacs Client Side (claude-code Package)

#### 2.1 Add Terminal Command Handler
**File:** `claude-code.el` (in the claude-code Emacs package)
- Add new method handler for `executeTerminalCommandInEmacs`
- Implement in the WebSocket message handling switch statement

#### 2.2 Implement Command Execution
**Function:** `claude-code--execute-terminal-command`
```elisp
(defun claude-code--execute-terminal-command (params)
  "Execute a terminal command with the given PARAMS.
PARAMS should contain:
- command: the shell command to run
- workingDirectory: optional working directory
- timeout: optional timeout in seconds"
  ;; Implementation details below
)
```

**Implementation approach:**
- Use `call-process-shell-command` for synchronous execution
- Set working directory using `default-directory`
- Implement timeout using `with-timeout`
- Capture stdout, stderr, and exit code separately
- Return structured response

#### 2.3 Security Considerations
- Validate working directory is within project bounds
- Sanitize command input (prevent command injection)
- Enforce timeout limits
- Consider blacklisting dangerous commands (rm -rf, etc.)

#### 2.4 Error Handling
- Handle process execution failures
- Manage timeout scenarios
- Provide informative error messages

### Phase 3: Testing & Integration

#### 3.1 Unit Tests
**MCP Server:**
- Test command validation
- Test timeout handling
- Test working directory validation
- Test bridge communication

**Emacs Client:**
- Test command execution
- Test timeout behavior
- Test error scenarios

#### 3.2 Integration Tests
- Test full Claude Code → MCP → Emacs → Terminal flow
- Test various command types (ls, git status, npm install, etc.)
- Test error propagation
- Test concurrent command execution

#### 3.3 Manual Testing
- Test with real Claude Code sessions
- Verify command output formatting
- Test interrupt/cancellation scenarios

## Security Considerations

### Command Validation
- Maximum command length (e.g., 1000 characters)
- No null bytes or control characters
- Optional command whitelist/blacklist

### Directory Restrictions
- Working directory must be within project root
- Prevent directory traversal attacks
- Validate directory exists and is accessible

### Resource Limits
- Maximum execution time (5 minutes)
- Consider memory/CPU limits if possible
- Limit concurrent executions

### Dangerous Commands
Consider preventing or warning about:
- `rm -rf` operations
- `sudo` commands
- Network commands that might expose data
- File system operations outside project

## API Specification

### MCP Tool Definition
```json
{
  "name": "executeTerminalCommandInEmacs",
  "description": "Execute a shell command in the project directory through Emacs",
  "inputSchema": {
    "type": "object",
    "properties": {
      "command": {
        "type": "string",
        "description": "The shell command to execute",
        "maxLength": 1000
      },
      "workingDirectory": {
        "type": "string", 
        "description": "Working directory for command execution (defaults to project root)"
      },
      "timeout": {
        "type": "number",
        "description": "Timeout in seconds (default: 30, max: 300)",
        "minimum": 1,
        "maximum": 300
      }
    },
    "required": ["command"]
  }
}
```

### WebSocket Message Format
```json
{
  "jsonrpc": "2.0",
  "id": 123,
  "method": "executeTerminalCommandInEmacs",
  "params": {
    "command": "git status",
    "workingDirectory": "/path/to/project",
    "timeout": 30
  }
}
```

### Response Format
```json
{
  "jsonrpc": "2.0",
  "id": 123,
  "result": {
    "stdout": "On branch main\nnothing to commit, working tree clean\n",
    "stderr": "",
    "exitCode": 0,
    "success": true,
    "timeout": false,
    "workingDirectory": "/path/to/project"
  }
}
```

## Implementation Notes

### Error Handling
- Network failures: Graceful degradation with clear error messages
- Command failures: Return exit code and stderr information
- Timeout: Clear indication when commands time out
- Permission errors: Helpful messages about file/directory access

### Performance
- Avoid blocking the Emacs UI during command execution
- Consider async execution for long-running commands
- Stream output for long commands if possible

### User Experience
- Clear feedback on command execution status
- Proper formatting of command output
- Integration with Claude Code's logging/feedback systems

## Future Enhancements

### Interactive Commands
- Support for commands requiring user input
- Terminal session management
- Real-time output streaming

### Advanced Features
- Command history
- Environment variable management
- Multi-step command sequences
- Background process management

### Monitoring
- Command execution metrics
- Resource usage tracking
- Audit logging for security

## Dependencies

### MCP Server
- No new dependencies required
- Uses existing WebSocket bridge infrastructure

### Emacs Client
- Requires Emacs 28.1+ (for better process handling)
- May benefit from `async` package for non-blocking execution
- Consider `s.el` for string manipulation if not already present

## Risk Assessment

### High Risk
- Command injection vulnerabilities
- Uncontrolled resource consumption
- Execution of destructive commands

### Medium Risk  
- Directory traversal attacks
- Information disclosure through command output
- Race conditions in concurrent execution

### Low Risk
- Performance impact on Emacs
- Compatibility issues across platforms
- WebSocket communication failures

## Mitigation Strategies
- Comprehensive input validation
- Sandboxing/containerization (future enhancement)
- User confirmation for dangerous operations
- Comprehensive logging and monitoring
- Regular security reviews of command handling code
