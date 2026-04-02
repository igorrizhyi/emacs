import { createSlice, PayloadAction } from '@reduxjs/toolkit';
import type { ChatBlock } from '../types';

// ── State ──────────────────────────────────────────────────────────────

type MessagesState = Record<string, ChatBlock[]>;

const initialState: MessagesState = {};

// ── Slice ──────────────────────────────────────────────────────────────

const messagesSlice = createSlice({
  name: 'messages',
  initialState,
  reducers: {
    addMessage(
      state,
      action: PayloadAction<{ agentId: string; block: ChatBlock }>,
    ) {
      const { agentId, block } = action.payload;
      if (!state[agentId]) {
        state[agentId] = [];
      }
      state[agentId].push(block);
    },
    appendChunk(
      state,
      action: PayloadAction<{ agentId: string; blockId: string; content: string }>,
    ) {
      const { agentId, blockId, content } = action.payload;
      const blocks = state[agentId];
      if (!blocks) return;

      const block = blocks.find((b) => b.id === blockId);
      if (block) {
        block.content += content;
      }
    },
    clearMessages(state, action: PayloadAction<string>) {
      delete state[action.payload];
    },
  },
});

export const { addMessage, appendChunk, clearMessages } = messagesSlice.actions;
export default messagesSlice.reducer;
