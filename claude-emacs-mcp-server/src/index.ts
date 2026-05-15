#!/usr/bin/env node

import {
  McpServer,
  ResourceTemplate,
} from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { createServer } from "http";
import { EmacsBridge } from "./emacs-bridge.js";
import {
  sendNotificationInputSchema,
  sendNotificationOutputSchema,
} from "./schemas/notification-schema.js";
import {
  tasksPutInputSchema,
  tasksPutOutputSchema,
} from "./schemas/tasks-schema.js";
import {
  taskUpdateInputSchema,
  taskUpdateOutputSchema,
} from "./schemas/task-update-schema.js";
import {
  dismissAgentInputSchema,
  dismissAgentOutputSchema,
} from "./schemas/dismiss-agent-schema.js";
import {
  messagePeerInputSchema,
  messagePeerOutputSchema,
} from "./schemas/message-peer-schema.js";
import {
  listNamespacePeersInputSchema,
  listNamespacePeersOutputSchema,
} from "./schemas/namespace-schema.js";
import {
  presentOptionsInputSchema,
  presentOptionsOutputSchema,
} from "./schemas/approval-schema.js";
import {
  listPendingReviewsInputSchema,
  listPendingReviewsOutputSchema,
} from "./schemas/review-schema.js";
import {
  getDiagnosticsInputSchema,
  getDiagnosticsOutputSchema,
} from "./schemas/diagnostic-schema.js";
import {
  getDefinitionInputSchema,
  getDefinitionOutputSchema,
} from "./schemas/definition-schema.js";
import {
  findReferencesInputSchema,
  findReferencesOutputSchema,
} from "./schemas/reference-schema.js";
import {
  describeSymbolInputSchema,
  describeSymbolOutputSchema,
} from "./schemas/describe-schema.js";
import {
  getOpenBuffersInputSchema,
  getOpenBuffersOutputSchema,
} from "./schemas/buffer-schema.js";
import {
  getCurrentSelectionInputSchema,
  getCurrentSelectionOutputSchema,
} from "./schemas/selection-schema.js";
import {
  executeTerminalCommandInEmacsInputSchema,
  executeTerminalCommandInEmacsOutputSchema,
  getTerminalContentInputSchema,
  getTerminalContentOutputSchema,
  createTerminalInputSchema,
  createTerminalOutputSchema,
} from "./schemas/terminal-schema.js";
import {
  handleGetOpenBuffers,
  handleGetCurrentSelection,
  handleGetDiagnostics,
  diffTools,
  handleGetDefinition,
  handleFindReferences,
  handleDescribeSymbol,
  handleSendNotification,
  handleTasksPut,
  handleTaskUpdate,
  handleDismissAgent,
  handleMessagePeer,
  handleListNamespacePeers,
  handlePresentOptions,
  handleListPendingReviews,
  handleExecuteTerminalCommandInEmacs,
  handleGetTerminalContent,
  handleCreateTerminal,
} from "./tools/index.js";
import {
  bufferResourceHandler,
  projectResourceHandler,
} from "./resources/index.js";
import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);

// Normalize project root by removing trailing slash
function normalizeProjectRoot(root: string): string {
  return root.replace(/\/$/, "");
}

// Create log file in project root
const projectRoot = normalizeProjectRoot(process.cwd());
const logFile = path.join(projectRoot, ".claude-code-mcp.log");
const logStream = fs.createWriteStream(logFile, { flags: "a" });

function log(message: string) {
  const timestamp = new Date().toISOString();
  logStream.write(`[${timestamp}] ${message}\n`);
}

log(`Starting MCP server for project: ${projectRoot}...`);
log(`Log file: ${logFile}`);

// Create a new bridge instance for each MCP server
// This ensures isolation between different Claude Code sessions
const bridge = new EmacsBridge(log);
let serverPort: number | undefined;

// Track active HTTP sessions (per-session McpServer instances)
const httpSessions = new Map<string, { server: McpServer; transport: StreamableHTTPServerTransport }>();

