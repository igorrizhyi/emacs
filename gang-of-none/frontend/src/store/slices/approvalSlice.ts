import { createSlice, PayloadAction } from '@reduxjs/toolkit';
import type { RootState } from '../index';

// ── Types ────────────────────────────────────────────────────────────

export interface ApprovalItem {
  id: string;
  label: string;
  description?: string;
  selected: boolean;
  default_selected?: boolean;
}

export interface ApprovalRequest {
  id: string;
  title: string;
  type: 'checklist' | 'choice';
  items: ApprovalItem[];
  description?: string;
  notes?: string;
  refine?: string;
  timestamp: number;
}

interface ApprovalState {
  requests: ApprovalRequest[];
  activeRequestId: string | null;
}

// ── Initial state ────────────────────────────────────────────────────

const initialState: ApprovalState = {
  requests: [],
  activeRequestId: null,
};

// ── Slice ────────────────────────────────────────────────────────────

const approvalSlice = createSlice({
  name: 'approval',
  initialState,
  reducers: {
    addRequest(state, action: PayloadAction<ApprovalRequest>) {
      state.requests.unshift(action.payload);
      // Auto-select the new request if none is active
      if (!state.activeRequestId) {
        state.activeRequestId = action.payload.id;
      }
    },

    removeRequest(state, action: PayloadAction<string>) {
      state.requests = state.requests.filter((r) => r.id !== action.payload);
      if (state.activeRequestId === action.payload) {
        state.activeRequestId = state.requests[0]?.id ?? null;
      }
    },

    setActiveRequest(state, action: PayloadAction<string | null>) {
      state.activeRequestId = action.payload;
    },

    toggleItem(
      state,
      action: PayloadAction<{ requestId: string; itemId: string }>,
    ) {
      const request = state.requests.find(
        (r) => r.id === action.payload.requestId,
      );
      if (!request) return;

      if (request.type === 'checklist') {
        const item = request.items.find(
          (i) => i.id === action.payload.itemId,
        );
        if (item) {
          item.selected = !item.selected;
        }
      } else {
        // Choice: radio-select — deselect all, select target
        for (const item of request.items) {
          item.selected = item.id === action.payload.itemId;
        }
      }
    },

    updateNotes(
      state,
      action: PayloadAction<{ requestId: string; notes: string }>,
    ) {
      const request = state.requests.find(
        (r) => r.id === action.payload.requestId,
      );
      if (request) {
        request.notes = action.payload.notes;
      }
    },

    updateRefine(
      state,
      action: PayloadAction<{ requestId: string; refine: string }>,
    ) {
      const request = state.requests.find(
        (r) => r.id === action.payload.requestId,
      );
      if (request) {
        request.refine = action.payload.refine;
      }
    },
  },
});

// ── Actions ──────────────────────────────────────────────────────────

export const {
  addRequest,
  removeRequest,
  setActiveRequest,
  toggleItem,
  updateNotes,
  updateRefine,
} = approvalSlice.actions;

// ── Selectors ────────────────────────────────────────────────────────

export const selectActiveRequest = (state: RootState) => {
  const { activeRequestId, requests } = state.approval;
  if (!activeRequestId) return undefined;
  return requests.find((r) => r.id === activeRequestId);
};

export const selectPendingCount = (state: RootState) =>
  state.approval.requests.length;

// ── Export ────────────────────────────────────────────────────────────

export default approvalSlice.reducer;
