import { EmacsBridge } from "../emacs-bridge.js";
import {
  TerminalCommandArgs,
  TerminalCommandResult,
  GetTerminalContentArgs,
  GetTerminalContentResult,
  CreateTerminalArgs,
  CreateTerminalResult,
} from "../schemas/terminal-schema.js";
import * as path from "path";

interface TerminalToolResult {
  content: Array<{ type: "text"; text: string }>;
  success: boolean;
  message?: string;
  terminalId?: string;
  command: string;
  stdout: string;
  stderr: string;
  exitCode: number;
  timeout: boolean;
  workingDirectory: string;
  error?: string;
  isError?: boolean;
}

function validateWorkingDirectory(
  workingDir: string,
  projectRoot: string
): string {
  // Resolve to absolute path
  const resolvedPath = path.resolve(workingDir);
  const resolvedProjectRoot = path.resolve(projectRoot);

  // Check if working directory is within project root
  if (!resolvedPath.startsWith(resolvedProjectRoot)) {
    throw new Error(
      `Working directory must be within project root. Got: ${resolvedPath}, Project root: ${resolvedProjectRoot}`
    );
  }

  return resolvedPath;
}

function sanitizeCommand(command: string): void {
  // Check for null bytes and control characters that could be dangerous
  if (command.includes("\0")) {
    throw new Error("Command contains null bytes");
  }
}

export async function handleExecuteTerminalCommandInEmacs(
  bridge: EmacsBridge,
  args: TerminalCommandArgs
): Promise<TerminalToolResult> {
  if (!bridge.isConnected()) {
    return {
      content: [
        {
          type: "text" as const,
          text: "Error: Emacs is not connected",
        },
      ],
      success: false,
      message: undefined,
      terminalId: args.terminalId,
      command: args.command,
      stdout: "",
      stderr: "Emacs is not connected",
      exitCode: -1,
      timeout: false,
      workingDirectory: "",
      error: "Emacs is not connected",
      isError: true,
    };
  }

  try {
    // Sanitize command
    sanitizeCommand(args.command);

    // Validate and resolve working directory
    const projectRoot = args.projectRoot || process.cwd();
    const workingDirectory = args.workingDirectory
      ? validateWorkingDirectory(args.workingDirectory, projectRoot)
      : projectRoot;

    // Send command to Emacs with optional terminal ID and instance ID
    const result = await bridge.request("executeTerminalCommandInEmacs", {
      terminalId: args.terminalId,
      command: args.command,
      workingDirectory: workingDirectory,
      projectRoot: projectRoot,
      timeout: args.timeout || 30,
      emacs_instance_id: args.emacs_instance_id,
    });

    // Emacs should return: { success, message, terminalId, command, stdout, stderr, exitCode, timeout, workingDirectory, error }
    const emacsResult = result as TerminalCommandResult;

    // Format output for display
    let displayText = "";
    if (emacsResult.error) {
      displayText = `Error: ${emacsResult.error}`;
    } else {
      if (emacsResult.stdout) {
        displayText += `STDOUT:\n${emacsResult.stdout}`;
      }
      if (emacsResult.stderr) {
        displayText += displayText
          ? `\n\nSTDERR:\n${emacsResult.stderr}`
          : `STDERR:\n${emacsResult.stderr}`;
      }
      if (!displayText && emacsResult.message) {
        displayText = emacsResult.message;
      } else if (!displayText) {
        displayText = `Command executed ${
          emacsResult.success ? "successfully" : "with errors"
        } (exit code: ${emacsResult.exitCode})`;
      }
    }

    return {
      content: [
        {
          type: "text" as const,
          text: displayText,
        },
      ],
      success: emacsResult.success,
      message: emacsResult.message,
      terminalId: emacsResult.terminalId || args.terminalId,
      command: args.command,
      stdout: emacsResult.stdout || "",
      stderr: emacsResult.stderr || "",
      exitCode: emacsResult.exitCode,
      timeout: emacsResult.timeout,
      workingDirectory: emacsResult.workingDirectory,
      error: emacsResult.error,
      isError: !emacsResult.success,
    };
  } catch (error) {
    const errorMessage =
      error instanceof Error ? error.message : "Unknown error";

    return {
      content: [
        {
          type: "text" as const,
          text: `Error executing command: ${errorMessage}`,
        },
      ],
      success: false,
      message: undefined,
      terminalId: args.terminalId,
      command: args.command,
      stdout: "",
      stderr: errorMessage,
      exitCode: -1,
      timeout: false,
      workingDirectory: args.workingDirectory || process.cwd(),
      error: errorMessage,
      isError: true,
    };
  }
}

