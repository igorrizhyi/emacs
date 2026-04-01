"""SQLite persistence layer backed by aiosqlite."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

import aiosqlite
import structlog

from ..models.enums import (
    AgentRole,
    AgentStatus,
    TaskPriority,
    TaskStatus,
)
from ..models.session import Session
from ..models.task import Task, TaskGroup

logger = structlog.get_logger()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _parse_dt(val: str | None) -> datetime | None:
    if val is None:
        return None
    return datetime.fromisoformat(val)


class Database:
    """Async SQLite storage for sessions, tasks, agents, and groups."""

    def __init__(self, db_path: str) -> None:
        self._db_path = db_path
        self._conn: aiosqlite.Connection | None = None

    # ── Lifecycle ─────────────────────────────────────────────────────

    async def init(self) -> None:
        self._conn = await aiosqlite.connect(self._db_path)
        self._conn.row_factory = aiosqlite.Row
        await self._conn.execute("PRAGMA journal_mode=WAL")
        await self._conn.execute("PRAGMA foreign_keys=ON")
        await self._ensure_tables()

    async def close(self) -> None:
        if self._conn is not None:
            await self._conn.close()
            self._conn = None

    async def _ensure_tables(self) -> None:
        assert self._conn is not None
        await self._conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                project_root TEXT NOT NULL,
                created_at TEXT NOT NULL,
                metadata TEXT
            );

            CREATE TABLE IF NOT EXISTS tasks (
                request_id TEXT PRIMARY KEY,
                id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                status TEXT NOT NULL,
                message TEXT NOT NULL,
                agent_id TEXT,
                group_id TEXT,
                target TEXT,
                model TEXT,
                priority TEXT DEFAULT 'normal',
                report_path TEXT,
                created_at TEXT NOT NULL,
                assigned_at TEXT,
                completed_at TEXT,
                result TEXT,
                FOREIGN KEY (session_id) REFERENCES sessions(id)
            );

            CREATE TABLE IF NOT EXISTS agents (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                status TEXT NOT NULL,
                worktree_name TEXT,
                worktree_path TEXT,
                current_request_id TEXT,
                reserved INTEGER DEFAULT 0,
                model TEXT,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS task_groups (
                group_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                total INTEGER NOT NULL DEFAULT 0,
                completed INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            );
            """
        )
        await self._conn.commit()

    @property
    def conn(self) -> aiosqlite.Connection:
        assert self._conn is not None, "Database not initialized"
        return self._conn

    # ── Sessions ──────────────────────────────────────────────────────

    async def save_session(self, session: Session) -> None:
        await self.conn.execute(
            "INSERT OR REPLACE INTO sessions (id, project_root, created_at) "
            "VALUES (?, ?, ?)",
            (session.id, session.project_root, session.created_at.isoformat()),
        )
        await self.conn.commit()

    async def get_session(self, session_id: str) -> Session | None:
        cursor = await self.conn.execute(
            "SELECT * FROM sessions WHERE id = ?", (session_id,)
        )
        row = await cursor.fetchone()
        if row is None:
            return None
        return self._row_to_session(row)

    async def list_sessions(self) -> list[Session]:
        cursor = await self.conn.execute("SELECT * FROM sessions ORDER BY created_at")
        rows = await cursor.fetchall()
        return [self._row_to_session(r) for r in rows]

    async def delete_session(self, session_id: str) -> None:
        await self.conn.execute("DELETE FROM tasks WHERE session_id = ?", (session_id,))
        await self.conn.execute("DELETE FROM agents WHERE session_id = ?", (session_id,))
        await self.conn.execute("DELETE FROM sessions WHERE id = ?", (session_id,))
        await self.conn.commit()

    @staticmethod
    def _row_to_session(row: Any) -> Session:
        return Session(
            id=row["id"],
            project_root=row["project_root"],
            created_at=_parse_dt(row["created_at"]),  # type: ignore[arg-type]
        )

    # ── Tasks ─────────────────────────────────────────────────────────

    async def save_task(self, task: Task) -> None:
        await self.conn.execute(
            "INSERT OR REPLACE INTO tasks "
            "(request_id, id, session_id, role, status, message, agent_id, "
            "group_id, target, model, priority, report_path, created_at, "
            "assigned_at, completed_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                task.request_id,
                task.id,
                task.session_id,
                str(task.role),
                str(task.status),
                task.message,
                None,  # agent_id not on Task model
                task.group_id,
                task.target,
                task.model,
                str(task.priority),
                task.report_path,
                task.created_at.isoformat(),
                task.assigned_at.isoformat() if task.assigned_at else None,
                task.completed_at.isoformat() if task.completed_at else None,
            ),
        )
        await self.conn.commit()

    async def get_task(self, request_id: str) -> Task | None:
        cursor = await self.conn.execute(
            "SELECT * FROM tasks WHERE request_id = ?", (request_id,)
        )
        row = await cursor.fetchone()
        if row is None:
            return None
        return self._row_to_task(row)

    async def list_tasks(self, session_id: str) -> list[Task]:
        cursor = await self.conn.execute(
            "SELECT * FROM tasks WHERE session_id = ? ORDER BY created_at",
            (session_id,),
        )
        rows = await cursor.fetchall()
        return [self._row_to_task(r) for r in rows]

    async def update_task_status(
        self,
        request_id: str,
        status: TaskStatus,
        completed_at: datetime | None = None,
        assigned_at: datetime | None = None,
        result: str | None = None,
    ) -> None:
        parts = ["status = ?"]
        params: list[Any] = [str(status)]
        if completed_at is not None:
            parts.append("completed_at = ?")
            params.append(completed_at.isoformat())
        if assigned_at is not None:
            parts.append("assigned_at = ?")
            params.append(assigned_at.isoformat())
        if result is not None:
            parts.append("result = ?")
            params.append(result)
        params.append(request_id)
        await self.conn.execute(
            f"UPDATE tasks SET {', '.join(parts)} WHERE request_id = ?",
            params,
        )
        await self.conn.commit()

    @staticmethod
    def _row_to_task(row: Any) -> Task:
        return Task(
            id=row["id"],
            request_id=row["request_id"],
            role=AgentRole(row["role"]),
            message=row["message"],
            group_id=row["group_id"],
            target=row["target"],
            priority=TaskPriority(row["priority"]) if row["priority"] else TaskPriority.NORMAL,
            model=row["model"],
            session_id=row["session_id"],
            report_path=row["report_path"],
            status=TaskStatus(row["status"]),
            created_at=_parse_dt(row["created_at"]),  # type: ignore[arg-type]
            assigned_at=_parse_dt(row["assigned_at"]),
            completed_at=_parse_dt(row["completed_at"]),
        )

    # ── Agents ────────────────────────────────────────────────────────

    async def save_agent(
        self,
        agent_id: str,
        session_id: str,
        role: str,
        status: str,
        worktree_name: str | None = None,
        worktree_path: str | None = None,
        current_request_id: str | None = None,
        reserved: bool = False,
        model: str | None = None,
        created_at: str | None = None,
    ) -> None:
        await self.conn.execute(
            "INSERT OR REPLACE INTO agents "
            "(id, session_id, role, status, worktree_name, worktree_path, "
            "current_request_id, reserved, model, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                agent_id,
                session_id,
                role,
                status,
                worktree_name,
                worktree_path,
                current_request_id,
                int(reserved),
                model,
                created_at or _now_iso(),
            ),
        )
        await self.conn.commit()

    async def get_agent(self, agent_id: str) -> dict[str, Any] | None:
        cursor = await self.conn.execute(
            "SELECT * FROM agents WHERE id = ?", (agent_id,)
        )
        row = await cursor.fetchone()
        if row is None:
            return None
        return dict(row)

    async def list_agents(self, session_id: str) -> list[dict[str, Any]]:
        cursor = await self.conn.execute(
            "SELECT * FROM agents WHERE session_id = ? ORDER BY created_at",
            (session_id,),
        )
        rows = await cursor.fetchall()
        return [dict(r) for r in rows]

    async def update_agent_status(self, agent_id: str, status: str) -> None:
        await self.conn.execute(
            "UPDATE agents SET status = ? WHERE id = ?", (status, agent_id)
        )
        await self.conn.commit()

    async def delete_agent(self, agent_id: str) -> None:
        await self.conn.execute("DELETE FROM agents WHERE id = ?", (agent_id,))
        await self.conn.commit()

    # ── Task Groups ───────────────────────────────────────────────────

    async def save_task_group(
        self, group_id: str, session_id: str, total: int = 0
    ) -> None:
        await self.conn.execute(
            "INSERT OR REPLACE INTO task_groups "
            "(group_id, session_id, total, completed, created_at) "
            "VALUES (?, ?, ?, 0, ?)",
            (group_id, session_id, total, _now_iso()),
        )
        await self.conn.commit()

    async def get_task_group(self, group_id: str) -> dict[str, Any] | None:
        cursor = await self.conn.execute(
            "SELECT * FROM task_groups WHERE group_id = ?", (group_id,)
        )
        row = await cursor.fetchone()
        if row is None:
            return None
        return dict(row)

    async def update_group_progress(
        self, group_id: str, completed: int, total: int | None = None
    ) -> None:
        if total is not None:
            await self.conn.execute(
                "UPDATE task_groups SET completed = ?, total = ? WHERE group_id = ?",
                (completed, total, group_id),
            )
        else:
            await self.conn.execute(
                "UPDATE task_groups SET completed = ? WHERE group_id = ?",
                (completed, group_id),
            )
        await self.conn.commit()
