from datetime import datetime

from pydantic import BaseModel

from .enums import ApprovalType


class ApprovalItem(BaseModel):
    id: str
    label: str
    description: str | None = None
    default_selected: bool = False


class ApprovalRequest(BaseModel):
    request_id: str
    title: str
    type: ApprovalType
    items: list[ApprovalItem]
    description: str | None = None
    session_id: str
    created_at: datetime


class ApprovalSubmission(BaseModel):
    request_id: str
    selected_items: list[str]
    refine: str | None = None
    notes: str | None = None
    submitted_at: datetime
