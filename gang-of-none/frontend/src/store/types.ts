/**
 * Shared domain types for the Redux store.
 * Mirrors the backend Pydantic models (gang-of-none/backend/src/api/schemas.py).
 */

// ── Enums ──────────────────────────────────────────────────────────────

export type AgentRole = 'lead' | 'dev' | 'tester' | 'researcher';
export type AgentStatus = 'idle' | 'busy' | 'initializing' | 'dead';
export type TaskStatus = 'pending' | 'assigned' | 'finished' | 'updated' | 'blocked';
export type TaskPriority = 'normal' | 'interrupt';
export type ApprovalType = 'checklist' | 'choice';

// ── Sessions ───────────────────────────────────────────────────────────

export interface Session {
  id: string;
  projectRoot: string;
  createdAt: string;
  agentCount: number;
  agentIds: string[];
}

// ── Agents ─────────────────────────────────────────────────────────────

export interface Agent {
  id: string;
  role: AgentRole;
  status: AgentStatus;
  sessionId: string;
  worktreeName: string | null;
  worktreePath: string | null;
  bufferName: string | null;
  ephemeral: boolean;
  reserved: boolean;
  initFinished: boolean;
  currentTaskId: string | null;
  createdAt: string;
  pid: number | null;
}

// ── Tasks ──────────────────────────────────────────────────────────────

export interface Task {
  id: string;
  requestId: string;
  role: AgentRole;
  message: string;
  groupId: string | null;
  target: string | null;
  priority: TaskPriority;
  model: string | null;
  sessionId: string;
  reportPath: string | null;
  status: TaskStatus;
  createdAt: string;
  assignedAt: string | null;
  completedAt: string | null;
}

export interface TaskGroup {
  groupId: string;
  sessionId: string;
  pending: string[];
  completed: string[];
}

// ── Messages ───────────────────────────────────────────────────────────
// Re-export ChatBlock from the component — canonical message type.

export type { ChatBlock, BlockType } from '../components/chat/MessageList';

// ── Approvals ──────────────────────────────────────────────────────────

export interface ApprovalItem {
  id: string;
  label: string;
  description?: string;
  defaultSelected: boolean;
  selected: boolean;
}

export interface ApprovalRequest {
  requestId: string;
  title: string;
  type: ApprovalType;
  description?: string;
  items: ApprovalItem[];
  notes?: string;
  refine?: string;
  timestamp: number;
}
