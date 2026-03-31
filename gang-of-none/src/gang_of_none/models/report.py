from pydantic import BaseModel


class ReportInfo(BaseModel):
    session_id: str
    request_id: str
    path: str
    exists: bool
    size: int = 0
