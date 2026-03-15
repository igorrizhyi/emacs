import { WebSocketServer, WebSocket } from 'ws';
import { EventEmitter } from 'events';

interface JsonRpcRequest {
  jsonrpc: '2.0';
  id: number | string;
  method: string;
  params?: any;
}

interface JsonRpcResponse {
  jsonrpc: '2.0';
  id: number | string;
  result?: any;
  error?: {
    code: number;
    message: string;
    data?: any;
  };
}

export class EmacsBridge extends EventEmitter {
  private wss?: WebSocketServer;
  private clients: Map<string, WebSocket> = new Map();
  private clientInstances: Map<string, { ws: WebSocket; instanceId?: number; projectRoot?: string }> = new Map();
  private sessionId?: string;
  private targetInstanceId?: number;
  private pendingRequests: Map<number | string, {
    resolve: (result: any) => void;
    reject: (error: any) => void;
  }> = new Map();
  private requestId = 0;
  private log: (message: string) => void;
  private onNotification?: (method: string, params: any) => void;

  constructor(logger?: (message: string) => void) {
    super();
    this.log = logger || (() => {});
  }

  async start(port: number = 0, sessionId?: string, targetInstanceId?: number): Promise<number> {
    // Store sessionId in the same format clients connect with (PID:projectRoot)
    // so that exact session match in request() works against client keys
    this.sessionId = targetInstanceId ? `${targetInstanceId}:${sessionId}` : sessionId;
    this.targetInstanceId = targetInstanceId;
    this.log(`EmacsBridge starting with target instance ID: ${targetInstanceId}`);
    return new Promise((resolve, reject) => {
      try {
        this.wss = new WebSocketServer({
          port,
          verifyClient: (info, cb) => {
            try {
              this.log(`WebSocket upgrade request - origin: ${info.origin}, url: ${info.req.url}, headers: ${JSON.stringify(info.req.headers)}`);
              // Accept all connections for now
              cb(true);
            } catch (error) {
              this.log(`Error in verifyClient: ${error}`);
              cb(false, 400, 'Bad Request');
            }
          }
        });

        this.wss.on('connection', (ws, req) => {
          this.log(`WebSocket connection attempt - URL: ${req.url}, headers: ${JSON.stringify(req.headers)}`);

          try {
            const url = new URL(req.url || '', `http://${req.headers.host}`);
            const clientSessionId = decodeURIComponent(url.searchParams.get('session') || 'default');

            // Extract instance ID and project root from session (format: "instanceId:projectRoot")
            let instanceId: number | undefined;
            let projectRoot: string | undefined;
            
            if (clientSessionId.includes(':')) {
              const parts = clientSessionId.split(':', 2);
              instanceId = parseInt(parts[0]);
              projectRoot = parts[1];
            } else {
              projectRoot = clientSessionId;
            }

            // Only accept connections from the target instance if specified
            if (this.targetInstanceId && instanceId !== this.targetInstanceId) {
              this.log(`Rejecting connection from instance ${instanceId} - target is ${this.targetInstanceId}`);
              ws.close(1000, 'Wrong instance');
              return;
            }

            this.log(`Emacs connected - session: ${clientSessionId}, instanceId: ${instanceId}, projectRoot: ${projectRoot}`);
            this.clients.set(clientSessionId, ws);
            this.clientInstances.set(clientSessionId, { ws, instanceId, projectRoot });

            // Trigger notification now that we have the instance connection
            this.emit('client-connected', { instanceId, projectRoot });

            ws.on('message', (data) => {
              try {
                const message = JSON.parse(data.toString());
                this.handleMessage(ws, message);
              } catch (error) {
                this.log(`Invalid message: ${error}`);
              }
            });

            ws.on('close', () => {
              this.log(`Emacs disconnected - session: ${clientSessionId}, instanceId: ${instanceId}, projectRoot: ${projectRoot}`);
              this.clients.delete(clientSessionId);
              this.clientInstances.delete(clientSessionId);
            });

            ws.on('error', (error) => {
              this.log(`WebSocket error: ${error}`);
            });
          } catch (error) {
            this.log(`Error handling WebSocket connection: ${error}`);
            ws.close(1002, 'Invalid request');
          }
        });

      this.wss.on('listening', () => {
        const assignedPort = (this.wss!.address() as any).port;
        this.log(`Emacs bridge listening on port ${assignedPort}`);
        resolve(assignedPort);
      });

      this.wss.on('error', (error) => {
        this.log(`WebSocketServer error: ${error}`);
        reject(error);
      });

      // Add additional error handling
      this.wss.on('headers', (headers, req) => {
        this.log(`WebSocket headers event - URL: ${req.url}`);
      });
      } catch (error) {
        this.log(`Failed to create WebSocketServer: ${error}`);
        reject(error);
      }
    });
  }