// The stdio server (used only in stdio mode)
let stdioServer: McpServer | null = null;

function createMcpServer(): McpServer {
  return new McpServer(
    {
      name: "claude-code-mcp",
      version: "0.1.0",
    },
    {
      capabilities: {
        tools: {},
        resources: {
          subscribe: false,
          listChanged: true,
        },
      },
    }
  );
}

// Broadcast a notification to all active servers (stdio + HTTP sessions)
function broadcastServerNotification(method: string, params?: any) {
  if (stdioServer) {
    try {
      stdioServer.server.notification({ method, params });
    } catch (e) {
      log(`Failed to send notification via stdio server: ${e}`);
    }
  }
  for (const [sessionId, { server }] of httpSessions) {
    try {
      server.server.notification({ method, params });
    } catch (e) {
      log(`Failed to send notification to HTTP session ${sessionId}: ${e}`);
    }
  }
}

// Set up instance-aware notification handler
bridge.setNotificationHandler((method: string, params: any) => {
  log(
    `Processing Emacs notification: ${method} with params: ${JSON.stringify(
      params
    )}`
  );

  // Extract context from the notification to determine which instances should receive it
  const instanceId = params?.emacs_instance_id;
  const projectRoot = params?.project_root || params?.projectRoot;

  // Handle buffer list updates - only notify relevant instance
  if (method === "emacs/bufferListUpdated") {
    if (instanceId) {
      // Send to specific instance only
      bridge.broadcastToInstance(
        instanceId,
        "notifications/resources/list_changed",
        {}
      );
      log(`Sent resource list changed notification to instance ${instanceId}`);
    } else if (projectRoot) {
      // Send to specific project only
      bridge.broadcastToProject(
        projectRoot,
        "notifications/resources/list_changed",
        {}
      );
      log(`Sent resource list changed notification to project ${projectRoot}`);
    } else {
      // Fallback: broadcast to all (old behavior)
      broadcastServerNotification("notifications/resources/list_changed", {});
      log(
        "Sent resource list changed notification to all clients (no context)"
      );
    }
  }

  // For other notifications, route based on context
  if (instanceId) {
    bridge.broadcastToInstance(instanceId, method, params);
    log(`Notification sent to instance ${instanceId}: ${method}`);
  } else if (projectRoot) {
    bridge.broadcastToProject(projectRoot, method, params);
    log(`Notification sent to project ${projectRoot}: ${method}`);
  } else {
    // No specific context - send to all clients (for compatibility)
    broadcastServerNotification(method, params);
    log(
      `Notification sent to all clients: ${method} (no instance/project context)`
    );
  }
});

