from datetime import datetime, timezone

from pydantic import BaseModel, Field

from .enums import AgentRole, TaskPriority, TaskStatus


class TaskCreate(BaseModel):
    role: AgentRole
    message: str
    group_id: str | None = None
    request_id: str | None = None
    target: str | None = None
    priority: TaskPriority = TaskPriority.NORMAL
    model: str | None = None


class Task(BaseModel):
    id: str
    request_id: str
    role: AgentRole
    message: str
    group_id: str | None = None
    target: str | None = None
    priority: TaskPriority = TaskPriority.NORMAL
    model: str | None = None
    session_id: str
    report_path: str | None = None
    status: TaskStatus = TaskStatus.PENDING
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    assigned_at: datetime | None = None
    completed_at: datetime | None = None


class TaskGroup(BaseModel):
    group_id: str
    pending: list[str] = Field(default_factory=list)
    completed: list[str] = Field(default_factory=list)
    session_id: str


class TaskUpdate(BaseModel):
    request_id: str
    status: TaskStatus
    content: str
    commit: str | None = None
    report_path: str | None = None
