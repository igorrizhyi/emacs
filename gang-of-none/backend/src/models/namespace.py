from datetime import datetime

from pydantic import BaseModel


class NamespaceConfig(BaseModel):
    namespace: str
    description: str | None = None


class Peer(BaseModel):
    pid: int
    hostname: str
    project_root: str
    namespace: str
    connected_at: datetime


class PeerMessage(BaseModel):
    target_pid: int
    message: str
    sender_session: str | None = None