// Register tools with McpServer
function registerTools(server: McpServer) {
  // getOpenBuffers tool
  server.registerTool(
    "getOpenBuffers",
    {
      description: "Get list of open buffers in current project",
      inputSchema: getOpenBuffersInputSchema.shape,
      outputSchema: getOpenBuffersOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleGetOpenBuffers(bridge, args);
      return {
        content: result.content,
        structuredContent: { buffers: result.buffers },
        isError: result.isError,
      };
    }
  );

  // getCurrentSelection tool
  server.registerTool(
    "getCurrentSelection",
    {
      description: "Get current text selection in Emacs",
      inputSchema: getCurrentSelectionInputSchema.shape,
      outputSchema: getCurrentSelectionOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleGetCurrentSelection(bridge, args);
      return {
        content: result.content,
        structuredContent: {
          selection: result.selection,
          file: result.file,
          start: result.start,
          end: result.end,
        },
        isError: result.isError,
      };
    }
  );

  // getDiagnostics tool
  server.registerTool(
    "getDiagnostics",
    {
      description:
        "Get project-wide LSP diagnostics using specified buffer for LSP context",
      inputSchema: getDiagnosticsInputSchema.shape,
      outputSchema: getDiagnosticsOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleGetDiagnostics(bridge, args);
      return {
        content: result.content,
        structuredContent: { diagnostics: result.diagnostics },
        isError: result.isError,
      };
    }
  );

  // getDefinition tool
  server.registerTool(
    "getDefinition",
    {
      description: "Find definition of symbol using LSP",
      inputSchema: getDefinitionInputSchema.shape,
      outputSchema: getDefinitionOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleGetDefinition(bridge, args);
      return {
        content: result.content,
        structuredContent: { definitions: result.definitions },
        isError: result.isError,
      };
    }
  );

  // findReferences tool
  server.registerTool(
    "findReferences",
    {
      description: "Find all references to a symbol using LSP",
      inputSchema: findReferencesInputSchema.shape,
      outputSchema: findReferencesOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleFindReferences(bridge, args);
      return {
        content: result.content,
        structuredContent: { references: result.references },
        isError: result.isError,
      };
    }
  );

  // describeSymbol tool
  server.registerTool(
    "describeSymbol",
    {
      description:
        "Get full documentation and information about a symbol using LSP hover",
      inputSchema: describeSymbolInputSchema.shape,
      outputSchema: describeSymbolOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleDescribeSymbol(bridge, args);
      return {
        content: result.content,
        structuredContent: {
          documentation: result.documentation,
        },
        isError: result.isError,
      };
    }
  );

  // sendNotification tool
  server.registerTool(
    "sendNotification",
    {
      description:
        "Send a desktop notification to alert the user when tasks complete or need attention.",
      inputSchema: sendNotificationInputSchema.shape,
      outputSchema: sendNotificationOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleSendNotification(bridge, args);
      return {
        content: result.content,
        structuredContent: {
          status: result.status,
          message: result.message,
        },
        isError: result.isError,
      };
    }
  );

  // tasksPut tool
  server.registerTool(
    "tasksPut",
    {
      description:
        "Submit tasks to the team lead for assignment to dev/researcher/tester agents.",
      inputSchema: tasksPutInputSchema.shape,
      outputSchema: tasksPutOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleTasksPut(bridge, args);
      return {
        content: result.content,
        structuredContent: {
          success: result.status === 'success',
          message: result.message || '',
        },
        isError: result.isError,
      };
    }
  );

  // taskUpdate tool
  server.registerTool(
    "taskUpdate",
    {
      description:
        "Push a task status update (finished/updated/blocked) to the team lead's queue.",
      inputSchema: taskUpdateInputSchema.shape,
      outputSchema: taskUpdateOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleTaskUpdate(bridge, args);
      return {
        content: result.content,
        structuredContent: {
          success: result.status === 'success',
          message: result.message || '',
        },
        isError: result.isError,
      };
    }
  );

  // dismissAgent tool
  server.registerTool(
    "dismissAgent",
    {
      description:
        "Dismiss a team agent by buffer name or worktree name. Only callable by the lead. Cleans up the agent buffer and worktree.",
      inputSchema: dismissAgentInputSchema.shape,
      outputSchema: dismissAgentOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleDismissAgent(bridge, args);
      return {
        content: result.content,
        structuredContent: {
          success: result.status === 'success',
          message: result.message || '',
        },
        isError: result.isError,
      };
    }
  );

  // messageNamespacePeer tool
  server.registerTool(
    "messageNamespacePeer",
    {
      description:
        "Send a message to another team lead in the same namespace. Used for cross-instance coordination when multiple Emacs instances work on related repositories.",
      inputSchema: messagePeerInputSchema.shape,
      outputSchema: messagePeerOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleMessagePeer(bridge, args);
      return {
        content: result.content,
        structuredContent: {
          success: result.status === 'success',
          message: result.message || '',
        },
        isError: result.isError,
      };
    }
  );

  // listNamespacePeers tool
  server.registerTool(
    "listNamespacePeers",
    {
      description:
        "List currently connected namespace peers with their PIDs, hostnames, and project roots. Use this to discover peers before sending messages with messageNamespacePeer.",
      inputSchema: listNamespacePeersInputSchema.shape,
      outputSchema: listNamespacePeersOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleListNamespacePeers(bridge, args);
      return {
        content: result.content,
        structuredContent: {
          success: result.success ?? (result.status === 'success'),
          message: result.message || '',
          peers: result.peers || [],
          count: result.count ?? 0,
        },
        isError: result.isError,
      };
    }
  );

  // presentOptions tool
  server.registerTool(
    "presentOptions",
    {
      description:
        "Present a list of options to the user for approval or selection. Supports checklist (multi-select) and choice (single-select) modes.",
      inputSchema: presentOptionsInputSchema.shape,
      outputSchema: presentOptionsOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handlePresentOptions(bridge, args, projectRoot);
      return {
        content: result.content,
        structuredContent: {
          success: result.status === 'success',
          message: result.message || '',
        },
        isError: result.isError,
      };
    }
  );

  // listPendingReviews tool
  server.registerTool(
    "listPendingReviews",
    {
      description:
        "List pending review/approval markdown files in .agent-shell/reviews/.",
      inputSchema: listPendingReviewsInputSchema.shape,
      outputSchema: listPendingReviewsOutputSchema.shape,
    },
    async (_args, _extra) => {
      const result = handleListPendingReviews(projectRoot);
      return {
        content: result.content,
        structuredContent: {
          reviews: result.reviews,
          count: result.count,
        },
        isError: result.isError,
      };
    }
  );

  // executeTerminalCommandInEmacs tool
  server.registerTool(
    "executeTerminalCommandInEmacs",
    {
      description:
        "Execute a shell command through Emacs for editor-integrated operations like project builds, git operations within the editor context, or when you need the command to be visible in Emacs. Supports optional terminal ID for executing in specific terminal buffers.",
      inputSchema: executeTerminalCommandInEmacsInputSchema.shape,
      outputSchema: executeTerminalCommandInEmacsOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleExecuteTerminalCommandInEmacs(bridge, args);
      return {
        content: result.content,
        structuredContent: {
          success: result.success,
          message: result.message,
          terminalId: result.terminalId,
          command: result.command,
          stdout: result.stdout,
          stderr: result.stderr,
          exitCode: result.exitCode,
          timeout: result.timeout,
          workingDirectory: result.workingDirectory,
          error: result.error,
        },
        isError: result.isError,
      };
    }
  );

  // getTerminalContent tool
  server.registerTool(
    "getTerminalContent",
    {
      description:
        "Retrieve the complete content of a terminal buffer by terminal ID",
      inputSchema: getTerminalContentInputSchema.shape,
      outputSchema: getTerminalContentOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleGetTerminalContent(bridge, args);
      return {
        content: result.content,
        structuredContent: {
          success: result.success,
          content: result.terminalContent,
          terminalId: result.terminalId,
          error: result.error,
        },
        isError: result.isError,
      };
    }
  );

  // createTerminal tool
  server.registerTool(
    "createTerminal",
    {
      description: "Create a new terminal buffer in a specified directory",
      inputSchema: createTerminalInputSchema.shape,
      outputSchema: createTerminalOutputSchema.shape,
    },
    async (args, _extra) => {
      const result = await handleCreateTerminal(bridge, args);
      return {
        content: result.content,
        structuredContent: {
          success: result.success,
          terminalId: result.terminalId,
          message: result.message,
          directory: result.directory,
          error: result.error,
        },
        isError: result.isError,
      };
    }
  );

  // Register diff tools individually for better type inference
  // openDiffFile tool
  server.registerTool(
    "openDiffFile",
    {
      description: diffTools.openDiffFile.description,
      inputSchema: diffTools.openDiffFile.inputSchema.shape,
      outputSchema: diffTools.openDiffFile.outputSchema.shape,
    },
    async (args, _extra) => {
      const result = await diffTools.openDiffFile.handler(bridge, args);
      return {
        content: result.content,
        structuredContent: result.structuredContent,
        isError: result.isError,
      };
    }
  );

  // openRevisionDiff tool
  server.registerTool(
    "openRevisionDiff",
    {
      description: diffTools.openRevisionDiff.description,
      inputSchema: diffTools.openRevisionDiff.inputSchema.shape,
      outputSchema: diffTools.openRevisionDiff.outputSchema.shape,
    },
    async (args, _extra) => {
      const result = await diffTools.openRevisionDiff.handler(bridge, args);
      return {
        content: result.content,
        structuredContent: result.structuredContent,
        isError: result.isError,
      };
    }
  );

  // openCurrentChanges tool
  server.registerTool(
    "openCurrentChanges",
    {
      description: diffTools.openCurrentChanges.description,
      inputSchema: diffTools.openCurrentChanges.inputSchema.shape,
      outputSchema: diffTools.openCurrentChanges.outputSchema.shape,
    },
    async (args, _extra) => {
      const result = await diffTools.openCurrentChanges.handler(bridge, args);
      return {
        content: result.content,
        structuredContent: result.structuredContent,
        isError: result.isError,
      };
    }
  );

  // openDiffContent tool
  server.registerTool(
    "openDiffContent",
    {
      description: diffTools.openDiffContent.description,
      inputSchema: diffTools.openDiffContent.inputSchema.shape,
      outputSchema: diffTools.openDiffContent.outputSchema.shape,
    },
    async (args, _extra) => {
      const result = await diffTools.openDiffContent.handler(bridge, args);
      return {
        content: result.content,
        structuredContent: result.structuredContent,
        isError: result.isError,
      };
    }
  );
}

