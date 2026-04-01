import type { Middleware } from '@reduxjs/toolkit';
import { websocketService } from '../../services/websocket';
import { notificationService } from '../../services/notificationService';
import {
  addNotification,
  type AppNotification,
  type NotificationType,
} from '../slices/notificationsSlice';

// ── WS payload shapes ────────────────────────────────────────────────

interface WsNotificationPayload {
  id?: string;
  title?: string;
  message?: string;
  type?: NotificationType;
  data?: Record<string, unknown>;
}

interface TaskUpdatePayload {
  id: string;
  status: string;
  agentId?: string;
  title?: string;
}

interface ApprovalNewPayload {
  id: string;
  title?: string;
  agentId?: string;
}

// ── Helpers ──────────────────────────────────────────────────────────

let counter = 0;

function makeId(): string {
  counter += 1;
  return `notif-${Date.now()}-${counter}`;
}

function buildNotification(
  type: NotificationType,
  title: string,
  message: string,
  data?: Record<string, unknown>,
): AppNotification {
  return {
    id: makeId(),
    title,
    message,
    type,
    timestamp: Date.now(),
    read: false,
    data,
  };
}

// ── Middleware ────────────────────────────────────────────────────────

const unsubscribers: Array<() => void> = [];

/**
 * Notification middleware — subscribes to WS events that produce
 * user-visible notifications (distinct from the data-sync events
 * handled by websocketMiddleware).
 *
 * Listens for: `notification`, `task.update`, `approval.new`
 */
export const notificationMiddleware: Middleware = (storeApi) => {
  // Subscribe once when the middleware is first created.
  // The websocketMiddleware handles connect/disconnect lifecycle;
  // we piggyback on the shared websocketService singleton.

  function subscribe() {
    // Tear down previous subscriptions (e.g. reconnect)
    for (const unsub of unsubscribers) unsub();
    unsubscribers.length = 0;

    // 1. Generic notification event
    unsubscribers.push(
      websocketService.onNotification('notification', (params) => {
        const p = params as WsNotificationPayload;
        const notif = buildNotification(
          p.type ?? 'system',
          p.title ?? 'Notification',
          p.message ?? '',
          p.data,
        );
        storeApi.dispatch(addNotification(notif));
        maybeLocalPush(notif);
      }),
    );

    // 2. Task status updates
    unsubscribers.push(
      websocketService.onNotification('task.update', (params) => {
        const p = params as TaskUpdatePayload;
        const notif = buildNotification(
          'task_update',
          p.title ?? `Task ${p.status}`,
          `Task ${p.id.slice(0, 8)} is now ${p.status}`,
          { taskId: p.id, agentId: p.agentId },
        );
        storeApi.dispatch(addNotification(notif));
        maybeLocalPush(notif);
      }),
    );

    // 3. New approval requests
    unsubscribers.push(
      websocketService.onNotification('approval.new', (params) => {
        const p = params as ApprovalNewPayload;
        const notif = buildNotification(
          'approval_request',
          'Approval Required',
          p.title ?? `New approval request ${p.id.slice(0, 8)}`,
          { approvalId: p.id, agentId: p.agentId },
        );
        storeApi.dispatch(addNotification(notif));
        maybeLocalPush(notif);
      }),
    );
  }

  // Subscribe when connection status changes to 'connected'
  unsubscribers.push(
    websocketService.onConnectionChange((status) => {
      if (status === 'connected') {
        subscribe();
      }
    }),
  );

  return (next) => (action) => next(action);
};

// ── Local push for background state ──────────────────────────────────

function maybeLocalPush(notif: AppNotification): void {
  if (notificationService.isAppInBackground()) {
    notificationService.showLocalNotification({
      title: notif.title,
      message: notif.message,
      data: notif.data,
    });
  }
}
