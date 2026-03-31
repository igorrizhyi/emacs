import { createSlice, PayloadAction } from '@reduxjs/toolkit';

export interface Session {
  id: string;
  projectRoot: string;
  createdAt: string;
  agentIds: string[];
}

type SessionsState = Record<string, Session>;

const initialState: SessionsState = {};

const sessionsSlice = createSlice({
  name: 'sessions',
  initialState,
  reducers: {
    addSession(state, action: PayloadAction<Session>) {
      state[action.payload.id] = action.payload;
    },
    removeSession(state, action: PayloadAction<string>) {
      delete state[action.payload];
    },
    updateSession(state, action: PayloadAction<{ id: string } & Partial<Omit<Session, 'id'>>>) {
      const session = state[action.payload.id];
      if (session) {
        Object.assign(session, action.payload);
      }
    },
  },
});

export const { addSession, removeSession, updateSession } = sessionsSlice.actions;
export default sessionsSlice.reducer;