// Register resources with dynamic listing
function registerResources(server: McpServer) {
  // Register buffer resources using ResourceTemplate with list callback
  const bufferTemplate = new ResourceTemplate("emacs://buffer/{+path}", {
    list: async () => {
      try {
        const resources = await bufferResourceHandler.list(bridge);
        log(
          `ResourceTemplate list callback: found ${resources.length} buffer resources`
        );
        return { resources };
      } catch (error) {
        log(`Error in ResourceTemplate list callback: ${error}`);
        return { resources: [] };
      }
    },
  });

  server.registerResource(
    "emacs-buffers",
    bufferTemplate,
    {
      title: "Emacs Buffers",
      description: "Open buffers in Emacs",
      mimeType: "text/plain",
    },
    async (uri, variables) => {
      log(`Reading buffer resource: ${uri}, path: ${variables.path}`);
      // Reconstruct the full path with leading slash
      const fullPath = `/${variables.path}`;
      const fullUri = `emacs://buffer${fullPath}`;
      const result = await bufferResourceHandler.read(bridge, fullUri);
      return {
        contents: [
          {
            uri: uri.toString(),
            mimeType: result.mimeType || "text/plain",
            text: result.text as string,
          },
        ],
      };
    }
  );

  // Project info resource (static)
  server.registerResource(
    "project-info",
    "emacs://project/info",
    {
      title: "Project Information",
      description: "Current project information",
      mimeType: "application/json",
    },
    async (uri) => {
      log(`Reading project resource: ${uri}`);
      const result = await projectResourceHandler.read(bridge, uri.toString());
      return {
        contents: [
          {
            uri: uri.toString(),
            mimeType: result.mimeType || "application/json",
            text: result.text as string,
          },
        ],
      };
    }
  );

  log("Resources registered successfully");
}