  async stop(): Promise<void> {
    if (this.wss) {
      this.clients.forEach((client) => client.close());
      this.clients.clear();
      this.clientInstances.clear();

      return new Promise((resolve) => {
        this.wss!.close(() => resolve());
      });
    }
  }

  private handleMessage(ws: WebSocket, message: any): void {
    // Handle ping message
    if ('type' in message && message.type === 'ping') {
      // Respond with pong
      ws.send(JSON.stringify({ type: 'pong' }));
      return;
    }

    // Handle JSON-RPC response
    if ('id' in message && ('result' in message || 'error' in message)) {
      const pending = this.pendingRequests.get(message.id);
      if (pending) {
        this.pendingRequests.delete(message.id);
        if ('error' in message) {
          this.log(`Emacs Response Error: id=${message.id}, error=${JSON.stringify(message.error)}`);
          pending.reject(new Error(message.error.message));
        } else {
          this.log(`Emacs Response: id=${message.id}, result=${JSON.stringify(message.result)}`);
          pending.resolve(message.result);
        }
      }
    }
    // Handle JSON-RPC request/notification from Emacs
    else if ('method' in message) {
      // If no id, it's a notification
      if (!('id' in message)) {
        this.handleNotification(message.method, message.params);
      } else {
        // Request from Emacs (currently not supported)
        this.sendResponse(ws, message.id, null, {
          code: -32601,
          message: 'Method not found'
        });
      }
    }
  }

  private sendResponse(ws: WebSocket, id: number | string, result?: any, error?: any): void {
    const response: JsonRpcResponse = {
      jsonrpc: '2.0',
      id
    };

    if (error) {
      response.error = error;
    } else {
      response.result = result;
    }

    ws.send(JSON.stringify(response) + '\n');
  }

