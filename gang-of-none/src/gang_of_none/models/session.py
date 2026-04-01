from datetime import datetime, timezone

from pydantic import BaseModel, Field

from .enums import AgentRole, TaskStatus


class Session(BaseModel):
    id: str
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    project_root: str


class SessionInfo(BaseModel):
    id: str
    created_at: datetime
    project_root: str
    agent_count_by_role: dict[str, int] = Field(default_factory=dict)


class TaskSummary(BaseModel):
    request_id: str
    role: AgentRole
    status: TaskStatus
    label: str
    completed_at: datetime | None = None


class SessionHistory(BaseModel):
    session_id: str
    created_at: datetime
    tasks: list[TaskSummary]
    agent_count: int
