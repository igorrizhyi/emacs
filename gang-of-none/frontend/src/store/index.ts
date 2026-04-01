import { configureStore } from '@reduxjs/toolkit';
import {
  sessionsReducer,
  agentsReducer,
  tasksReducer,
  messagesReducer,
  connectionReducer,
  approvalReducer,
  notificationsReducer,
} from './slices';
import { websocketMiddleware } from './middleware/websocketMiddleware';
import { notificationMiddleware } from './middleware/notificationMiddleware';

export const store = configureStore({
  reducer: {
    sessions: sessionsReducer,
    agents: agentsReducer,
    tasks: tasksReducer,
    messages: messagesReducer,
    connection: connectionReducer,
    approval: approvalReducer,
    notifications: notificationsReducer,
  },
  middleware: (getDefaultMiddleware) =>
    getDefaultMiddleware().concat(websocketMiddleware, notificationMiddleware),
});

export type RootState = ReturnType<typeof store.getState>;
export type AppDispatch = typeof store.dispatch;
