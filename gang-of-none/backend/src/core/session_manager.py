"""SessionManager — session lifecycle and task persistence."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import TYPE_CHECKING
from uuid import uuid4

import structlog

from ..config import Settings
from .agent_manager import AgentManager
from ..models.session import Session, SessionHistory, TaskSummary
from ..models.task import Task

if TYPE_CHECKING:
    from .database import Database

logger = structlog.get_logger()


class SessionManager:
    """Manages session lifecycle and persists task data via Database."""

    def __init__(
        self,
        settings: Settings,
        agent_manager: AgentManager,
        db: Database | None = None,
    ) -> None:
        self._settings = settings
        self._agent_mgr = agent_manager
        self._db = db
        self._sessions: dict[str, Session] = {}

    # ── Session CRUD ──────────────────────────────────────────────────

    def create_session(self, project_root: str) -> Session:
        """Create a new session with a generated UUID."""
        session = Session(
            id=uuid4().hex[:8],
            project_root=project_root,
        )
        self._sessions[session.id] = session
        logger.info("session.created", session_id=session.id, project_root=project_root)
        return session

    async def create_session_async(self, project_root: str) -> Session:
        """Create session and persist to DB."""
        session = self.create_session(project_root)
        if self._db is not None:
            await self._db.save_session(session)
        return session

    def get_session(self, session_id: str) -> Session | None:
        """Return a session by ID, or None."""
        return self._sessions.get(session_id)

    def list_sessions(self) -> dict[str, Session]:
        """Return the sessions registry (dict of id -> Session)."""
        return self._sessions

    def destroy_session(self, session_id: str) -> None:
        """Remove a session from the registry."""
        removed = self._sessions.pop(session_id, None)
        if removed is not None:
            logger.info("session.destroyed", session_id=session_id)

    async def destroy_session_async(self, session_id: str) -> None:
        """Remove session from registry and DB."""
        self.destroy_session(session_id)
        if self._db is not None:
            await self._db.delete_session(session_id)

    # ── Task Persistence ──────────────────────────────────────────────

    async def persist_task(self, session_id: str, task: Task) -> None:
        """Persist task data to SQLite."""
        if self._db is not None:
            await self._db.save_task(task)
            logger.debug(
                "task.persisted",
                session_id=session_id,
                request_id=task.request_id,
            )

    async def load_tasks(self, session_id: str) -> list[Task]:
        """Read all persisted tasks for a session from DB."""
        if self._db is None:
            return []
        return await self._db.list_tasks(session_id)

    # ── Session Restore ───────────────────────────────────────────────

    async def restore_from_db(self) -> None:
        """Rehydrate in-memory session registry from SQLite on startup."""
        if self._db is None:
            return
        sessions = await self._db.list_sessions()
        for session in sessions:
            self._sessions[session.id] = session
        if sessions:
            logger.info("sessions.restored", count=len(sessions))

    # ── Session History ───────────────────────────────────────────────

    async def get_session_history(self, session_id: str) -> SessionHistory | None:
        """Build a SessionHistory for the given session."""
        session = self._sessions.get(session_id)
        if session is None:
            return None

        persisted = await self.load_tasks(session_id)

        task_summaries = [
            TaskSummary(
                request_id=t.request_id,
                role=t.role,
                status=t.status,
                label=t.message[:60],
                completed_at=t.completed_at,
            )
            for t in persisted
        ]

        agents = self._agent_mgr.get_session_agents(session_id)

        return SessionHistory(
            session_id=session.id,
            created_at=session.created_at,
            tasks=task_summaries,
            agent_count=len(agents),
        )
