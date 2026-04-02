"""Orchestrator — glue between TaskManager, AgentManager, and ACPSessionManager.

Handles task-to-agent assignment, agent spawning, and completion cycling.
"""

from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING, Any

import structlog

from ..config import Settings
from .acp_session import ACPSessionManager
from .agent_manager import AgentManager
from .prompt_manager import PromptManager
from .report_manager import ReportManager
from .task_manager import TaskManager
from .retry import is_retryable_error
from .isolation import build_command_prefix
from .worktree_manager import WorktreeManager

if TYPE_CHECKING:
    from ..api.connection_manager import ConnectionManager
    from .session_manager import SessionManager
from ..models.agent import AgentCreate
from ..models.enums import AgentRole, AgentStatus, TaskStatus

logger = structlog.get_logger()


class Orchestrator:
    """Connects TaskManager + AgentManager + ACPSessionManager."""

    def __init__(
        self,
        settings: Settings,
        task_manager: TaskManager,
        agent_manager: AgentManager,
        acp_session_manager: ACPSessionManager,
        worktree_manager: WorktreeManager,
        report_manager: ReportManager | None = None,
        session_manager: SessionManager | None = None,
        prompt_manager: PromptManager | None = None,
        connection_manager: ConnectionManager | None = None,
    ) -> None:
        self.settings = settings
        self.task_mgr = task_manager
        self.agent_mgr = agent_manager
        self.acp_mgr = acp_session_manager
        self.worktree_mgr = worktree_manager
        self.report_mgr = report_manager
        self.session_mgr = session_manager
        self.prompt_mgr = prompt_manager or PromptManager()
        self.conn_mgr = connection_manager
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
        # Pre-create the report file so agents can write to it immediately
        if self.report_mgr is not None:
            self.report_mgr.pre_create(session_id, task.request_id)

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
        """Mark task complete, persist to disk, mark agent idle, re-assign."""
        task = self.task_mgr.mark_completed(request_id, status)
        if task is None:
            return

        # Persist completed task to database
        if self.session_mgr is not None:
            try:
                await self.session_mgr.persist_task(session_id, task)
            except Exception:
                logger.exception(
                    "task.persist_failed",
                    request_id=request_id,
                    session_id=session_id,
                )

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
        project_root: str | None = None,
    ) -> Any | None:
        """Spawn a new agent: create worktree, then start ACP session."""
        create = AgentCreate(role=role, session_id=session_id)
        agent = self.agent_mgr.create_agent(create)

        # Create worktree for agent isolation
        wt_info = None
        if project_root is not None:
            try:
                wt_info = await self.worktree_mgr.create_worktree(
                    agent.worktree_name or agent.id, project_root,
                )
                agent.worktree_path = wt_info.path
                agent.worktree_name = wt_info.name
            except Exception:
                logger.exception("worktree.create_failed", agent_id=agent.id)
                self.agent_mgr.dismiss_agent(agent.id)
                return None

        work_dir = wt_info.path if wt_info else (
            f"{self.settings.worktree_subdir}/{agent.worktree_name}"
        )

        # Build role-specific system prompt
        system_prompt = self.prompt_mgr.get_prompt_for_role(role)

        # Build isolation command prefix (bwrap / devcontainer)
        command_prefix = build_command_prefix(
            role=str(role.value),
            worktree_path=agent.worktree_path,
            project_root=project_root,
            linuxbrew_path=self.settings.linuxbrew_path,
        )

        # Build notification callback to broadcast agent output to WS clients
        on_notification = None
        if self.conn_mgr is not None:
            _conn_mgr = self.conn_mgr
            _agent_id = agent.id
            _session_id = session_id

            def on_notification(notification: dict[str, Any]) -> None:
                method = notification.get("method", "")
                params = notification.get("params", {})
                asyncio.ensure_future(_conn_mgr.broadcast(_session_id, {
                    "jsonrpc": "2.0",
                    "method": f"agent/{method}",
                    "params": {"agent_id": _agent_id, **params},
                }))

        # Build ordered list of models to try (primary + fallbacks).
        models_to_try = [model]
        if model and model in self.settings.model_fallback_chains:
            models_to_try.extend(self.settings.model_fallback_chains[model])

        actual_model: str | None = None
        for candidate_model in models_to_try:
            try:
                await self.acp_mgr.create_session(
                    agent_id=agent.id,
                    work_dir=work_dir,
                    model=candidate_model,
                    system_prompt=system_prompt,
                    on_notification=on_notification,
                    command_prefix=command_prefix,
                )
                actual_model = candidate_model
                break
            except RuntimeError as e:
                if not is_retryable_error(str(e)):
                    raise
                logger.warning(
                    "model.fallback",
                    agent_id=agent.id,
                    failed_model=candidate_model,
                    error=str(e),
                )
                continue
            except Exception:
                raise  # non-retryable errors fail immediately
        else:
            # for/else: all candidates exhausted without a successful break
            logger.error(
                "agent.spawn_failed_all_models",
                agent_id=agent.id,
                models_tried=models_to_try,
            )
            if wt_info is not None:
                await self.worktree_mgr.remove_worktree(wt_info.path)
            self.agent_mgr.dismiss_agent(agent.id)
            return None

        agent.model = actual_model
        self.agent_mgr.mark_init_finished(agent.id)
        logger.info("agent.spawned", agent_id=agent.id, role=str(role), model=actual_model)
        return agent

    async def dismiss_agent(self, agent_id: str, force: bool = False) -> bool:
        """Dismiss an agent: stop ACP session, remove worktree, unregister."""
        agent = self.agent_mgr.get_agent(agent_id)
        if agent is None:
            return False

        allowed, reason = self.agent_mgr.can_dismiss(agent_id, force)
        if not allowed:
            logger.warning("agent.dismiss_denied", agent_id=agent_id, reason=reason)
            return False

        # Stop ACP session first
        acp_session = self.acp_mgr.get_session(agent_id)
        if acp_session is not None:
            try:
                await acp_session.stop()
            except Exception:
                logger.exception("acp.stop_failed", agent_id=agent_id)

        # Remove worktree
        if agent.worktree_path:
            await self.worktree_mgr.remove_worktree(agent.worktree_path)

        self.agent_mgr.dismiss_agent(agent_id)
        logger.info("agent.dismissed", agent_id=agent_id)
        return True

    async def cleanup_session(self, session_id: str, project_root: str) -> None:
        """Clean up all agents and worktrees for a session."""
        agents = self.agent_mgr.get_session_agents(session_id)
        for agent in agents:
            await self.dismiss_agent(agent.id, force=True)

        # Final worktree prune
        await self.worktree_mgr.cleanup_all(project_root)
