import { createAsyncThunk, createSlice, PayloadAction } from '@reduxjs/toolkit';
import type { Agent } from '../types';
import { fetchAgents as apiFetchAgents } from '@/services/api';

// ── State ──────────────────────────────────────────────────────────────

type AgentsState = Record<string, Agent>;

const initialState: AgentsState = {};

// ── Async thunks ───────────────────────────────────────────────────────

export const fetchAgents = createAsyncThunk(
  'agents/fetchAll',
  async (sessionId: string) => apiFetchAgents(sessionId),
);

// ── Slice ──────────────────────────────────────────────────────────────

const agentsSlice = createSlice({
  name: 'agents',
  initialState,
  reducers: {
    setAgents(state, action: PayloadAction<Agent[]>) {
      const keys = Object.keys(state);
      for (const k of keys) delete state[k];
      for (const a of action.payload) {
        state[a.id] = a;
      }
    },
    updateAgent(
      state,
      action: PayloadAction<{ id: string } & Partial<Omit<Agent, 'id'>>>,
    ) {
      const agent = state[action.payload.id];
      if (agent) {
        Object.assign(agent, action.payload);
      }
    },
    removeAgent(state, action: PayloadAction<string>) {
      delete state[action.payload];
    },
    updateAgentStatus(
      state,
      action: PayloadAction<{ id: string; status: Agent['status'] }>,
    ) {
      const agent = state[action.payload.id];
      if (agent) {
        agent.status = action.payload.status;
      }
    },
    setCurrentTask(
      state,
      action: PayloadAction<{ id: string; taskId: string | null }>,
    ) {
      const agent = state[action.payload.id];
      if (agent) {
        agent.currentTaskId = action.payload.taskId;
      }
    },
  },
  extraReducers: (builder) => {
    builder.addCase(fetchAgents.fulfilled, (state, action) => {
      const keys = Object.keys(state);
      for (const k of keys) delete state[k];
      for (const a of action.payload) {
        state[a.id] = a;
      }
    });
  },
});

export const { setAgents, updateAgent, removeAgent, updateAgentStatus, setCurrentTask } =
  agentsSlice.actions;
export default agentsSlice.reducer;
