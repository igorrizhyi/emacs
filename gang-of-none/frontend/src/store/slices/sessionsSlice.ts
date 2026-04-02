import { createAsyncThunk, createSlice, PayloadAction } from '@reduxjs/toolkit';
import type { Session } from '../types';
import { getSessions as apiFetchSessions } from '@/services/api';

// ── State ──────────────────────────────────────────────────────────────

interface SessionsState {
  byId: Record<string, Session>;
  activeSessionId: string | null;
  loading: boolean;
  error: string | null;
}

const initialState: SessionsState = {
  byId: {},
  activeSessionId: null,
  loading: false,
  error: null,
};

// ── Async thunks ───────────────────────────────────────────────────────

export const fetchSessions = createAsyncThunk(
  'sessions/fetchAll',
  async () => {
    const res = await apiFetchSessions();
    return res.sessions;
  },
);

// ── Slice ──────────────────────────────────────────────────────────────

const sessionsSlice = createSlice({
  name: 'sessions',
  initialState,
  reducers: {
    setSessions(state, action: PayloadAction<Session[]>) {
      state.byId = {};
      for (const s of action.payload) {
        state.byId[s.id] = s;
      }
    },
    addSession(state, action: PayloadAction<Session>) {
      state.byId[action.payload.id] = action.payload;
    },
    removeSession(state, action: PayloadAction<string>) {
      delete state.byId[action.payload];
      if (state.activeSessionId === action.payload) {
        state.activeSessionId = null;
      }
    },
    setActiveSession(state, action: PayloadAction<string | null>) {
      state.activeSessionId = action.payload;
    },
    updateSession(
      state,
      action: PayloadAction<{ id: string } & Partial<Omit<Session, 'id'>>>,
    ) {
      const session = state.byId[action.payload.id];
      if (session) {
        Object.assign(session, action.payload);
      }
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(fetchSessions.pending, (state) => {
        state.loading = true;
        state.error = null;
      })
      .addCase(fetchSessions.fulfilled, (state, action) => {
        state.loading = false;
        state.byId = {};
        for (const s of action.payload) {
          state.byId[s.id] = s;
        }
      })
      .addCase(fetchSessions.rejected, (state, action) => {
        state.loading = false;
        state.error = action.error.message ?? 'Failed to fetch sessions';
      });
  },
});

export const { setSessions, addSession, removeSession, setActiveSession, updateSession } =
  sessionsSlice.actions;
export default sessionsSlice.reducer;
