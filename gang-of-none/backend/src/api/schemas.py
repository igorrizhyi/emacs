"""Pydantic response models for the REST API."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel

from ..models.enums import (
    AgentRole,
    AgentStatus,
    ApprovalType,
    TaskPriority,
    TaskStatus,
)


# ── Generic ────────────────────────────────────────────────────────────

class SuccessResponse(BaseModel):
    success: bool
    message: str


# ── Sessions ───────────────────────────────────────────────────────────

class SessionResponse(BaseModel):
    id: str
    project_root: str
    created_at: datetime
    agent_count: int = 0
    agents: list[AgentResponse] = []


class SessionListResponse(BaseModel):
    sessions: list[SessionResponse]


class SessionCreateRequest(BaseModel):
    project_root: str


# ── Agents ─────────────────────────────────────────────────────────────

class AgentResponse(BaseModel):
    id: str
    role: AgentRole
    status: AgentStatus
    session_id: str
    worktree_name: str | None = None
    worktree_path: str | None = None
    buffer_name: str | None = None
    ephemeral: bool = False
    reserved: bool = False
    init_finished: bool = False
    current_task_id: str | None = None
    created_at: datetime
    pid: int | None = None


class AgentListResponse(BaseModel):
    agents: list[AgentResponse]


# ── Tasks ──────────────────────────────────────────────────────────────

class TaskResponse(BaseModel):
    id: str
    request_id: str
    role: AgentRole
    message: str
    group_id: str | None = None
    target: str | None = None
    priority: TaskPriority
    model: str | None = None
    session_id: str
    report_path: str | None = None
    status: TaskStatus
    created_at: datetime
    assigned_at: datetime | None = None
    completed_at: datetime | None = None


class TaskListResponse(BaseModel):
    tasks: list[TaskResponse]


class TaskCreateRequest(BaseModel):
    role: AgentRole
    message: str
    priority: TaskPriority = TaskPriority.NORMAL
    group_id: str | None = None
    target: str | None = None
    model: str | None = None


class GroupResponse(BaseModel):
    group_id: str
    session_id: str
    pending: list[str]
    completed: list[str]
    tasks: list[TaskResponse] = []


# ── Approvals ──────────────────────────────────────────────────────────

class ApprovalItemResponse(BaseModel):
    id: str
    label: str
    description: str | None = None
    default_selected: bool = False


class ApprovalResponse(BaseModel):
    request_id: str
    title: str
    type: ApprovalType
    description: str | None = None
    items: list[ApprovalItemResponse] = []


class ApprovalListResponse(BaseModel):
    approvals: list[ApprovalResponse]


class ApprovalSubmitRequest(BaseModel):
    selected_items: list[str]
    refine: bool = False
    notes: str | None = None


# ── Namespace / Peers ──────────────────────────────────────────────────

class PeerResponse(BaseModel):
    pid: int
    hostname: str
    project_root: str
    namespace: str
    connected_at: datetime


class PeerListResponse(BaseModel):
    peers: list[PeerResponse]


class PeerMessageRequest(BaseModel):
    message: str


# ── Reports ────────────────────────────────────────────────────────────

class ReportResponse(BaseModel):
    request_id: str
    content: str


# Forward-ref resolution (SessionResponse uses AgentResponse)
SessionResponse.model_rebuild()
