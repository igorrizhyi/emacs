import type { Middleware } from '@reduxjs/toolkit';
import { notificationService } from '../../services/notificationService';
import type { AppNotification } from '../slices/notificationsSlice';

// ── Middleware ────────────────────────────────────────────────────────

/**
 * Notification middleware — watches for addNotification dispatches and
 * triggers a local push when the app is in the background.
 *
 * The actual WS→Redux dispatching is handled by websocketMiddleware;
 * this middleware only does the push-notification side effect.
 */
export const notificationMiddleware: Middleware = () => {
  return (next) => (action: unknown) => {
    const result = next(action);

    const act = action as { type: string; payload?: unknown };
    if (act.type === 'notifications/addNotification') {
      const notif = act.payload as AppNotification;
      maybeLocalPush(notif);
    }

    return result;
  };
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
