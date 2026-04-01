import { createSlice, PayloadAction } from '@reduxjs/toolkit';

export interface Task {
  id: string;
  role: string;
  message: string;
  status: 'pending' | 'in_progress' | 'finished' | 'blocked';
  groupId?: string;
  assignedAgentId?: string;
}

export interface TaskGroup {
  groupId: string;
  pending: string[];
  completed: string[];
}

interface TasksState {
  queue: Task[];
  groups: Record<string, TaskGroup>;
}

const initialState: TasksState = {
  queue: [],
  groups: {},
};

const tasksSlice = createSlice({
  name: 'tasks',
  initialState,
  reducers: {
    addTask(state, action: PayloadAction<Task>) {
      state.queue.push(action.payload);
    },
    updateTaskStatus(
      state,
      action: PayloadAction<{ id: string; status: Task['status'] }>,
    ) {
      const task = state.queue.find((t) => t.id === action.payload.id);
      if (task) {
        task.status = action.payload.status;
      }
    },
    removeTask(state, action: PayloadAction<string>) {
      state.queue = state.queue.filter((t) => t.id !== action.payload);
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
});

export const { addTask, updateTaskStatus, removeTask, addGroup, updateGroupProgress } =
  tasksSlice.actions;
export default tasksSlice.reducer;
