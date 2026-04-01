import { configureStore } from '@reduxjs/toolkit';
import {
  sessionsReducer,
  agentsReducer,
  tasksReducer,
  messagesReducer,
  connectionReducer,
  approvalReducer,
} from './slices';
import { websocketMiddleware } from './middleware/websocketMiddleware';

export const store = configureStore({
  reducer: {
    sessions: sessionsReducer,
    agents: agentsReducer,
    tasks: tasksReducer,
    messages: messagesReducer,
    connection: connectionReducer,
    approval: approvalReducer,
  },
  middleware: (getDefaultMiddleware) =>
    getDefaultMiddleware().concat(websocketMiddleware),
});

export type RootState = ReturnType<typeof store.getState>;
export type AppDispatch = typeof store.dispatch;
