from enum import StrEnum


class AgentRole(StrEnum):
    LEAD = "lead"
    DEV = "dev"
    TESTER = "tester"
    RESEARCHER = "researcher"


class AgentStatus(StrEnum):
    IDLE = "idle"
    BUSY = "busy"
    INITIALIZING = "initializing"
    DEAD = "dead"


class TaskStatus(StrEnum):
    PENDING = "pending"
    ASSIGNED = "assigned"
    FINISHED = "finished"
    UPDATED = "updated"
    BLOCKED = "blocked"


class TaskPriority(StrEnum):
    NORMAL = "normal"
    INTERRUPT = "interrupt"


class ApprovalType(StrEnum):
    CHECKLIST = "checklist"
    CHOICE = "choice"
