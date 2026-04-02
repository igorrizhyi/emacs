import { createAsyncThunk, createSlice, PayloadAction } from '@reduxjs/toolkit';
import type { Task, TaskGroup } from '../types';
import { getTasks as apiFetchTasks } from '@/services/api';

// ── State ──────────────────────────────────────────────────────────────

interface TasksState {
  byId: Record<string, Task>;
  groups: Record<string, TaskGroup>;
  loading: boolean;
}

const initialState: TasksState = {
  byId: {},
  groups: {},
  loading: false,
};

// ── Async thunks ───────────────────────────────────────────────────────

export const fetchTasks = createAsyncThunk(
  'tasks/fetchAll',
  async (sessionId: string) => {
    const res = await apiFetchTasks(sessionId);
    return res.tasks;
  },
);

// ── Slice ──────────────────────────────────────────────────────────────

const tasksSlice = createSlice({
  name: 'tasks',
  initialState,
  reducers: {
    setTasks(state, action: PayloadAction<Task[]>) {
      state.byId = {};
      for (const t of action.payload) {
        state.byId[t.id] = t;
      }
    },
    addTask(state, action: PayloadAction<Task>) {
      state.byId[action.payload.id] = action.payload;
    },
    updateTask(
      state,
      action: PayloadAction<{ id: string } & Partial<Omit<Task, 'id'>>>,
    ) {
      const task = state.byId[action.payload.id];
      if (task) {
        Object.assign(task, action.payload);
      }
    },
    updateTaskStatus(
      state,
      action: PayloadAction<{ id: string; status: Task['status'] }>,
    ) {
      const task = state.byId[action.payload.id];
      if (task) {
        task.status = action.payload.status;
      }
    },
    removeTask(state, action: PayloadAction<string>) {
      delete state.byId[action.payload];
    },
    addGroup(state, action: PayloadAction<TaskGroup>) {
      state.groups[action.payload.groupId] = action.payload;
    },
    updateGroupProgress(
      state,
      action: PayloadAction<{
        groupId: string;
        completedTaskId?: string;
        pending?: string[];
        completed?: string[];
      }>,
    ) {
      const group = state.groups[action.payload.groupId];
      if (!group) return;

      if (action.payload.completedTaskId) {
        group.pending = group.pending.filter(
          (id) => id !== action.payload.completedTaskId,
        );
        if (!group.completed.includes(action.payload.completedTaskId)) {
          group.completed.push(action.payload.completedTaskId);
        }
      }
      if (action.payload.pending) {
        group.pending = action.payload.pending;
      }
      if (action.payload.completed) {
        group.completed = action.payload.completed;
      }
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(fetchTasks.pending, (state) => {
        state.loading = true;
      })
      .addCase(fetchTasks.fulfilled, (state, action) => {
        state.loading = false;
        state.byId = {};
        for (const t of action.payload) {
          state.byId[t.id] = t;
        }
      })
      .addCase(fetchTasks.rejected, (state) => {
        state.loading = false;
      });
  },
});

export const {
  setTasks,
  addTask,
  updateTask,
  updateTaskStatus,
  removeTask,
  addGroup,
  updateGroupProgress,
} = tasksSlice.actions;
export default tasksSlice.reducer;