// Get running Emacs process PIDs using ps command (excludes emacsclient)
async function getRunningEmacsPids(): Promise<number[]> {
  try {
    const { stdout } = await execAsync(
      "ps -eo pid,comm | grep -v grep | grep -v emacsclient | grep -E '[Ee]macs' | awk '{print $1}'"
    );
    const pids = stdout
      .trim()
      .split("\n")
      .filter((line) => line.trim())
      .map((pid) => parseInt(pid.trim()))
      .filter((pid) => !isNaN(pid));
    log(`Found running Emacs PIDs: ${pids.join(", ")}`);
    return pids;
  } catch (error) {
    log(`Failed to get Emacs PIDs: ${error}`);
    return [];
  }
}

// Get target instance ID from project root or use first available Emacs PID
async function getTargetInstanceId(
  projectRoot: string
): Promise<number | null> {
  // First try to get from existing WebSocket connections
  const connectedInstanceId = bridge.getInstanceIdForProject(projectRoot);
  if (connectedInstanceId) {
    return connectedInstanceId;
  }

  // Fallback: try all running Emacs PIDs to find the right one for this project
  const runningPids = await getRunningEmacsPids();
  if (runningPids.length > 0) {
    // We'll try the PIDs in order and let the notification logic handle targeting
    log(
      `No WebSocket connection found, will try all available Emacs PIDs: ${runningPids.join(
        ", "
      )}`
    );
    return runningPids[0]; // Return first, but we'll try all in notifyEmacsPort
  }

  return null;
}