  async request(method: string, params?: any): Promise<any> {
    // Extract instance ID from params if available
    const instanceId = params?.emacs_instance_id;
    
    let client: WebSocket | null = null;
    
    // If we have an instance ID, try to find the specific client
    if (instanceId) {
      // Look for client with matching session that contains the instance ID
      for (const [sessionId, ws] of this.clients.entries()) {
        // Session ID format might be: project_root or instance_id:project_root
        if (sessionId.includes(instanceId.toString()) || sessionId === instanceId.toString()) {
          client = ws;
          this.log(`Found client for instance ${instanceId}: session=${sessionId}`);
          break;
        }
      }
    }
    
    // Fallback to session-based lookup
    if (!client && this.sessionId) {
      const sessionClient = this.clients.get(this.sessionId);
      if (sessionClient) {
        client = sessionClient;
        this.log(`Found client by exact session match: ${this.sessionId}`);
      }
    }

    // Try matching by project root (sessionId is projectRoot, client keys are "PID:projectRoot")
    if (!client && this.sessionId) {
      for (const [sid, info] of this.clientInstances.entries()) {
        if (info.projectRoot === this.sessionId) {
          client = info.ws;
          this.log(`Found client by project root match: session=${sid}`);
          break;
        }
      }
    }

    if (!client) {
      const connectedClients = Array.from(this.clients.keys()).join(', ');
      this.log(`Request failed: No matching Emacs client found for instanceId=${this.targetInstanceId}, session=${this.sessionId}. Connected clients: ${connectedClients}`);
      throw new Error(`No matching Emacs client found for instanceId=${this.targetInstanceId}, session=${this.sessionId}. Connected clients: ${connectedClients}`);
    }
    
    // Generate instance-specific request ID if instance ID is provided
    const baseId = ++this.requestId;
    const id = instanceId ? `${instanceId}-${baseId}` : baseId;

    const request: JsonRpcRequest = {
      jsonrpc: '2.0',
      id,
      method,
      params
    };

    return new Promise((resolve, reject) => {
      this.pendingRequests.set(id, { resolve, reject });

      this.log(`Emacs Request: ${method} with params: ${JSON.stringify(params)}`);

      client.send(JSON.stringify(request) + '\n', (error) => {
        if (error) {
          this.pendingRequests.delete(id);
          this.log(`Emacs Request Error: ${method} - ${error}`);
          reject(error);
        }
      });

      // Timeout after 30 seconds
      setTimeout(() => {
        if (this.pendingRequests.has(id)) {
          this.pendingRequests.delete(id);
          this.log(`Emacs Request Timeout: ${method} (id=${id}) after 30 seconds`);
          reject(new Error(`Request timeout: ${method}`));
        }
      }, 30000);
    });
  }

  isConnected(): boolean {
    return this.clients.size > 0;
  }

  async sendRequest(method: string, params?: any): Promise<any> {
    return this.request(method, params);
  }

  private handleNotification(method: string, params: any): void {
    this.log(`Received notification from Emacs: ${method}`);
    if (this.onNotification) {
      this.onNotification(method, params);
    }
    // Emit event for the notification
    this.emit('notification', method, params);
  }

  setNotificationHandler(handler: (method: string, params: any) => void): void {
    this.onNotification = handler;
  }

  // Instance-aware notification methods
  broadcastToInstance(instanceId: number, method: string, params: any): void {
    this.log(`Broadcasting to instance ${instanceId}: ${method}`);
    for (const [sessionId, clientInfo] of this.clientInstances.entries()) {
      if (clientInfo.instanceId === instanceId && clientInfo.ws.readyState === 1) {
        const notification = {
          jsonrpc: '2.0',
          method,
          params
        };
        clientInfo.ws.send(JSON.stringify(notification));
        this.log(`Sent notification to instance ${instanceId} (session: ${sessionId})`);
      }
    }
  }

  broadcastToProject(projectRoot: string, method: string, params: any): void {
    this.log(`Broadcasting to project ${projectRoot}: ${method}`);
    for (const [sessionId, clientInfo] of this.clientInstances.entries()) {
      if (clientInfo.projectRoot === projectRoot && clientInfo.ws.readyState === 1) {
        const notification = {
          jsonrpc: '2.0',
          method,
          params
        };
        clientInfo.ws.send(JSON.stringify(notification));
        this.log(`Sent notification to project ${projectRoot} (session: ${sessionId})`);
      }
    }
  }

  getInstanceInfo(instanceId: number): Array<{ sessionId: string; projectRoot?: string }> {
    const instances = [];
    for (const [sessionId, clientInfo] of this.clientInstances.entries()) {
      if (clientInfo.instanceId === instanceId) {
        instances.push({ sessionId, projectRoot: clientInfo.projectRoot });
      }
    }
    return instances;
  }

  getInstanceIdForProject(projectRoot: string): number | null {
    for (const [sessionId, clientInfo] of this.clientInstances.entries()) {
      if (clientInfo.projectRoot === projectRoot && clientInfo.instanceId) {
        return clientInfo.instanceId;
      }
    }
    return null;
  }
}
