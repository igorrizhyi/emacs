/**
 * REST API client for the gang-of-none backend.
 *
 * All endpoints return camelCased types; snake_case → camelCase
 * mapping happens in the transform helpers below.
 */

import type {
  Agent,
  ApprovalRequest,
  ApprovalItem,
  Session,
  Task,
  TaskGroup,
} from '@/store/types';

// ── Config ─────────────────────────────────────────────────────────────

let baseUrl = '';

export function setBaseUrl(url: string) {
  baseUrl = url.replace(/\/+$/, '');
}

// ── Fetch wrapper ──────────────────────────────────────────────────────

async function apiFetch<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${baseUrl}${path}`, {
    ...init,
    headers: { 'Content-Type': 'application/json', ...init?.headers },
  });
  if (!res.ok) {
    throw new Error(`API ${res.status}: ${res.statusText}`);
  }
  return res.json() as Promise<T>;
}

// ── Snake → Camel transforms ───────────────────────────────────────────

function toSession(raw: Record<string, unknown>): Session {
  return {
    id: raw['id'] as string,
    projectRoot: raw['project_root'] as string,
    createdAt: raw['created_at'] as string,
    agentCount: (raw['agent_count'] as number) ?? 0,
    agentIds: ((raw['agents'] as Array<Record<string, unknown>>) ?? []).map(
      (a) => a['id'] as string,
    ),
  };
}

function toAgent(raw: Record<string, unknown>): Agent {
  return {
    id: raw['id'] as string,
    role: raw['role'] as Agent['role'],
    status: raw['status'] as Agent['status'],
    sessionId: raw['session_id'] as string,
    worktreeName: (raw['worktree_name'] as string) ?? null,
    worktreePath: (raw['worktree_path'] as string) ?? null,
    bufferName: (raw['buffer_name'] as string) ?? null,
    ephemeral: (raw['ephemeral'] as boolean) ?? false,
    reserved: (raw['reserved'] as boolean) ?? false,
    initFinished: (raw['init_finished'] as boolean) ?? false,
    currentTaskId: (raw['current_task_id'] as string) ?? null,
    createdAt: raw['created_at'] as string,
    pid: (raw['pid'] as number) ?? null,
  };
}

function toTask(raw: Record<string, unknown>): Task {
  return {
    id: raw['id'] as string,
    requestId: raw['request_id'] as string,
    role: raw['role'] as Task['role'],
    message: raw['message'] as string,
    groupId: (raw['group_id'] as string) ?? null,
    target: (raw['target'] as string) ?? null,
    priority: raw['priority'] as Task['priority'],
    model: (raw['model'] as string) ?? null,
    sessionId: raw['session_id'] as string,
    reportPath: (raw['report_path'] as string) ?? null,
    status: raw['status'] as Task['status'],
    createdAt: raw['created_at'] as string,
    assignedAt: (raw['assigned_at'] as string) ?? null,
    completedAt: (raw['completed_at'] as string) ?? null,
  };
}

function toTaskGroup(raw: Record<string, unknown>): TaskGroup {
  return {
    groupId: raw['group_id'] as string,
    sessionId: raw['session_id'] as string,
    pending: (raw['pending'] as string[]) ?? [],
    completed: (raw['completed'] as string[]) ?? [],
  };
}

function toApprovalItem(raw: Record<string, unknown>): ApprovalItem {
  return {
    id: raw['id'] as string,
    label: raw['label'] as string,
    description: raw['description'] as string | undefined,
    defaultSelected: (raw['default_selected'] as boolean) ?? false,
    selected: (raw['default_selected'] as boolean) ?? false,
  };
}

function toApproval(raw: Record<string, unknown>): ApprovalRequest {
  return {
    requestId: raw['request_id'] as string,
    title: raw['title'] as string,
    type: raw['type'] as ApprovalRequest['type'],
    description: raw['description'] as string | undefined,
    items: ((raw['items'] as Array<Record<string, unknown>>) ?? []).map(toApprovalItem),
    timestamp: Date.now(),
  };
}

// ── Sessions ───────────────────────────────────────────────────────────

export async function fetchSessions(): Promise<Session[]> {
  const data = await apiFetch<{ sessions: Array<Record<string, unknown>> }>('/api/sessions');
  return data.sessions.map(toSession);
}

export async function fetchSession(sessionId: string): Promise<Session> {
  const data = await apiFetch<Record<string, unknown>>(`/api/sessions/${sessionId}`);
  return toSession(data);
}

export async function createSession(projectRoot: string): Promise<Session> {
  const data = await apiFetch<Record<string, unknown>>('/api/sessions', {
    method: 'POST',
    body: JSON.stringify({ project_root: projectRoot }),
  });
  return toSession(data);
}

export async function deleteSession(sessionId: string): Promise<void> {
  await apiFetch(`/api/sessions/${sessionId}`, { method: 'DELETE' });
}

// ── Agents ─────────────────────────────────────────────────────────────

export async function fetchAgents(sessionId: string): Promise<Agent[]> {
  const data = await apiFetch<{ agents: Array<Record<string, unknown>> }>(
    `/api/sessions/${sessionId}/agents`,
  );
  return data.agents.map(toAgent);
}

export async function fetchAgent(agentId: string): Promise<Agent> {
  const data = await apiFetch<Record<string, unknown>>(`/api/agents/${agentId}`);
  return toAgent(data);
}

// ── Tasks ──────────────────────────────────────────────────────────────

export async function fetchTasks(sessionId: string): Promise<Task[]> {
  const data = await apiFetch<{ tasks: Array<Record<string, unknown>> }>(
    `/api/sessions/${sessionId}/tasks`,
  );
  return data.tasks.map(toTask);
}

export async function fetchTaskGroups(groupId: string): Promise<TaskGroup> {
  const data = await apiFetch<Record<string, unknown>>(`/api/groups/${groupId}`);
  return toTaskGroup(data);
}

// ── Approvals ──────────────────────────────────────────────────────────

export async function fetchApprovals(): Promise<ApprovalRequest[]> {
  const data = await apiFetch<{ approvals: Array<Record<string, unknown>> }>('/api/approvals');
  return data.approvals.map(toApproval);
}

export async function submitApproval(
  requestId: string,
  selectedItems: string[],
  opts?: { refine?: boolean; notes?: string },
): Promise<void> {
  await apiFetch(`/api/approvals/${requestId}/submit`, {
    method: 'POST',
    body: JSON.stringify({
      selected_items: selectedItems,
      refine: opts?.refine ?? false,
      notes: opts?.notes,
    }),
  });
}

export async function dismissApproval(requestId: string): Promise<void> {
  await apiFetch(`/api/approvals/${requestId}`, { method: 'DELETE' });
}
