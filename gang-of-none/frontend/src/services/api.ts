import type {
  Agent,
  AgentListResponse,
  ApprovalListResponse,
  ApprovalRequest,
  ApprovalSubmitRequest,
  PeerListResponse,
  PeerMessageRequest,
  Report,
  Session,
  SessionCreateRequest,
  SessionListResponse,
  SuccessResponse,
  Task,
  TaskCreate,
  TaskGroup,
  TaskListResponse,
} from './types';

// ── Configuration ──────────────────────────────────────────────────────

let baseUrl = 'http://localhost:8000/api';

export function setBaseUrl(url: string): void {
  baseUrl = url.replace(/\/+$/, '');
}

export function getBaseUrl(): string {
  return baseUrl;
}

// ── Fetch wrapper ──────────────────────────────────────────────────────

class ApiError extends Error {
  constructor(
    public status: number,
    public statusText: string,
    public body?: unknown,
  ) {
    super(`API ${status}: ${statusText}`);
    this.name = 'ApiError';
  }
}

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${baseUrl}${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...options?.headers,
    },
  });

  if (!res.ok) {
    let body: unknown;
    try {
      body = await res.json();
    } catch {
      // ignore parse failure
    }
    throw new ApiError(res.status, res.statusText, body);
  }

  return res.json() as Promise<T>;
}

// ── Sessions ───────────────────────────────────────────────────────────

export function getSessions(): Promise<SessionListResponse> {
  return request('/sessions');
}

export function getSession(sessionId: string): Promise<Session> {
  return request(`/sessions/${sessionId}`);
}

export function createSession(req: SessionCreateRequest): Promise<Session> {
  return request('/sessions', {
    method: 'POST',
    body: JSON.stringify(req),
  });
}

export function deleteSession(sessionId: string): Promise<SuccessResponse> {
  return request(`/sessions/${sessionId}`, { method: 'DELETE' });
}

// ── Agents ─────────────────────────────────────────────────────────────

export function getAgents(sessionId: string): Promise<AgentListResponse> {
  return request(`/sessions/${sessionId}/agents`);
}

export function getAgent(agentId: string): Promise<Agent> {
  return request(`/agents/${agentId}`);
}

export function reserveAgent(agentId: string): Promise<Agent> {
  return request(`/agents/${agentId}/reserve`, { method: 'POST' });
}

export function cancelAgent(agentId: string): Promise<SuccessResponse> {
  return request(`/agents/${agentId}/cancel`, { method: 'POST' });
}

// ── Tasks ──────────────────────────────────────────────────────────────

export function getTasks(sessionId: string): Promise<TaskListResponse> {
  return request(`/sessions/${sessionId}/tasks`);
}

export function getTask(requestId: string): Promise<Task> {
  return request(`/tasks/${requestId}`);
}

export function createTask(
  sessionId: string,
  req: TaskCreate,
): Promise<TaskListResponse> {
  return request(`/sessions/${sessionId}/tasks`, {
    method: 'POST',
    body: JSON.stringify(req),
  });
}

export function getGroup(groupId: string): Promise<TaskGroup> {
  return request(`/groups/${groupId}`);
}

// ── Approvals ──────────────────────────────────────────────────────────

export function getApprovals(): Promise<ApprovalListResponse> {
  return request('/approvals');
}

export function getApproval(requestId: string): Promise<ApprovalRequest> {
  return request(`/approvals/${requestId}`);
}

export function submitApproval(
  requestId: string,
  req: ApprovalSubmitRequest,
): Promise<SuccessResponse> {
  return request(`/approvals/${requestId}/submit`, {
    method: 'POST',
    body: JSON.stringify(req),
  });
}

export function dismissApproval(requestId: string): Promise<SuccessResponse> {
  return request(`/approvals/${requestId}`, { method: 'DELETE' });
}

// ── Namespace / Peers ──────────────────────────────────────────────────

export function getNamespace(): Promise<unknown> {
  return request('/namespace');
}

export function getPeers(): Promise<PeerListResponse> {
  return request('/namespace/peers');
}

export function messagePeer(
  pid: number,
  req: PeerMessageRequest,
): Promise<SuccessResponse> {
  return request(`/namespace/peers/${pid}/message`, {
    method: 'POST',
    body: JSON.stringify(req),
  });
}

// ── Reports ────────────────────────────────────────────────────────────

export function getReport(
  sessionId: string,
  requestId: string,
): Promise<Report> {
  return request(`/reports/${sessionId}/${requestId}`);
}

export { ApiError };
