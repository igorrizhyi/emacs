import { createSlice, PayloadAction } from '@reduxjs/toolkit';
import type { RootState } from '../index';

// ── Stream entry types ──────────────────────────────────────────────

export interface MessageEntry {
  type: 'message';
  text: string;
}

export interface ThoughtEntry {
  type: 'thought';
  text: string;
}

export interface ToolCallEntry {
  type: 'toolCall';
  toolCallId: string;
  title: string;
  status: string;
  kind: string;
  rawInput: unknown;
  content?: unknown;
}

export type StreamEntry = MessageEntry | ThoughtEntry | ToolCallEntry;

export interface PermissionRequest {
  toolCallId: string;
  title: string;
  description: string;
}

export interface PlanEntry {
  status: string;
  content: string;
}

export interface AgentStream {
  messages: StreamEntry[];
  pendingPermission: PermissionRequest | null;
  plan: PlanEntry[] | null;
}

// ── State ───────────────────────────────────────────────────────────

type MessagesState = Record<string, AgentStream>;

const initialState: MessagesState = {};

function ensureStream(state: MessagesState, agentId: string): AgentStream {
  if (!state[agentId]) {
    state[agentId] = { messages: [], pendingPermission: null, plan: null };
  }
  return state[agentId];
}

// ── Slice ───────────────────────────────────────────────────────────

const messagesSlice = createSlice({
  name: 'messages',
  initialState,
  reducers: {
    appendMessageChunk(
      state,
      action: PayloadAction<{ agentId: string; text: string }>,
    ) {
      const { agentId, text } = action.payload;
      const stream = ensureStream(state, agentId);
      const last = stream.messages[stream.messages.length - 1];
      if (last && last.type === 'message') {
        last.text += text;
      } else {
        stream.messages.push({ type: 'message', text });
      }
    },

    appendThoughtChunk(
      state,
      action: PayloadAction<{ agentId: string; text: string }>,
    ) {
      const { agentId, text } = action.payload;
      const stream = ensureStream(state, agentId);
      const last = stream.messages[stream.messages.length - 1];
      if (last && last.type === 'thought') {
        last.text += text;
      } else {
        stream.messages.push({ type: 'thought', text });
      }
    },

    addToolCall(
      state,
      action: PayloadAction<{
        agentId: string;
        toolCall: {
          toolCallId: string;
          title: string;
          status: string;
          kind: string;
          rawInput: unknown;
        };
      }>,
    ) {
      const { agentId, toolCall } = action.payload;
      const stream = ensureStream(state, agentId);
      stream.messages.push({ type: 'toolCall', ...toolCall });
    },

    updateToolCall(
      state,
      action: PayloadAction<{
        agentId: string;
        toolCallId: string;
        update: { status?: string; content?: unknown; title?: string };
      }>,
    ) {
      const { agentId, toolCallId, update } = action.payload;
      const stream = state[agentId];
      if (!stream) return;

      const entry = stream.messages.find(
        (e): e is ToolCallEntry =>
          e.type === 'toolCall' && e.toolCallId === toolCallId,
      );
      if (entry) {
        if (update.status != null) entry.status = update.status;
        if (update.content !== undefined) entry.content = update.content;
        if (update.title != null) entry.title = update.title;
      }
    },

    setPlan(
      state,
      action: PayloadAction<{ agentId: string; entries: PlanEntry[] }>,
    ) {
      const stream = ensureStream(state, action.payload.agentId);
      stream.plan = action.payload.entries;
    },

    addPermissionRequest(
      state,
      action: PayloadAction<{
        agentId: string;
        request: PermissionRequest;
      }>,
    ) {
      const stream = ensureStream(state, action.payload.agentId);
      stream.pendingPermission = action.payload.request;
    },

    resolvePermission(state, action: PayloadAction<{ agentId: string }>) {
      const stream = state[action.payload.agentId];
      if (stream) {
        stream.pendingPermission = null;
      }
    },

    clearStream(state, action: PayloadAction<{ agentId: string }>) {
      delete state[action.payload.agentId];
    },
  },
});

// ── Selectors ───────────────────────────────────────────────────────

const emptyStream: AgentStream = {
  messages: [],
  pendingPermission: null,
  plan: null,
};

export const selectAgentStream = (state: RootState, agentId: string): AgentStream =>
  state.messages[agentId] ?? emptyStream;

export const selectAgentMessages = (state: RootState, agentId: string): StreamEntry[] =>
  state.messages[agentId]?.messages ?? [];

export const selectAgentPlan = (state: RootState, agentId: string): PlanEntry[] | null =>
  state.messages[agentId]?.plan ?? null;

export const selectAgentPermission = (state: RootState, agentId: string): PermissionRequest | null =>
  state.messages[agentId]?.pendingPermission ?? null;

// ── Exports ─────────────────────────────────────────────────────────

export const {
  appendMessageChunk,
  appendThoughtChunk,
  addToolCall,
  updateToolCall,
  setPlan,
  addPermissionRequest,
  resolvePermission,
  clearStream,
} = messagesSlice.actions;

export default messagesSlice.reducer;
