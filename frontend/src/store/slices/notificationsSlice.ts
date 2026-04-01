import { createSlice, PayloadAction } from '@reduxjs/toolkit';

// ── Types ────────────────────────────────────────────────────────────

export type NotificationType =
  | 'task_update'
  | 'approval_request'
  | 'agent_status'
  | 'system';

export interface AppNotification {
  id: string;
  title: string;
  message: string;
  type: NotificationType;
  timestamp: number;
  read: boolean;
  data?: Record<string, unknown>;
}

interface NotificationsState {
  notifications: AppNotification[];
  unreadCount: number;
}

// ── Initial state ────────────────────────────────────────────────────

const initialState: NotificationsState = {
  notifications: [],
  unreadCount: 0,
};

// ── Slice ────────────────────────────────────────────────────────────

const notificationsSlice = createSlice({
  name: 'notifications',
  initialState,
  reducers: {
    addNotification(state, action: PayloadAction<AppNotification>) {
      state.notifications.unshift(action.payload);
      if (!action.payload.read) {
        state.unreadCount += 1;
      }
    },

    markRead(state, action: PayloadAction<string>) {
      const notification = state.notifications.find(
        (n) => n.id === action.payload,
      );
      if (notification && !notification.read) {
        notification.read = true;
        state.unreadCount = Math.max(0, state.unreadCount - 1);
      }
    },

    markAllRead(state) {
      for (const n of state.notifications) {
        n.read = true;
      }
      state.unreadCount = 0;
    },

    clearAll(state) {
      state.notifications = [];
      state.unreadCount = 0;
    },
  },
});

// ── Exports ──────────────────────────────────────────────────────────

export const { addNotification, markRead, markAllRead, clearAll } =
  notificationsSlice.actions;

export default notificationsSlice.reducer;

// ── Selectors ────────────────────────────────────────────────────────

interface RootStateWithNotifications {
  notifications: NotificationsState;
}

export const selectNotifications = (state: RootStateWithNotifications) =>
  state.notifications.notifications;

export const selectUnreadCount = (state: RootStateWithNotifications) =>
  state.notifications.unreadCount;