// Notify a specific Emacs instance, or discover the sole running instance
async function notifyEmacsInstance(port: number, projectRoot: string, instanceId?: number): Promise<boolean> {
  const agentBuffer = process.env.EMACS_AGENT_BUFFER;
  const elisp = agentBuffer
    ? `(claude-code-mcp-register-port "${projectRoot}" ${port} "${agentBuffer}")`
    : `(claude-code-mcp-register-port "${projectRoot}" ${port})`;

  if (instanceId) {
    // Direct: use emacs-{instanceId} server name
    const serverName = `emacs-${instanceId}`;
    try {
      await execAsync(`emacsclient -s ${serverName} --eval '${elisp}'`);
      log(`Successfully notified Emacs instance ${instanceId} about port ${port} for project ${projectRoot}`);
      return true;
    } catch (error) {
      log(`Failed to notify Emacs instance ${instanceId}: ${error}`);
      return false;
    }
  }

  // Fallback: check how many Emacs instances are running
  const pids = await getRunningEmacsPids();
  if (pids.length === 0) {
    log('No running Emacs instances found');
    return false;
  }
  if (pids.length > 1) {
    log(`Multiple Emacs instances found (PIDs: ${pids.join(', ')}). Set EMACS_INSTANCE_ID env var or launch claude from within Emacs.`);
    return false;
  }
  // Exactly one instance — safe to use
  const serverName = `emacs-${pids[0]}`;
  try {
    await execAsync(`emacsclient -s ${serverName} --eval '${elisp}'`);
    log(`Successfully notified Emacs instance ${pids[0]} about port ${port} for project ${projectRoot}`);
    return true;
  } catch (error) {
    log(`Failed to notify Emacs instance ${pids[0]}: ${error}`);
    return false;
  }
}

// Create a fully-configured McpServer with all tools and resources registered
function createConfiguredServer(): McpServer {
  const srv = createMcpServer();
  registerTools(srv);
  registerResources(srv);
  return srv;
}

// Notify Emacs about the port using direct instance targeting
async function notifyEmacsPort(port: number, targetInstanceId?: number): Promise<void> {
  const projectRoot = normalizeProjectRoot(process.cwd());
  const success = await notifyEmacsInstance(port, projectRoot, targetInstanceId);
  if (!success) {
    log(`Warning: Failed to notify any Emacs instance about port ${port} for project ${projectRoot}`);
  }
}

