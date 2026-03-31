"""Orchestrator — glue between TaskManager, AgentManager, and ACPSessionManager.

Handles task-to-agent assignment, agent spawning, and completion cycling.
"""

from __future__ import annotations

import asyncio
from typing import Any

import structlog

from gang_of_none.config import Settings
from gang_of_none.core.acp_session import ACPSessionManager
from gang_of_none.core.agent_manager import AgentManager
from gang_of_none.core.task_manager import TaskManager
from gang_of_none.models.agent import AgentCreate
from gang_of_none.models.enums import AgentRole, AgentStatus, TaskStatus

logger = structlog.get_logger()


class Orchestrator:
    """Connects TaskManager + AgentManager + ACPSessionManager."""

    def __init__(
        self,
        settings: Settings,
        task_manager: TaskManager,
        agent_manager: AgentManager,
        acp_session_manager: ACPSessionManager,
    ) -> None:
        self.settings = settings
        self.task_mgr = task_manager
        self.agent_mgr = agent_manager
        self.acp_mgr = acp_session_manager
        self._drain_task: asyncio.Task[None] | None = None

    # ── Drain loop ─────────────────────────────────────────────────

    async def start_drain_loop(self) -> None:
        """Start the periodic drain loop that assigns pending tasks."""
        if self._drain_task is not None:
            return
        self._drain_task = asyncio.create_task(
            self._drain_loop(), name="orchestrator-drain"
        )

    async def stop_drain_loop(self) -> None:
        """Stop the drain loop."""
        if self._drain_task is not None:
            self._drain_task.cancel()
            try:
                await self._drain_task
            except asyncio.CancelledError:
                pass
            self._drain_task = None

    async def _drain_loop(self) -> None:
        """Periodically attempt to assign queued tasks to idle agents."""
        try:
            while True:
                await asyncio.sleep(self.settings.drain_interval_seconds)
                # Try assignment for all sessions that have agents
                for session_id in self._active_session_ids():
                    await self.try_assign_tasks(session_id)
        except asyncio.CancelledError:
            return

    def _active_session_ids(self) -> set[str]:
        """Collect session IDs from all registered agents."""
        return {
            agent.session_id
            for agent in self.agent_mgr._agents.values()
        }

    # ── Assignment ─────────────────────────────────────────────────

    async def try_assign_tasks(self, session_id: str) -> int:
        """Match pending tasks to idle agents, spawn if needed.

        Returns the number of tasks assigned in this pass.
        """
        assigned_count = 0

        for role in AgentRole:
            if role == AgentRole.LEAD:
                continue

            pending = self.task_mgr.get_pending_for_role(role)
            if not pending:
                continue

            for task in pending:
                # Skip targeted tasks that don't match any idle agent
                idle_agents = self.agent_mgr.get_idle_agents(role, session_id)

                agent = None
                if task.target:
                    agent = self.agent_mgr.find_agent_by_name(task.target)
                    if agent is None or agent.status != AgentStatus.IDLE:
                        continue
                elif idle_agents:
                    agent = idle_agents[0]
                elif self.agent_mgr.should_auto_spawn(role, session_id):
                    agent = await self._spawn_agent(role, session_id, task.model)
                    if agent is None:
                        continue

                if agent is None:
                    continue

                await self.assign_task_to_agent(task, agent.id, session_id)
                assigned_count += 1

        return assigned_count

    async def assign_task_to_agent(
        self, task: Any, agent_id: str, session_id: str
    ) -> None:
        """Mark task assigned, mark agent busy, prompt via ACP."""
        self.task_mgr.mark_assigned(task.request_id, agent_id)
        self.agent_mgr.mark_busy(agent_id, task.request_id)
        self.agent_mgr.assign_request(task.request_id, agent_id)

        logger.info(
            "task.assigned",
            request_id=task.request_id,
            agent_id=agent_id,
            role=str(task.role),
        )

        # Build prompt with request_id and report_path metadata
        prompt = (
            f"[Request ID: {task.request_id}]\n"
            f"Write your report to: {task.report_path}\n\n"
            f"{task.message}"
        )

        acp_session = self.acp_mgr.get_session(agent_id)
        if acp_session is not None:
            try:
                await acp_session.prompt(prompt)
            except Exception:
                logger.exception("acp.prompt_failed", agent_id=agent_id)

    async def handle_agent_completion(
        self, request_id: str, status: TaskStatus, session_id: str
    ) -> None:
        """Mark task complete, mark agent idle, trigger re-assignment."""
        task = self.task_mgr.mark_completed(request_id, status)
        if task is None:
            return

        agent = self.agent_mgr.get_agent_for_request(request_id)
        if agent is not None:
            self.agent_mgr.mark_idle(agent.id)

        await self.try_assign_tasks(session_id)

    # ── Agent spawning ─────────────────────────────────────────────

    async def _spawn_agent(
        self,
        role: AgentRole,
        session_id: str,
        model: str | None = None,
    ) -> Any | None:
        """Spawn a new agent and start its ACP session."""
        create = AgentCreate(role=role, session_id=session_id)
        agent = self.agent_mgr.create_agent(create)

        work_dir = f"{self.settings.worktree_subdir}/{agent.worktree_name}"
        try:
            await self.acp_mgr.create_session(
                agent_id=agent.id,
                work_dir=work_dir,
                model=model,
            )
        except Exception:
            logger.exception("agent.spawn_failed", agent_id=agent.id)
            self.agent_mgr.dismiss_agent(agent.id)
            return None

        self.agent_mgr.mark_init_finished(agent.id)
        logger.info("agent.spawned", agent_id=agent.id, role=str(role))
        return agent
