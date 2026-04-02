"""MCP Streamable HTTP server — exposes orchestration tools via MCP protocol."""

from __future__ import annotations

from typing import Any

import structlog
from mcp.server.fastmcp import FastMCP

from ..core.agent_manager import AgentManager
from ..core.approval_manager import ApprovalManager
from ..core.task_manager import TaskManager
from ..models.enums import ApprovalType, TaskStatus
from ..models.task import TaskCreate, TaskUpdate

logger = structlog.get_logger()


def create_mcp_server(
    *,
    task_manager: TaskManager,
    agent_manager: AgentManager,
    approval_manager: ApprovalManager,
    connection_manager: Any,
    orchestrator: Any,
    acp_session_manager: Any,
    session_id_resolver: Any = None,
) -> FastMCP:
    """Create and return a FastMCP server with orchestration tools.

    The returned server can be mounted on a FastAPI app via
    ``server.streamable_http_app()``.

    ``session_id_resolver`` is an optional callable that returns the current
    session ID.  When ``None``, tools that need a session will use a
    fixed default (useful for single-session deployments).
    """
    mcp = FastMCP(
        "gang-of-none",
        stateless_http=True,
        streamable_http_path="/",
    )

    def _session_id() -> str:
        if session_id_resolver is not None:
            return session_id_resolver()
        # Fallback: pick the first active session
        agents = list(agent_manager._agents.values())
        if agents:
            return agents[0].session_id
        return "default"

    # ── Tool definitions ──────────────────────────────────────────

    @mcp.tool(description="Submit tasks for assignment to dev/researcher/tester agents")
    async def tasksPut(tasks: list[dict[str, Any]]) -> dict[str, Any]:  # noqa: N802
        session_id = _session_id()
        creates = [TaskCreate(**t) for t in tasks]
        result = task_manager.enqueue_tasks(creates, session_id)
        if orchestrator is not None:
            await orchestrator.try_assign_tasks(session_id)
        return {"success": True, "count": len(result)}

    @mcp.tool(description="Push a task status update (finished/updated/blocked)")
    async def taskUpdate(  # noqa: N802
        request_id: str,
        status: str,
        content: str,
        commit: str | None = None,
        report_path: str | None = None,
    ) -> dict[str, Any]:
        session_id = _session_id()
        update = TaskUpdate(
            request_id=request_id,
            status=TaskStatus(status),
            content=content,
            commit=commit,
            report_path=report_path,
        )
        task = task_manager.handle_task_update(update)
        if task is None:
            return {"success": False, "message": f"No active task for request_id={request_id}"}

        # Broadcast status change
        await connection_manager.broadcast(session_id, {
            "jsonrpc": "2.0",
            "method": "task/statusChanged",
            "params": {
                "request_id": request_id,
                "status": str(task.status),
                "content": content,
                "commit": commit,
            },
        })

        if task.status in (TaskStatus.FINISHED, TaskStatus.BLOCKED):
            agent = agent_manager.get_agent_for_request(request_id)
            if agent is not None:
                agent_manager.mark_idle(agent.id)
            if task.group_id and task_manager.check_group_complete(task.group_id):
                group = task_manager.get_group_report(task.group_id)
                await connection_manager.broadcast(session_id, {
                    "jsonrpc": "2.0",
                    "method": "task/groupComplete",
                    "params": {
                        "group_id": task.group_id,
                        "completed": group.completed if group else [],
                    },
                })
            if orchestrator is not None:
                await orchestrator.try_assign_tasks(session_id)

        return {"success": True}

    @mcp.tool(description="Dismiss a team agent by name")
    async def dismissAgent(  # noqa: N802
        target: str,
        force: bool = False,
    ) -> dict[str, Any]:
        agent = agent_manager.find_agent_by_name(target)
        if agent is None:
            return {"success": False, "message": f"Agent not found: {target}"}
        allowed, reason = agent_manager.can_dismiss(agent.id, force=force)
        if not allowed:
            return {"success": False, "message": reason}
        await acp_session_manager.destroy_session(agent.id)
        agent_manager.dismiss_agent(agent.id)
        return {"success": True, "message": f"Agent {agent.id} dismissed"}

    @mcp.tool(description="Send a desktop notification")
    async def sendNotification(  # noqa: N802
        title: str,
        message: str,
    ) -> dict[str, Any]:
        session_id = _session_id()
        await connection_manager.broadcast(session_id, {
            "jsonrpc": "2.0",
            "method": "notification",
            "params": {"title": title, "message": message},
        })
        return {"success": True}

    @mcp.tool(description="Present approval/selection UI to the user")
    async def presentOptions(  # noqa: N802
        request_id: str,
        title: str,
        type: str = "checklist",
        items: list[dict[str, Any]] | None = None,
        description: str | None = None,
    ) -> dict[str, Any]:
        session_id = _session_id()
        approval_type = ApprovalType(type)
        items = items or []
        approval_manager.create_request(
            request_id=request_id,
            title=title,
            type=approval_type,
            items=items,
            description=description,
            session_id=session_id,
        )
        await connection_manager.broadcast(session_id, {
            "jsonrpc": "2.0",
            "method": "approval/request",
            "params": {
                "request_id": request_id,
                "title": title,
                "type": approval_type,
                "items": items,
                "description": description,
                "session_id": session_id,
            },
        })
        return {"success": True, "message": f"Options presented: {title}"}

    @mcp.tool(description="List pending review/approval files")
    async def listPendingReviews() -> dict[str, Any]:  # noqa: N802
        session_id = _session_id()
        pending = approval_manager.list_pending(session_id=session_id)
        pending_ids = [r.request_id for r in pending]
        return {"success": True, "pending": pending_ids, "count": len(pending_ids)}

    return mcp