// Start server
async function main() {
  // Use project root as session ID
  const sessionId = normalizeProjectRoot(process.cwd());
  
  // Determine target Emacs instance for this MCP server
  const envInstanceId = process.env.EMACS_INSTANCE_ID
    ? parseInt(process.env.EMACS_INSTANCE_ID, 10)
    : undefined;
  let targetInstanceId = envInstanceId;

  if (!targetInstanceId) {
    const runningPids = await getRunningEmacsPids();
    if (runningPids.length > 0) {
      targetInstanceId = Math.max(...runningPids);
    }
  }
  if (targetInstanceId) {
    log(`Target Emacs instance: ${targetInstanceId}${envInstanceId ? ' (from env)' : ' (pid heuristic)'}`);
  }

  // Start Emacs bridge with port 0 for automatic assignment and target instance
  const port = await bridge.start(0, sessionId, targetInstanceId);
  serverPort = port;

  // Notify Emacs about the assigned port using ps-based instance discovery
  await notifyEmacsPort(port, targetInstanceId);

  // Determine transport mode
  const useHttp = process.argv.includes("--http") || process.env.MCP_TRANSPORT === "http";

  if (useHttp) {
    const httpPort = process.env.EMACS_MCP_PORT ? parseInt(process.env.EMACS_MCP_PORT, 10) : 0;

    const httpServer = createServer(async (req, res) => {
      const url = new URL(req.url || "/", `http://127.0.0.1`);

      if (url.pathname === "/mcp") {
        // Check for existing session
        const existingSessionId = req.headers["mcp-session-id"] as string | undefined;

        if (existingSessionId && httpSessions.has(existingSessionId)) {
          // Existing session - reuse transport
          const session = httpSessions.get(existingSessionId)!;
          await session.transport.handleRequest(req, res);
        } else if (!existingSessionId && req.method === "POST") {
          // New session - create per-session McpServer + transport
          const sessionServer = createConfiguredServer();
          const transport = new StreamableHTTPServerTransport({
            sessionIdGenerator: () => crypto.randomUUID(),
            onsessioninitialized: (newSessionId) => {
              httpSessions.set(newSessionId, { server: sessionServer, transport });
              log(`HTTP session initialized: ${newSessionId}`);
            },
          });

          // Connect first, then set onclose to avoid Protocol.connect() overwriting it
          await sessionServer.connect(transport);

          // Compose our cleanup with Protocol's onclose handler
          const protocolOnclose = transport.onclose;
          transport.onclose = () => {
            if (transport.sessionId) {
              httpSessions.delete(transport.sessionId);
              log(`HTTP session closed: ${transport.sessionId}`);
            }
            // Call Protocol's original onclose handler
            if (protocolOnclose) {
              protocolOnclose();
            }
          };

          await transport.handleRequest(req, res);
        } else {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "Bad Request: No valid session" }));
          return;
        }
      } else {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "Not Found" }));
      }
    });

    await new Promise<void>((resolve) => {
      httpServer.listen(httpPort, "127.0.0.1", () => {
        const addr = httpServer.address();
        const actualPort = typeof addr === "object" && addr ? addr.port : httpPort;
        // Print port to stdout for callers to discover
        process.stdout.write(`PORT=${actualPort}\n`);
        log(`HTTP transport listening on 127.0.0.1:${actualPort}`);
        resolve();
      });
    });

    log(`MCP server (HTTP) running for session ${sessionId}, Emacs bridge on port ${port}`);
  } else {
    // Default: stdio transport — single McpServer instance
    stdioServer = createConfiguredServer();

    const PING_NORMAL_INTERVAL = 30000;
    const PING_RETRY_INITIAL = 5000;
    const PING_RETRY_MAX = 60000;
    const PING_FAILURE_TIMEOUT = 5 * 60 * 1000; // 5 minutes

    let pingRetryDelay = 0;
    let pingFailureSince: number | null = null;

    const ping = async () => {
      try {
        await stdioServer!.server.ping();
        if (pingFailureSince !== null) {
          const downtime = Math.round((Date.now() - pingFailureSince) / 1000);
          log(`Ping recovered for session ${sessionId} after ${downtime}s of failures. Resuming normal ping cycle.`);
          pingFailureSince = null;
          pingRetryDelay = 0;
        } else {
          log(`Ping successful for session ${sessionId}`);
        }
        setTimeout(ping, PING_NORMAL_INTERVAL);
      } catch (error) {
        const now = Date.now();
        if (pingFailureSince === null) {
          pingFailureSince = now;
          pingRetryDelay = PING_RETRY_INITIAL;
          log(`Ping failed for session ${sessionId} — entering suspended state, will retry in ${pingRetryDelay / 1000}s`);
        } else {
          const elapsed = now - pingFailureSince;
          if (elapsed >= PING_FAILURE_TIMEOUT) {
            log(`Ping has failed for ${Math.round(elapsed / 1000)}s (>${PING_FAILURE_TIMEOUT / 1000}s). CLI appears truly dead. Exiting.`);
            await cleanup();
            process.exit(1);
          }
          pingRetryDelay = Math.min(pingRetryDelay * 2, PING_RETRY_MAX);
          log(`Ping still failing for session ${sessionId} (${Math.round(elapsed / 1000)}s elapsed). Retrying in ${pingRetryDelay / 1000}s...`);
        }
        setTimeout(ping, pingRetryDelay);
      }
    };
    stdioServer.server.oninitialized = () => {
      log(
        `MCP server initialized for session ${sessionId}, Emacs bridge on port ${port}`
      );
      log(`Starting ping monitoring for session ${sessionId}`);
      ping();
      const cap = stdioServer!.server.getClientCapabilities();
      log(`Client capabilities: ${JSON.stringify(cap)}`);
    };

    const transport = new StdioServerTransport();
    await stdioServer.connect(transport);
    log(`MCP server (stdio) running for session ${sessionId}, Emacs bridge on port ${port}`);
  }
}