interface GetTerminalContentToolResult {
  content: Array<{ type: "text"; text: string }>;
  success: boolean;
  terminalContent?: string;
  terminalId: string;
  error?: string;
  isError?: boolean;
}

export async function handleGetTerminalContent(
  bridge: EmacsBridge,
  args: GetTerminalContentArgs
): Promise<GetTerminalContentToolResult> {
  if (!bridge.isConnected()) {
    return {
      content: [
        {
          type: "text" as const,
          text: "Error: Emacs is not connected",
        },
      ],
      success: false,
      terminalContent: undefined,
      terminalId: args.terminalId,
      error: "Emacs is not connected",
      isError: true,
    };
  }

  try {
    const result = await bridge.request("getTerminalContent", {
      terminalId: args.terminalId,
      projectRoot: args.projectRoot,
      emacs_instance_id: args.emacs_instance_id,
    });

    const emacsResult = result as GetTerminalContentResult;

    return {
      content: [
        {
          type: "text" as const,
          text:
            emacsResult.success && emacsResult.content
              ? emacsResult.content
              : emacsResult.error || "No content available",
        },
      ],
      success: emacsResult.success,
      terminalContent: emacsResult.content,
      terminalId: emacsResult.terminalId,
      error: emacsResult.error,
      isError: !emacsResult.success,
    };
  } catch (error) {
    const errorMessage =
      error instanceof Error ? error.message : "Unknown error";

    return {
      content: [
        {
          type: "text" as const,
          text: `Error getting terminal content: ${errorMessage}`,
        },
      ],
      success: false,
      terminalContent: undefined,
      terminalId: args.terminalId,
      error: errorMessage,
      isError: true,
    };
  }
}

interface CreateTerminalToolResult extends CreateTerminalResult {
  content: Array<{ type: "text"; text: string }>;
  isError?: boolean;
}

export async function handleCreateTerminal(
  bridge: EmacsBridge,
  args: CreateTerminalArgs
): Promise<CreateTerminalToolResult> {
  if (!bridge.isConnected()) {
    return {
      content: [
        {
          type: "text" as const,
          text: "Error: Emacs is not connected",
        },
      ],
      success: false,
      error: "Emacs is not connected",
      isError: true,
    };
  }

  try {
    const projectRoot = args.projectRoot || process.cwd();
    const directory = args.directory
      ? validateWorkingDirectory(args.directory, projectRoot)
      : projectRoot;

    const result = await bridge.request("createTerminal", {
      directory: directory,
      projectRoot: projectRoot,
      emacs_instance_id: args.emacs_instance_id,
    });

    const emacsResult = result as CreateTerminalResult;

    const displayText = emacsResult.success
      ? emacsResult.message ||
        `Terminal ${emacsResult.terminalId} created successfully`
      : emacsResult.error || "Failed to create terminal";

    return {
      content: [
        {
          type: "text" as const,
          text: displayText,
        },
      ],
      success: emacsResult.success,
      terminalId: emacsResult.terminalId,
      message: emacsResult.message,
      directory: emacsResult.directory,
      error: emacsResult.error,
      isError: !emacsResult.success,
    };
  } catch (error) {
    const errorMessage =
      error instanceof Error ? error.message : "Unknown error";

    return {
      content: [
        {
          type: "text" as const,
          text: `Error creating terminal: ${errorMessage}`,
        },
      ],
      success: false,
      error: errorMessage,
      isError: true,
    };
  }
}
