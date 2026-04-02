from datetime import datetime

from pydantic import BaseModel, Field

from .enums import AgentRole, AgentStatus


class WorktreeInfo(BaseModel):
    """Info about an agent's git worktree."""

    path: str
    name: str
    branch: str


class Agent(BaseModel):
    id: str
    role: AgentRole
    status: AgentStatus = AgentStatus.INITIALIZING
    session_id: str
    worktree_path: str | None = None
    worktree_name: str | None = None
    buffer_name: str | None = None
    model: str | None = None
    ephemeral: bool = False
    reserved: bool = False
    init_finished: bool = False
    current_task_id: str | None = None
    created_at: datetime = Field(default_factory=datetime.utcnow)
    pid: int | None = None


class AgentCreate(BaseModel):
    role: AgentRole
    session_id: str
    mode: str = "isolated"
