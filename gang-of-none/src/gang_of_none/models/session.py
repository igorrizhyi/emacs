from datetime import datetime

from pydantic import BaseModel, Field


class Session(BaseModel):
    id: str
    created_at: datetime = Field(default_factory=datetime.utcnow)
    project_root: str


class SessionInfo(BaseModel):
    id: str
    created_at: datetime
    project_root: str
    agent_count_by_role: dict[str, int] = Field(default_factory=dict)
