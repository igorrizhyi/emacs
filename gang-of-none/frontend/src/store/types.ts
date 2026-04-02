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

// ── Request / Response types (API boundary) ───────────────────────────

export interface SessionCreateRequest {
  projectRoot: string;
}

export interface TaskCreate {
  role: AgentRole;
  message: string;
  priority?: TaskPriority;
  groupId?: string;
  target?: string;
  model?: string;
}

export interface TaskUpdate {
  requestId: string;
  status: TaskStatus;
  content: string;
  commit?: string;
  reportPath?: string;
}

export interface ApprovalSubmitRequest {
  selectedItems: string[];
  refine?: boolean;
  notes?: string;
}

// ── Namespace / Peers ─────────────────────────────────────────────────

export interface Peer {
  pid: number;
  hostname: string;
  projectRoot: string;
  namespace: string;
  connectedAt: string;
}

export interface PeerMessageRequest {
  message: string;
}

// ── Reports ───────────────────────────────────────────────────────────

export interface Report {
  requestId: string;
  content: string;
}

// ── Generic ───────────────────────────────────────────────────────────

export interface SuccessResponse {
  success: boolean;
  message: string;
}

// ── List wrappers ─────────────────────────────────────────────────────

export interface SessionListResponse {
  sessions: Session[];
}

export interface AgentListResponse {
  agents: Agent[];
}

export interface TaskListResponse {
  tasks: Task[];
}

export interface ApprovalListResponse {
  approvals: ApprovalRequest[];
}

export interface PeerListResponse {
  peers: Peer[];
}

// ── WebSocket RPC param types ─────────────────────────────────────────

export interface DismissAgentParams {
  target: string;
  force?: boolean;
}

export interface SendNotificationParams {
  title: string;
  message: string;
}

export interface PresentOptionsParams {
  requestId: string;
  title: string;
  type: ApprovalType;
  items: ApprovalItem[];
  description?: string;
}

export interface MessagePeerParams {
  targetPid: number;
  message: string;
}
