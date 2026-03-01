# Terminal MCP Tools Specification

This document describes the MCP (Model Context Protocol) tools for terminal integration between Claude Code and Emacs.

## Overview

The terminal MCP tools enable Claude to interact with terminal buffers within Emacs. Each terminal buffer has a unique ID that allows Claude to read content, execute commands, and manage terminal sessions through the MCP server.

## Terminal Buffer Management

### Buffer Naming Convention
- Format: `*claude-terminal:<project-name>:<terminal-id>*`
- Example: `*claude-terminal:my-project:term-1*`

### Terminal ID Format
- Pattern: `term-<number>`
- Examples: `term-1`, `term-2`, `term-3`
- Generated sequentially per session

## MCP Tools

### 1. `getTerminalContent`

**Purpose**: Retrieve the complete content of a terminal buffer.

**Parameters**:
- `terminalId` (required, string): The unique terminal identifier
- `projectRoot` (optional, string): Project root path for context

**Request Example**:
```json
{
  "method": "tools/call",
  "params": {
    "name": "getTerminalContent",
    "arguments": {
      "terminalId": "term-1",
      "projectRoot": "/home/user/project"
    }
  }
}
```

**Response Format**:
```json
{
  "success": true,
  "content": "user@host:~/project$ ls\nfile1.txt  file2.txt  directory/\nuser@host:~/project$ echo 'Hello World'\nHello World\nuser@host:~/project$ ",
  "terminalId": "term-1"
}
```

**Error Response**:
```json
{
  "success": false,
  "error": "Terminal not found or no content available"
}
```

### 2. `executeTerminalCommand`

**Purpose**: Execute a command in a specific terminal buffer.

**Parameters**:
- `terminalId` (required, string): The unique terminal identifier
- `command` (required, string): The command to execute
- `projectRoot` (optional, string): Project root path for context

**Request Example**:
```json
{
  "method": "tools/call",
  "params": {
    "name": "executeTerminalCommand",
    "arguments": {
      "terminalId": "term-1",
      "command": "ls -la",
      "projectRoot": "/home/user/project"
    }
  }
}
```

**Response Format**:
```json
{
  "success": true,
  "message": "Command executed successfully",
  "terminalId": "term-1",
  "command": "ls -la"
}
```

**Error Response**:
```json
{
  "success": false,
  "error": "Failed to execute command - terminal not found or not accessible"
}
```

### 3. `getTerminalList`

**Purpose**: List all active terminal sessions, optionally filtered by project.

**Parameters**:
- `projectRoot` (optional, string): Filter terminals by project root

**Request Example**:
```json
{
  "method": "tools/call",
  "params": {
    "name": "getTerminalList",
    "arguments": {
      "projectRoot": "/home/user/project"
    }
  }
}
```

**Response Format**:
```json
{
  "success": true,
  "terminals": [
    {
      "terminalId": "term-1",
      "bufferName": "*claude-terminal:project:term-1*",
      "projectRoot": "/home/user/project"
    },
    {
      "terminalId": "term-2", 
      "bufferName": "*claude-terminal:project:term-2*",
      "projectRoot": "/home/user/project"
    }
  ],
  "count": 2
}
```

**Error Response**:
```json
{
  "success": false,
  "error": "Error message describing the issue"
}
```

### 4. `createTerminal`

**Purpose**: Create a new terminal buffer in a specified directory.

**Parameters**:
- `directory` (optional, string): Working directory for the new terminal
- `projectRoot` (optional, string): Project root context

**Request Example**:
```json
{
  "method": "tools/call",
  "params": {
    "name": "createTerminal",
    "arguments": {
      "directory": "/home/user/project/subdirectory",
      "projectRoot": "/home/user/project"
    }
  }
}
```

**Response Format**:
```json
{
  "success": true,
  "terminalId": "term-3",
  "message": "Terminal created successfully",
  "directory": "/home/user/project/subdirectory"
}
```

**Error Response**:
```json
{
  "success": false,
  "error": "Failed to create terminal"
}
```

## Implementation Details

### Emacs Side (claude-code-terminal.el)

**Key Functions**:
- `claude-code-terminal-create(&optional directory)`: Creates new terminal
- `claude-code-terminal-get-content(terminal-id &optional project-root)`: Retrieves content
- `claude-code-terminal-execute-command(terminal-id command &optional project-root)`: Executes command
- `claude-code-terminal-list-active()`: Lists active terminals

**Session Tracking**:
- Hash table `claude-code-terminal-sessions` tracks sessions by project root
- Each terminal buffer stores `claude-code-terminal-id` as buffer-local variable
- Automatic cleanup of dead buffers via kill-buffer-hook

### MCP Server Side (claude-code-mcp-tools.el)

**Handler Functions**:
- `claude-code-mcp-handle-getTerminalContent(params)`
- `claude-code-mcp-handle-executeTerminalCommand(params)`
- `claude-code-mcp-handle-getTerminalList(params)`
- `claude-code-mcp-handle-createTerminal(params)`

**Error Handling**:
- All handlers use `condition-case` for robust error handling
- Missing required parameters return appropriate error messages
- Function availability checked with `fboundp`

## User Workflow

1. **Create Terminal**: User creates terminal via `C-c c n` (transient menu)
2. **Work in Terminal**: User executes commands, builds projects, etc.
3. **Start Claude Chat**: User presses `C-c C-c` in terminal buffer
4. **Claude Context**: Claude can see terminal content via `getTerminalContent`
5. **Command Execution**: Claude can execute commands via `executeTerminalCommand`
6. **Session Management**: Claude can list/create terminals as needed

## Security Considerations

- Command execution is limited to the terminal's current working directory
- No privilege escalation mechanisms provided
- Terminal content is read-only unless explicitly executed via MCP tools
- Project isolation ensures terminals are scoped to specific projects

## Performance Notes

- Terminal content retrieval gets full buffer content (no pagination currently)
- Command execution is asynchronous (fire-and-forget)
- Session cleanup happens automatically on buffer kill
- Terminal list filtered efficiently by project root when specified

## Error Conditions

Common error scenarios and responses:

1. **Terminal Not Found**: Terminal ID doesn't exist or buffer was killed
2. **Command Execution Failure**: Terminal not accessible or vterm mode issues
3. **Missing Parameters**: Required terminalId or command not provided
4. **Function Unavailability**: Terminal module not loaded or vterm not available

## Future Enhancements

Potential improvements for consideration:

- **Content Pagination**: Support for retrieving terminal content in chunks
- **Command History**: Access to terminal command history
- **Output Streaming**: Real-time command output monitoring
- **Terminal Configuration**: Custom shell, environment variables
- **Session Persistence**: Save/restore terminal sessions across Emacs restarts