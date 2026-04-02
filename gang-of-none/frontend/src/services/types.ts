// ── Enums ──────────────────────────────────────────────────────────────

export enum AgentRole {
  LEAD = 'lead',
  DEV = 'dev',
  TESTER = 'tester',
  RESEARCHER = 'researcher',
}

export enum AgentStatus {
  IDLE = 'idle',
  BUSY = 'busy',
  INITIALIZING = 'initializing',
  DEAD = 'dead',
}

export enum TaskStatus {
  PENDING = 'pending',
  ASSIGNED = 'assigned',
  FINISHED = 'finished',
  UPDATED = 'updated',
  BLOCKED = 'blocked',
}

export enum TaskPriority {
  NORMAL = 'normal',
  INTERRUPT = 'interrupt',
}

export enum ApprovalType {
  CHECKLIST = 'checklist',
  CHOICE = 'choice',
}

// ── Agent ──────────────────────────────────────────────────────────────

export interface Agent {
  id: string;
  role: AgentRole;
  status: AgentStatus;
  session_id: string;
  worktree_name: string | null;
  worktree_path: string | null;
  buffer_name: string | null;
  ephemeral: boolean;
  reserved: boolean;
  init_finished: boolean;
  current_task_id: string | null;
  created_at: string;
  pid: number | null;
}

// ── Task ───────────────────────────────────────────────────────────────

export interface Task {
  id: string;
  request_id: string;
  role: AgentRole;
  message: string;
  group_id: string | null;
  target: string | null;
  priority: TaskPriority;
  model: string | null;
  session_id: string;
  report_path: string | null;
  status: TaskStatus;
  created_at: string;
  assigned_at: string | null;
  completed_at: string | null;
}

export interface TaskCreate {
  role: AgentRole;
  message: string;
  priority?: TaskPriority;
  group_id?: string;
  target?: string;
  model?: string;
}

export interface TaskUpdate {
  request_id: string;
  status: TaskStatus;
  content: string;
  commit?: string;
  report_path?: string;
}

export interface TaskGroup {
  group_id: string;
  session_id: string;
  pending: string[];
  completed: string[];
  tasks: Task[];
}

// ── Session ────────────────────────────────────────────────────────────

export interface Session {
  id: string;
  project_root: string;
  created_at: string;
  agent_count: number;
  agents: Agent[];
}

export interface SessionCreateRequest {
  project_root: string;
}

// ── Approval ───────────────────────────────────────────────────────────

export interface ApprovalItem {
  id: string;
  label: string;
  description: string | null;
  default_selected: boolean;
}

export interface ApprovalRequest {
  request_id: string;
  title: string;
  type: ApprovalType;
  description: string | null;
  items: ApprovalItem[];
}

export interface ApprovalSubmitRequest {
  selected_items: string[];
  refine?: boolean;
  notes?: string;
}

// ── Namespace / Peers ──────────────────────────────────────────────────

export interface Peer {
  pid: number;
  hostname: string;
  project_root: string;
  namespace: string;
  connected_at: string;
}

export interface PeerMessageRequest {
  message: string;
}

// ── Reports ────────────────────────────────────────────────────────────

export interface Report {
  request_id: string;
  content: string;
}

// ── Generic ────────────────────────────────────────────────────────────

export interface SuccessResponse {
  success: boolean;
  message: string;
}

// ── List wrappers ──────────────────────────────────────────────────────

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

// ── WS JSON-RPC param types ───────────────────────────────────────────

export interface DismissAgentParams {
  target: string;
  force?: boolean;
}

export interface SendNotificationParams {
  title: string;
  message: string;
}

export interface PresentOptionsParams {
  request_id: string;
  title: string;
  type: ApprovalType;
  items: ApprovalItem[];
  description?: string;
}

export interface MessagePeerParams {
  target_pid: number;
  message: string;
}
