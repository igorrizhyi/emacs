import ReconnectingWebSocket from 'reconnecting-websocket';
import { JSONRPCClient } from 'json-rpc-2.0';

import type {
  DismissAgentParams,
  MessagePeerParams,
  Peer,
  PresentOptionsParams,
  SendNotificationParams,
  SuccessResponse,
  TaskCreate,
  TaskUpdate,
} from './types';

// ── Connection state ────────────────────────────────────────────────────

export type ConnectionStatus =
  | 'disconnected'
  | 'connecting'
  | 'connected'
  | 'error';

type StatusCallback = (status: ConnectionStatus) => void;
type NotificationCallback = (method: string, params: unknown) => void;

// ── Service ─────────────────────────────────────────────────────────────

class WsService {
  private ws: ReconnectingWebSocket | null = null;
  private rpc: JSONRPCClient | null = null;
  private status: ConnectionStatus = 'disconnected';
  private statusListeners = new Set<StatusCallback>();
  private notificationListeners = new Set<NotificationCallback>();

  // ── Connection lifecycle ────────────────────────────────────────────

  connect(host: string, sessionId: string): void {
    this.disconnect();
    this.setStatus('connecting');

    const url = `ws://${host}/ws/${sessionId}`;
    const ws = new ReconnectingWebSocket(url);
    this.ws = ws;

    // JSONRPCClient sends requests through the WebSocket
    this.rpc = new JSONRPCClient((request: unknown) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(request));
      } else {
        return Promise.reject(new Error('WebSocket not connected'));
      }
    });

    ws.addEventListener('open', () => this.setStatus('connected'));
    ws.addEventListener('close', () => this.setStatus('disconnected'));
    ws.addEventListener('error', () => this.setStatus('error'));

    ws.addEventListener('message', (event: MessageEvent) => {
      const data = JSON.parse(event.data as string) as Record<string, unknown>;

      if ('id' in data && data.id != null) {
        // Response to our request — feed it to the JSONRPCClient
        this.rpc?.receive(data);
      } else if ('method' in data) {
        // Server-pushed notification
        for (const cb of this.notificationListeners) {
          cb(data.method as string, data.params);
        }
      }
    });
  }

  disconnect(): void {
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    this.rpc = null;
    this.setStatus('disconnected');
  }

  // ── Typed RPC methods ───────────────────────────────────────────────

  tasksPut(tasks: TaskCreate[]): Promise<unknown> {
    return this.call('tasksPut', { tasks });
  }

  taskUpdate(params: TaskUpdate): Promise<unknown> {
    return this.call('taskUpdate', params);
  }

  dismissAgent(params: DismissAgentParams): Promise<unknown> {
    return this.call('dismissAgent', params);
  }

  sendNotification(params: SendNotificationParams): Promise<unknown> {
    return this.call('sendNotification', params);
  }

  presentOptions(params: PresentOptionsParams): Promise<unknown> {
    return this.call('presentOptions', params);
  }

  listPendingReviews(): Promise<string[]> {
    return this.call('listPendingReviews') as Promise<string[]>;
  }

  messageNamespacePeer(params: MessagePeerParams): Promise<SuccessResponse> {
    return this.call('messageNamespacePeer', params) as Promise<SuccessResponse>;
  }

  listNamespacePeers(): Promise<Peer[]> {
    return this.call('listNamespacePeers') as Promise<Peer[]>;
  }

  // ── Subscriptions ───────────────────────────────────────────────────

  onNotification(callback: NotificationCallback): () => void {
    this.notificationListeners.add(callback);
    return () => {
      this.notificationListeners.delete(callback);
    };
  }

  onStatusChange(callback: StatusCallback): () => void {
    this.statusListeners.add(callback);
    callback(this.status);
    return () => {
      this.statusListeners.delete(callback);
    };
  }

  getStatus(): ConnectionStatus {
    return this.status;
  }

  // ── Internal ────────────────────────────────────────────────────────

  private call(method: string, params?: unknown): Promise<unknown> {
    if (!this.rpc) {
      return Promise.reject(new Error('WebSocket not connected'));
    }
    return this.rpc.request(method, params);
  }

  private setStatus(next: ConnectionStatus): void {
    if (this.status === next) return;
    this.status = next;
    for (const cb of this.statusListeners) {
      cb(next);
    }
  }
}

export const wsService = new WsService();
