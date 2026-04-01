"""SessionManager — session lifecycle and task persistence."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

import structlog

from gang_of_none.config import Settings
from gang_of_none.core.agent_manager import AgentManager
from gang_of_none.models.enums import AgentRole, TaskStatus
from gang_of_none.models.session import Session, SessionHistory, TaskSummary
from gang_of_none.models.task import Task

logger = structlog.get_logger()


class SessionManager:
    """Manages session lifecycle and persists task data to disk."""

    def __init__(
        self,
        settings: Settings,
        agent_manager: AgentManager,
    ) -> None:
        self._settings = settings
        self._agent_mgr = agent_manager
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

    # ── Task Persistence ──────────────────────────────────────────────

    def _tasks_dir(self, project_root: str) -> Path:
        """Resolve the tasks directory for a project."""
        return Path(project_root) / self._settings.tasks_dir

    def persist_task(self, session_id: str, task: Task) -> None:
        """Write task data to {tasks_dir}/{session_id}/{request_id}.json."""
        session = self._sessions.get(session_id)
        if session is None:
            logger.warning("persist_task.no_session", session_id=session_id)
            return

        task_dir = self._tasks_dir(session.project_root) / session_id
        task_dir.mkdir(parents=True, exist_ok=True)
        task_file = task_dir / f"{task.request_id}.json"

        data = task.model_dump(mode="json")
        task_file.write_text(json.dumps(data, indent=2, default=str), encoding="utf-8")
        logger.debug(
            "task.persisted",
            session_id=session_id,
            request_id=task.request_id,
            path=str(task_file),
        )

    def load_tasks(self, session_id: str, project_root: str) -> list[Task]:
        """Read all persisted tasks for a session from disk."""
        task_dir = self._tasks_dir(project_root) / session_id
        if not task_dir.is_dir():
            return []

        tasks: list[Task] = []
        for task_file in sorted(task_dir.glob("*.json")):
            try:
                data = json.loads(task_file.read_text(encoding="utf-8"))
                tasks.append(Task.model_validate(data))
            except Exception:
                logger.exception("task.load_failed", path=str(task_file))
        return tasks

    def load_all_sessions(self, project_root: str) -> dict[str, list[Task]]:
        """Scan tasks dir for all sessions and their persisted tasks."""
        tasks_root = self._tasks_dir(project_root)
        if not tasks_root.is_dir():
            return {}

        result: dict[str, list[Task]] = {}
        for session_dir in tasks_root.iterdir():
            if session_dir.is_dir():
                sid = session_dir.name
                tasks = self.load_tasks(sid, project_root)
                if tasks:
                    result[sid] = tasks
        return result

    # ── Session History ───────────────────────────────────────────────

    def get_session_history(self, session_id: str) -> SessionHistory | None:
        """Build a SessionHistory for the given session."""
        session = self._sessions.get(session_id)
        if session is None:
            return None

        # Gather persisted tasks from disk
        persisted = self.load_tasks(session_id, session.project_root)

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
