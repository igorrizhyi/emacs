import type { Middleware } from '@reduxjs/toolkit';
import { websocketService } from '../../services/websocket';
import { setConnectionStatus, setUrl } from '../slices/connectionSlice';
import { updateTaskStatus } from '../slices/tasksSlice';
import { updateGroupProgress } from '../slices/tasksSlice';
import { updateAgentStatus } from '../slices/agentsSlice';

// ── Action types the middleware listens for ─────────────────────────

export const WS_CONNECT = 'ws/connect' as const;
export const WS_DISCONNECT = 'ws/disconnect' as const;

export interface WsConnectAction {
  type: typeof WS_CONNECT;
  payload: { url: string };
}

export interface WsDisconnectAction {
  type: typeof WS_DISCONNECT;
}

// Action creators
export const wsConnect = (url: string): WsConnectAction => ({
  type: WS_CONNECT,
  payload: { url },
});

export const wsDisconnect = (): WsDisconnectAction => ({
  type: WS_DISCONNECT,
});

// ── Notification payload shapes ─────────────────────────────────────

interface TaskStatusPayload {
  id: string;
  status: 'pending' | 'in_progress' | 'finished' | 'blocked';
}

interface GroupCompletePayload {
  groupId: string;
  completedTaskId?: string;
  pending?: string[];
  completed?: string[];
}

interface AgentStatusPayload {
  id: string;
  status: 'idle' | 'busy' | 'offline' | 'error';
}

interface ApprovalRequestPayload {
  id: string;
  [key: string]: unknown;
}

// ── Middleware ───────────────────────────────────────────────────────

const unsubscribers: Array<() => void> = [];

function teardown() {
  for (const unsub of unsubscribers) {
    unsub();
  }
  unsubscribers.length = 0;
}

export const websocketMiddleware: Middleware = (storeApi) => {
  return (next) => (action: unknown) => {
    const act = action as { type: string; payload?: unknown };

    if (act.type === WS_CONNECT) {
      const { url } = (act as WsConnectAction).payload;

      // Tear down any prior connection
      teardown();
      websocketService.disconnect();

      storeApi.dispatch(setUrl(url));
      websocketService.connect(url);

      // Subscribe to connection state changes
      unsubscribers.push(
        websocketService.onConnectionChange((status) => {
          storeApi.dispatch(setConnectionStatus(status));
        }),
      );

      // Route server notifications → Redux actions
      unsubscribers.push(
        websocketService.onNotification('task/statusChanged', (params) => {
          const p = params as TaskStatusPayload;
          storeApi.dispatch(updateTaskStatus({ id: p.id, status: p.status }));
        }),
      );

      unsubscribers.push(
        websocketService.onNotification('task/groupComplete', (params) => {
          const p = params as GroupCompletePayload;
          storeApi.dispatch(updateGroupProgress(p));
        }),
      );

      unsubscribers.push(
        websocketService.onNotification('approval/request', (params) => {
          // Dispatch to Zustand approvalStore — import dynamically to avoid
          // circular deps between Redux middleware and Zustand store.
          // The uiStore exposes setApprovalVisible; a dedicated approval store
          // can be added later. For now, signal the UI.
          try {
            // eslint-disable-next-line @typescript-eslint/no-require-imports
            const { useUIStore } = require('../uiStore') as {
              useUIStore: { getState: () => { setApprovalVisible: (v: boolean) => void } };
            };
            useUIStore.getState().setApprovalVisible(true);
          } catch {
            // Approval store not available — silently ignore
          }
          void params; // consumed by approval store
        }),
      );

      unsubscribers.push(
        websocketService.onNotification('notification', (_params) => {
          // TODO: dispatch to a notifications queue slice when added
        }),
      );

      unsubscribers.push(
        websocketService.onNotification('agent/statusChanged', (params) => {
          const p = params as AgentStatusPayload;
          storeApi.dispatch(
            updateAgentStatus({ id: p.id, status: p.status }),
          );
        }),
      );
    }

    if (act.type === WS_DISCONNECT) {
      teardown();
      websocketService.disconnect();
      storeApi.dispatch(setUrl(null));
    }

    return next(action);
  };
};