// Cleanup on exit
process.on("SIGINT", async () => {
  log("Received SIGINT, shutting down...");
  await cleanup();
  process.exit(0);
});

process.on("SIGTERM", async () => {
  log("Received SIGTERM, shutting down...");
  await cleanup();
  process.exit(0);
});

// Handle uncaught exceptions and rejections
process.on("uncaughtException", (error) => {
  log(`Uncaught exception: ${error.message}`);
  log(`Stack: ${error.stack}`);
  log(`Project root: ${normalizeProjectRoot(process.cwd())}`);
  cleanup().then(() => process.exit(1));
});

process.on("unhandledRejection", (reason, promise) => {
  log(`Unhandled rejection at: ${promise}, reason: ${reason}`);
  log(`Project root: ${normalizeProjectRoot(process.cwd())}`);
  // Log only — do NOT exit. A single session's rejection must not kill the shared server.
});

async function cleanup() {
  const projectRoot = normalizeProjectRoot(process.cwd());
  const targetInstanceId = await getTargetInstanceId(projectRoot);
  const portArg = serverPort ? ` ${serverPort}` : '';
  const elisp = `(claude-code-mcp-unregister-port "${projectRoot}"${portArg})`;

  if (targetInstanceId) {
    // Use instance-specific server
    const serverName = `emacs-${targetInstanceId}`;
    try {
      await execAsync(`emacsclient -s ${serverName} --eval '${elisp}'`);
      log(
        `Unregistered port for project ${projectRoot} from instance ${targetInstanceId}`
      );
    } catch (error) {
      log(
        `Failed to unregister port from instance ${targetInstanceId}: ${error}`
      );
      // Fallback to default
      await cleanupFallback(elisp, projectRoot);
    }
  } else {
    await cleanupFallback(elisp, projectRoot);
  }
}

async function cleanupFallback(
  elisp: string,
  projectRoot: string
): Promise<void> {
  try {
    await execAsync(`emacsclient --eval '${elisp}'`);
    log(`Unregistered port for project ${projectRoot} (fallback)`);
  } catch (error) {
    log(`Failed to unregister port: ${error}`);
  }

  // Clean up port file
  try {
    const portFile = path.join(
      os.tmpdir(),
      `claude-code-mcp-${projectRoot.replace(/[^a-zA-Z0-9]/g, "_")}.port`
    );
    await fs.promises.unlink(portFile);
    log(`Removed port file ${portFile}`);
  } catch (error) {
    log(`Failed to remove port file: ${error}`);
  }

  await bridge.stop();
}

main().catch((error) => {
  log(`Server error: ${error.message}`);
  log(`Stack: ${error.stack}`);
  log(`Project root: ${normalizeProjectRoot(process.cwd())}`);
  log(`Process info: PID=${process.pid}, Node=${process.version}`);
  cleanup().then(() => process.exit(1));
});
