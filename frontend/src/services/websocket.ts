import ReconnectingWebSocket from 'reconnecting-websocket';

// ── JSON-RPC 2.0 types ─────────────────────────────────────────────

interface JsonRpcRequest {
  jsonrpc: '2.0';
  id: number;
  method: string;
  params?: unknown;
}

interface JsonRpcResponse {
  jsonrpc: '2.0';
  id: number;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

interface JsonRpcNotification {
  jsonrpc: '2.0';
  method: string;
  params?: unknown;
}

type JsonRpcMessage = JsonRpcResponse | JsonRpcNotification;

// ── Connection state ────────────────────────────────────────────────

export type ConnectionStatus = 'disconnected' | 'connecting' | 'connected' | 'error';

type ConnectionChangeCallback = (status: ConnectionStatus) => void;
type NotificationCallback = (params: unknown) => void;

// ── Pending request tracker ─────────────────────────────────────────

interface PendingRequest {
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

// ── Constants ───────────────────────────────────────────────────────

const HEARTBEAT_INTERVAL = 30_000;
const REQUEST_TIMEOUT = 15_000;

// ── Singleton WebSocket service ─────────────────────────────────────

class WebSocketService {
  private ws: ReconnectingWebSocket | null = null;
  private nextId = 1;
  private pending = new Map<number, PendingRequest>();
  private notificationListeners = new Map<string, Set<NotificationCallback>>();
  private connectionListeners = new Set<ConnectionChangeCallback>();
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private status: ConnectionStatus = 'disconnected';

  // ── Connection lifecycle ────────────────────────────────────────

  connect(url: string): void {
    if (this.ws) {
      this.disconnect();
    }

    this.setStatus('connecting');

    this.ws = new ReconnectingWebSocket(url);

    this.ws.addEventListener('open', () => {
      this.setStatus('connected');
      this.startHeartbeat();
    });

    this.ws.addEventListener('close', () => {
      this.setStatus('disconnected');
      this.stopHeartbeat();
    });

    this.ws.addEventListener('error', () => {
      this.setStatus('error');
    });

    this.ws.addEventListener('message', (event) => {
      this.handleMessage(event.data as string);
    });
  }

  disconnect(): void {
    this.stopHeartbeat();
    this.rejectAllPending('Connection closed');

    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }

    this.setStatus('disconnected');
  }

  isConnected(): boolean {
    return this.status === 'connected';
  }

  // ── JSON-RPC requests ───────────────────────────────────────────

  sendRequest(method: string, params?: unknown): Promise<unknown> {
    return new Promise((resolve, reject) => {
      if (!this.ws || this.status !== 'connected') {
        reject(new Error('WebSocket not connected'));
        return;
      }

      const id = this.nextId++;
      const request: JsonRpcRequest = {
        jsonrpc: '2.0',
        id,
        method,
        ...(params !== undefined && { params }),
      };

      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Request ${method} timed out`));
      }, REQUEST_TIMEOUT);

      this.pending.set(id, { resolve, reject, timer });
      this.ws.send(JSON.stringify(request));
    });
  }

  // ── Notification subscription ───────────────────────────────────

  onNotification(method: string, callback: NotificationCallback): () => void {
    let listeners = this.notificationListeners.get(method);
    if (!listeners) {
      listeners = new Set();
      this.notificationListeners.set(method, listeners);
    }
    listeners.add(callback);

    // Return unsubscribe function
    return () => {
      listeners!.delete(callback);
      if (listeners!.size === 0) {
        this.notificationListeners.delete(method);
      }
    };
  }

  // ── Connection state subscription ───────────────────────────────

  onConnectionChange(callback: ConnectionChangeCallback): () => void {
    this.connectionListeners.add(callback);
    // Emit current status immediately
    callback(this.status);
    return () => {
      this.connectionListeners.delete(callback);
    };
  }

  // ── Internal ────────────────────────────────────────────────────

  private handleMessage(data: string): void {
    let msg: JsonRpcMessage;
    try {
      msg = JSON.parse(data) as JsonRpcMessage;
    } catch {
      return; // Ignore malformed messages
    }

    if ('id' in msg && msg.id != null) {
      // Response to a request
      const pending = this.pending.get(msg.id);
      if (!pending) return;

      clearTimeout(pending.timer);
      this.pending.delete(msg.id);

      const resp = msg as JsonRpcResponse;
      if (resp.error) {
        pending.reject(new Error(resp.error.message));
      } else {
        pending.resolve(resp.result);
      }
    } else if ('method' in msg) {
      // Server-push notification
      const notification = msg as JsonRpcNotification;
      const listeners = this.notificationListeners.get(notification.method);
      if (listeners) {
        for (const cb of listeners) {
          try {
            cb(notification.params);
          } catch {
            // Don't let listener errors break the loop
          }
        }
      }
    }
  }

  private setStatus(status: ConnectionStatus): void {
    if (this.status === status) return;
    this.status = status;
    for (const cb of this.connectionListeners) {
      try {
        cb(status);
      } catch {
        // Ignore listener errors
      }
    }
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (this.ws && this.status === 'connected') {
        // Use JSON-RPC ping notification (no id = no response expected)
        this.ws.send(JSON.stringify({ jsonrpc: '2.0', method: 'ping' }));
      }
    }, HEARTBEAT_INTERVAL);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  private rejectAllPending(reason: string): void {
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(new Error(reason));
    }
    this.pending.clear();
  }
}

// Export singleton
export const websocketService = new WebSocketService();
