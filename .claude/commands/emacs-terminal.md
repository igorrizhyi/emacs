# Emacs Terminal Command

This command instructs Claude to interpret a human request, convert it to appropriate terminal commands, and execute them using the Emacs terminal MCP integration.

## Usage

```
/emacs-terminal <human-request> [terminal-id] [working-directory]
```

## Parameters

- `human-request` (required): Natural language description of what you want to accomplish
- `terminal-id` (optional): Specific terminal ID (format: term-1, term-2, etc.)
- `working-directory` (optional): Directory to execute the command in

## Instructions for Claude

When this command is invoked:

1. **Interpret Request**: Analyze the human request to understand the desired outcome
2. **Convert to Commands**: Determine the appropriate Linux/shell commands needed
3. **Use MCP Emacs Terminal Integration**: Execute commands using `mcp__emacs__executeTerminalCommandInEmacs` tool
4. **Create Terminal if Needed**: If no terminal-id is specified and none exists, create one using `mcp__emacs__createTerminal`
5. **Monitor Output**: Use `mcp__emacs__getTerminalContent` to retrieve and display command output
6. **Error Handling**: If commands fail, analyze errors and provide solutions
7. **Context Awareness**: Consider the current working directory and project context

## Example Usage

```
/emacs-terminal "check disk space"
/emacs-terminal "find all Python files in this directory" term-1
/emacs-terminal "show running processes sorted by CPU usage" term-2 /home/user
/emacs-terminal "install dependencies for this Node.js project"
```

## Claude Behavior

- Interpret the human request intelligently
- Choose the most appropriate commands for the task
- Execute commands immediately using MCP integration
- Display command output clearly with brief interpretation
- Explain what commands were chosen and why
- Suggest follow-up commands when relevant
- Maintain terminal session context for related operations