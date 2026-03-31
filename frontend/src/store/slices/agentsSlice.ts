import { createSlice, PayloadAction } from '@reduxjs/toolkit';

export interface Agent {
  id: string;
  role: string;
  status: 'idle' | 'busy' | 'offline' | 'error';
  worktreeName: string;
  sessionId: string;
  currentTaskId: string | null;
  reserved: boolean;
  ephemeral: boolean;
}

type AgentsState = Record<string, Agent>;

const initialState: AgentsState = {};

const agentsSlice = createSlice({
  name: 'agents',
  initialState,
  reducers: {
    addAgent(state, action: PayloadAction<Agent>) {
      state[action.payload.id] = action.payload;
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
});

export const { addAgent, removeAgent, updateAgentStatus, setCurrentTask } =
  agentsSlice.actions;
export default agentsSlice.reducer;
