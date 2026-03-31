import { configureStore, createSlice } from '@reduxjs/toolkit';

// Placeholder slices — will be expanded
const sessionsSlice = createSlice({
  name: 'sessions',
  initialState: {} as Record<string, any>,
  reducers: {},
});

const agentsSlice = createSlice({
  name: 'agents',
  initialState: {} as Record<string, any>,
  reducers: {},
});

const tasksSlice = createSlice({
  name: 'tasks',
  initialState: { queue: [] as any[], active: {} as Record<string, any> },
  reducers: {},
});

const messagesSlice = createSlice({
  name: 'messages',
  initialState: {} as Record<string, any[]>,  // agentId -> messages
  reducers: {},
});

export const store = configureStore({
  reducer: {
    sessions: sessionsSlice.reducer,
    agents: agentsSlice.reducer,
    tasks: tasksSlice.reducer,
    messages: messagesSlice.reducer,
  },
});

export type RootState = ReturnType<typeof store.getState>;
export type AppDispatch = typeof store.dispatch;
