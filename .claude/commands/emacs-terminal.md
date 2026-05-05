# Emacs Terminal Instructions

When asked to run a terminal command or accomplish a task via the Emacs terminal:

1. **Interpret** the request and determine the appropriate Linux/shell commands.
2. **Find or create a terminal**: If a `term-N` ID is specified, use it. Otherwise check for an existing terminal; if none exists, create one with `mcp__emacs__createTerminal`.
3. **Execute** the commands using `mcp__emacs__executeTerminalCommandInEmacs`, passing the `terminalId` and optional `workingDirectory`.
4. **Retrieve output** with `mcp__emacs__getTerminalContent` and display it with a brief interpretation.
5. **Handle errors**: If a command fails, analyze the error and apply a fix or explain the issue.
6. **Stay context-aware**: Use the current project root and working directory when no path is explicitly given.
7. **Suggest follow-ups** when the output implies obvious next steps.
