import { handleExecuteTerminalCommandInEmacs } from "../../src/tools/terminal-tools.js";
import { EmacsBridge } from "../../src/emacs-bridge.js";

// Mock EmacsBridge
const mockBridge = {
  isConnected: jest.fn(),
  request: jest.fn(),
} as unknown as EmacsBridge;

describe("handleExecuteTerminalCommandInEmacs", () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  test("should return error when Emacs is not connected", async () => {
    (mockBridge.isConnected as jest.Mock).mockReturnValue(false);

    const result = await handleExecuteTerminalCommandInEmacs(mockBridge, {
      command: 'echo "test"',
    });

    expect(result.isError).toBe(true);
    expect(result.stderr).toBe("Emacs is not connected");
    expect(result.exitCode).toBe(-1);
  });

  test("should execute command successfully", async () => {
    (mockBridge.isConnected as jest.Mock).mockReturnValue(true);
    (mockBridge.request as jest.Mock).mockResolvedValue({
      stdout: "test output\n",
      stderr: "",
      exitCode: 0,
      success: true,
      timeout: false,
      workingDirectory: "/test/project",
    });

    const result = await handleExecuteTerminalCommandInEmacs(mockBridge, {
      command: 'echo "test"',
    });

    expect(result.success).toBe(true);
    expect(result.stdout).toBe("test output\n");
    expect(result.stderr).toBe("");
    expect(result.exitCode).toBe(0);
    expect(result.isError).toBe(false);
    expect(mockBridge.request).toHaveBeenCalledWith(
      "executeTerminalCommandInEmacs",
      {
        command: 'echo "test"',
        workingDirectory: process.cwd(),
        timeout: 30,
      }
    );
  });

  test("should handle command with custom working directory", async () => {
    const customDir = process.cwd() + "/test";
    (mockBridge.isConnected as jest.Mock).mockReturnValue(true);
    (mockBridge.request as jest.Mock).mockResolvedValue({
      stdout: "",
      stderr: "",
      exitCode: 0,
      success: true,
      timeout: false,
      workingDirectory: customDir,
    });

    const result = await handleExecuteTerminalCommandInEmacs(mockBridge, {
      command: "ls",
      workingDirectory: customDir,
      timeout: 60,
    });

    expect(result.success).toBe(true);
    expect(mockBridge.request).toHaveBeenCalledWith(
      "executeTerminalCommandInEmacs",
      {
        command: "ls",
        workingDirectory: customDir,
        timeout: 60,
      }
    );
  });

  test("should reject dangerous commands", async () => {
    (mockBridge.isConnected as jest.Mock).mockReturnValue(true);

    const result = await handleExecuteTerminalCommandInEmacs(mockBridge, {
      command: "rm -rf /",
    });

    expect(result.isError).toBe(true);
    expect(result.stderr).toContain("dangerous pattern");
    expect(mockBridge.request).not.toHaveBeenCalled();
  });

  test("should reject commands with null bytes", async () => {
    (mockBridge.isConnected as jest.Mock).mockReturnValue(true);

    const result = await handleExecuteTerminalCommandInEmacs(mockBridge, {
      command: 'echo "test\0"',
    });

    expect(result.isError).toBe(true);
    expect(result.stderr).toBe("Command contains null bytes");
    expect(mockBridge.request).not.toHaveBeenCalled();
  });

  test("should reject working directory outside project", async () => {
    (mockBridge.isConnected as jest.Mock).mockReturnValue(true);

    const result = await handleExecuteTerminalCommandInEmacs(mockBridge, {
      command: "ls",
      workingDirectory: "/etc",
    });

    expect(result.isError).toBe(true);
    expect(result.stderr).toContain(
      "Working directory must be within project root"
    );
    expect(mockBridge.request).not.toHaveBeenCalled();
  });

  test("should handle command execution errors", async () => {
    (mockBridge.isConnected as jest.Mock).mockReturnValue(true);
    (mockBridge.request as jest.Mock).mockRejectedValue(
      new Error("Connection timeout")
    );

    const result = await handleExecuteTerminalCommandInEmacs(mockBridge, {
      command: 'echo "test"',
    });

    expect(result.isError).toBe(true);
    expect(result.stderr).toBe("Connection timeout");
    expect(result.exitCode).toBe(-1);
  });

  test("should handle failed commands with non-zero exit code", async () => {
    (mockBridge.isConnected as jest.Mock).mockReturnValue(true);
    (mockBridge.request as jest.Mock).mockResolvedValue({
      stdout: "",
      stderr: "command not found\n",
      exitCode: 127,
      success: false,
      timeout: false,
      workingDirectory: "/test/project",
    });

    const result = await handleExecuteTerminalCommandInEmacs(mockBridge, {
      command: "nonexistentcommand",
    });

    expect(result.success).toBe(false);
    expect(result.exitCode).toBe(127);
    expect(result.stderr).toBe("command not found\n");
    expect(result.isError).toBe(true);
  });
});
