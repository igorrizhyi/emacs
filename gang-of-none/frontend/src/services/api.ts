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
} from '@/store/types';

// ── Key mapping utilities ─────────────────────────────────────────────

function snakeToCamel(s: string): string {
  return s.replace(/_([a-z])/g, (_, c: string) => c.toUpperCase());
}

function camelToSnake(s: string): string {
  return s.replace(/[A-Z]/g, (c) => '_' + c.toLowerCase());
}

type AnyRecord = Record<string, unknown>;

/** Recursively convert object keys from snake_case to camelCase. */
function mapKeys<T>(obj: unknown): T {
  if (Array.isArray(obj)) {
    return obj.map((item) => mapKeys(item)) as unknown as T;
  }
  if (obj !== null && typeof obj === 'object' && !(obj instanceof Date)) {
    const mapped: AnyRecord = {};
    for (const [key, value] of Object.entries(obj as AnyRecord)) {
      mapped[snakeToCamel(key)] = mapKeys(value);
    }
    return mapped as T;
  }
  return obj as T;
}

/** Recursively convert object keys from camelCase to snake_case. */
function toSnake(obj: unknown): unknown {
  if (Array.isArray(obj)) {
    return obj.map((item) => toSnake(item));
  }
  if (obj !== null && typeof obj === 'object' && !(obj instanceof Date)) {
    const mapped: AnyRecord = {};
    for (const [key, value] of Object.entries(obj as AnyRecord)) {
      mapped[camelToSnake(key)] = toSnake(value);
    }
    return mapped;
  }
  return obj;
}

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

/** Raw request — returns snake_case JSON as-is. */
async function requestRaw<T>(path: string, options?: RequestInit): Promise<T> {
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

/** Request with automatic snake_case → camelCase response mapping. */
async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const raw = await requestRaw<unknown>(path, options);
  return mapKeys<T>(raw);
}

/** JSON.stringify with camelCase → snake_case key conversion. */
function jsonBody(obj: unknown): string {
  return JSON.stringify(toSnake(obj));
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
    body: jsonBody(req),
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
    body: jsonBody(req),
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
    body: jsonBody(req),
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
    body: jsonBody(req),
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
