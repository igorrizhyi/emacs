import { createAsyncThunk, createSlice, PayloadAction } from '@reduxjs/toolkit';
import type { ApprovalRequest } from '../types';
import type { RootState } from '../index';
import { getApprovals as apiFetchApprovals } from '@/services/api';

// ── State ──────────────────────────────────────────────────────────────

interface ApprovalState {
  byId: Record<string, ApprovalRequest>;
  activeRequestId: string | null;
}

const initialState: ApprovalState = {
  byId: {},
  activeRequestId: null,
};

// ── Async thunks ───────────────────────────────────────────────────────

export const fetchApprovals = createAsyncThunk(
  'approval/fetchAll',
  async () => {
    const res = await apiFetchApprovals();
    return res.approvals;
  },
);

// ── Slice ──────────────────────────────────────────────────────────────

const approvalSlice = createSlice({
  name: 'approval',
  initialState,
  reducers: {
    setApprovals(state, action: PayloadAction<ApprovalRequest[]>) {
      state.byId = {};
      for (const a of action.payload) {
        state.byId[a.requestId] = a;
      }
    },
    addApproval(state, action: PayloadAction<ApprovalRequest>) {
      state.byId[action.payload.requestId] = action.payload;
      if (!state.activeRequestId) {
        state.activeRequestId = action.payload.requestId;
      }
    },
    removeApproval(state, action: PayloadAction<string>) {
      delete state.byId[action.payload];
      if (state.activeRequestId === action.payload) {
        const ids = Object.keys(state.byId);
        state.activeRequestId = ids[0] ?? null;
      }
    },
    updateApproval(
      state,
      action: PayloadAction<{ requestId: string } & Partial<Omit<ApprovalRequest, 'requestId'>>>,
    ) {
      const approval = state.byId[action.payload.requestId];
      if (approval) {
        Object.assign(approval, action.payload);
      }
    },
    setActiveRequest(state, action: PayloadAction<string | null>) {
      state.activeRequestId = action.payload;
    },
    toggleItem(
      state,
      action: PayloadAction<{ requestId: string; itemId: string }>,
    ) {
      const request = state.byId[action.payload.requestId];
      if (!request) return;

      if (request.type === 'checklist') {
        const item = request.items.find((i) => i.id === action.payload.itemId);
        if (item) {
          item.selected = !item.selected;
        }
      } else {
        for (const item of request.items) {
          item.selected = item.id === action.payload.itemId;
        }
      }
    },
    updateNotes(
      state,
      action: PayloadAction<{ requestId: string; notes: string }>,
    ) {
      const request = state.byId[action.payload.requestId];
      if (request) {
        request.notes = action.payload.notes;
      }
    },
    updateRefine(
      state,
      action: PayloadAction<{ requestId: string; refine: string }>,
    ) {
      const request = state.byId[action.payload.requestId];
      if (request) {
        request.refine = action.payload.refine;
      }
    },
  },
  extraReducers: (builder) => {
    builder.addCase(fetchApprovals.fulfilled, (state, action) => {
      state.byId = {};
      for (const a of action.payload) {
        state.byId[a.requestId] = a;
      }
    });
  },
});

// ── Actions ──────────────────────────────────────────────────────────

export const {
  setApprovals,
  addApproval,
  removeApproval,
  updateApproval,
  setActiveRequest,
  toggleItem,
  updateNotes,
  updateRefine,
} = approvalSlice.actions;

// ── Selectors ────────────────────────────────────────────────────────

export const selectActiveRequest = (state: RootState) => {
  const { activeRequestId, byId } = state.approval;
  if (!activeRequestId) return undefined;
  return byId[activeRequestId];
};

export const selectPendingCount = (state: RootState) =>
  Object.keys(state.approval.byId).length;

// ── Export ────────────────────────────────────────────────────────────

export default approvalSlice.reducer;
