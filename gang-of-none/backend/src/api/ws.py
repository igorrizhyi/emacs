"""WebSocket endpoint — JSON-RPC 2.0 transport for client connections."""

from __future__ import annotations

import json
from typing import Any

import structlog
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from .connection_manager import ConnectionManager
from .rpc_router import RPCRouter
from ..core.agent_manager import AgentManager
from ..core.approval_manager import ApprovalManager
from ..core.namespace_manager import NamespaceManager
from ..core.task_manager import TaskManager
from ..models.enums import AgentRole, ApprovalType, TaskStatus
from ..models.task import TaskCreate, TaskUpdate

logger = structlog.get_logger()

router = APIRouter()

def _get_managers(ws: WebSocket) -> tuple[ConnectionManager, AgentManager, TaskManager]:
    """Retrieve managers from app state (set during lifespan)."""
    app = ws.app
    return app.state.connection_manager, app.state.agent_manager, app.state.task_manager


def _get_orchestrator(ws: WebSocket):
    """Retrieve orchestrator from app state."""
    return ws.app.state.orchestrator


def _get_approval_manager(ws: WebSocket) -> ApprovalManager:
    """Retrieve approval manager from app state."""
    return ws.app.state.approval_manager


def _get_namespace_manager(ws: WebSocket) -> NamespaceManager | None:
    """Retrieve namespace manager from app state."""
    return getattr(ws.app.state, "namespace_manager", None)


def build_rpc_router(
    session_id: str,
    websocket: WebSocket,
) -> RPCRouter:
    """Build a JSON-RPC router with all method handlers bound to the session."""
    rpc = RPCRouter()

    async def handle_tasks_put(params: dict[str, Any]) -> dict[str, Any]:
        conn_mgr, agent_mgr, task_mgr = _get_managers(websocket)
        orchestrator = _get_orchestrator(websocket)
        raw_tasks = params.get("tasks", [])
        creates = [TaskCreate(**t) for t in raw_tasks]
        tasks = task_mgr.enqueue_tasks(creates, session_id)
        # Trigger assignment loop
        if orchestrator is not None:
            await orchestrator.try_assign_tasks(session_id)
        return {"success": True, "count": len(tasks)}

    async def handle_task_update(params: dict[str, Any]) -> dict[str, Any]:
        conn_mgr, agent_mgr, task_mgr = _get_managers(websocket)
        orchestrator = _get_orchestrator(websocket)
        update = TaskUpdate(**params)
        task = task_mgr.handle_task_update(update)
        if task is None:
            return {"success": False, "message": f"No active task for request_id={update.request_id}"}

        # Broadcast status change
        await conn_mgr.broadcast(session_id, {
            "jsonrpc": "2.0",
            "method": "task/statusChanged",
            "params": {
                "request_id": update.request_id,
                "status": str(task.status),
                "content": update.content,
                "commit": update.commit,
            },
        })

        # If terminal, mark agent idle and check group completion
        if task.status in (TaskStatus.FINISHED, TaskStatus.BLOCKED):
            agent = agent_mgr.get_agent_for_request(update.request_id)
            if agent is not None:
                agent_mgr.mark_idle(agent.id)

            if task.group_id and task_mgr.check_group_complete(task.group_id):
                group = task_mgr.get_group_report(task.group_id)
                await conn_mgr.broadcast(session_id, {
                    "jsonrpc": "2.0",
                    "method": "task/groupComplete",
                    "params": {
                        "group_id": task.group_id,
                        "completed": group.completed if group else [],
                    },
                })

            # Trigger re-assignment
            if orchestrator is not None:
                await orchestrator.try_assign_tasks(session_id)

        return {"success": True}

    async def handle_dismiss_agent(params: dict[str, Any]) -> dict[str, Any]:
        conn_mgr, agent_mgr, task_mgr = _get_managers(websocket)
        target = params.get("target", "")
        force = params.get("force", False)

        agent = agent_mgr.find_agent_by_name(target)
        if agent is None:
            return {"success": False, "message": f"Agent not found: {target}"}

        allowed, reason = agent_mgr.can_dismiss(agent.id, force=force)
        if not allowed:
            return {"success": False, "message": reason}

        # Stop ACP session if running
        acp_mgr = websocket.app.state.acp_session_manager
        await acp_mgr.destroy_session(agent.id)

        agent_mgr.dismiss_agent(agent.id)
        return {"success": True, "message": f"Agent {agent.id} dismissed"}

    async def handle_send_notification(params: dict[str, Any]) -> dict[str, Any]:
        conn_mgr, _, _ = _get_managers(websocket)
        title = params.get("title", "")
        message = params.get("message", "")
        await conn_mgr.broadcast(session_id, {
            "jsonrpc": "2.0",
            "method": "notification",
            "params": {"title": title, "message": message},
        })
        return {"success": True}

    async def handle_present_options(params: dict[str, Any]) -> dict[str, Any]:
        conn_mgr, _, _ = _get_managers(websocket)
        approval_mgr = _get_approval_manager(websocket)
        request_id = params.get("request_id", "")
        title = params.get("title", "")
        approval_type = params.get("type", ApprovalType.CHECKLIST)
        items = params.get("items", [])
        description = params.get("description")

        approval_mgr.create_request(
            request_id=request_id,
            title=title,
            type=approval_type,
            items=items,
            description=description,
            session_id=session_id,
        )

        await conn_mgr.broadcast(session_id, {
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

    async def handle_submit_approval(params: dict[str, Any]) -> dict[str, Any]:
        approval_mgr = _get_approval_manager(websocket)
        request_id = params.get("request_id", "")
        selected_items = params.get("selected_items", [])
        refine = params.get("refine")
        notes = params.get("notes")

        approval = approval_mgr.get_approval(request_id)
        if approval is None:
            return {"success": False, "message": f"Approval {request_id} not found"}

        approval_mgr.submit(
            request_id,
            selected_items=selected_items,
            refine=refine,
            notes=notes,
        )
        return {"success": True, "message": f"Approval {request_id} submitted"}

    async def handle_dismiss_approval(params: dict[str, Any]) -> dict[str, Any]:
        approval_mgr = _get_approval_manager(websocket)
        request_id = params.get("request_id", "")

        approval = approval_mgr.get_approval(request_id)
        if approval is None:
            return {"success": False, "message": f"Approval {request_id} not found"}

        approval_mgr.dismiss(request_id)
        return {"success": True, "message": f"Approval {request_id} dismissed"}

    async def handle_list_pending_reviews(params: dict[str, Any]) -> dict[str, Any]:
        approval_mgr = _get_approval_manager(websocket)
        pending = approval_mgr.list_pending(session_id=session_id)
        pending_ids = [r.request_id for r in pending]
        return {"success": True, "pending": pending_ids, "count": len(pending_ids)}

    async def handle_message_namespace_peer(params: dict[str, Any]) -> dict[str, Any]:
        conn_mgr, _, _ = _get_managers(websocket)
        ns_mgr = _get_namespace_manager(websocket)
        target_pid = params.get("target_pid")
        message = params.get("message", "")

        if ns_mgr is not None:
            # Use file-based IPC for cross-instance messaging
            ns_mgr.send_to_peer(target_pid, message)
            return {"success": True}

        # Fallback: try to deliver via WebSocket if peer is in this instance
        return {"success": False, "message": f"Peer with pid={target_pid} not found"}

    async def handle_prompt_agent(params: dict[str, Any]) -> dict[str, Any]:
        conn_mgr, agent_mgr, _ = _get_managers(websocket)
        acp_mgr = websocket.app.state.acp_session_manager
        agent_id = params.get("agent_id", "")
        message = params.get("message", "")

        if not agent_id or not message:
            return {"success": False, "message": "agent_id and message are required"}

        acp_session = acp_mgr.get_session(agent_id)
        if acp_session is None:
            return {"success": False, "message": f"No ACP session for agent {agent_id}"}

        agent_mgr.mark_busy(agent_id, "prompt-relay")

        try:
            response = await acp_session.prompt(message)
        except Exception as exc:
            agent_mgr.mark_idle(agent_id)
            return {"success": False, "message": f"Prompt failed: {exc}"}

        agent_mgr.mark_idle(agent_id)
        return {"success": True, "response": response}

    async def handle_cancel_agent(params: dict[str, Any]) -> dict[str, Any]:
        _, agent_mgr, _ = _get_managers(websocket)
        acp_mgr = websocket.app.state.acp_session_manager
        agent_id = params.get("agent_id", "")

        if not agent_id:
            return {"success": False, "message": "agent_id is required"}

        acp_session = acp_mgr.get_session(agent_id)
        if acp_session is None:
            return {"success": False, "message": f"No ACP session for agent {agent_id}"}

        await acp_session.cancel()
        agent_mgr.mark_idle(agent_id)
        return {"success": True}

    async def handle_list_namespace_peers(params: dict[str, Any]) -> dict[str, Any]:
        ns_mgr = _get_namespace_manager(websocket)
        if ns_mgr is not None:
            peers = ns_mgr.list_peers()
            return {
                "success": True,
                "peers": [
                    {"pid": p.pid, "hostname": p.hostname, "project_root": p.project_root}
                    for p in peers
                ],
                "count": len(peers),
            }
        return {"success": True, "peers": [], "count": 0}

    async def handle_spawn_agent(params: dict[str, Any]) -> dict[str, Any]:
        orchestrator = _get_orchestrator(websocket)
        if orchestrator is None:
            return {"success": False, "message": "Orchestrator not initialized"}

        role_str = params.get("role")
        if not role_str:
            return {"success": False, "message": "Missing required param: role"}
        try:
            role = AgentRole(role_str)
        except ValueError:
            return {"success": False, "message": f"Invalid role: {role_str}"}

        model = params.get("model")
        system_prompt = params.get("system_prompt")
        is_ephemeral = params.get("is_ephemeral", True)
        worktree_name = params.get("worktree_name")

        try:
            agent = await orchestrator.spawn_agent(
                session_id=session_id,
                role=role,
                model=model,
                system_prompt=system_prompt,
                is_ephemeral=is_ephemeral,
                worktree_name=worktree_name,
            )
        except Exception as exc:
            logger.exception("ws.spawn_agent_failed", session_id=session_id)
            return {"success": False, "message": str(exc)}

        if agent is None:
            return {"success": False, "message": "Agent spawn failed (all models exhausted or worktree error)"}

        conn_mgr, _, _ = _get_managers(websocket)
        await conn_mgr.broadcast(session_id, {
            "jsonrpc": "2.0",
            "method": "agent/spawned",
            "params": {
                "agent_id": agent.id,
                "role": str(agent.role),
                "worktree_name": agent.worktree_name,
                "worktree_path": agent.worktree_path,
                "status": str(agent.status),
            },
        })

        return {
            "success": True,
            "agent_id": agent.id,
            "role": str(agent.role),
            "worktree_name": agent.worktree_name,
            "worktree_path": agent.worktree_path,
            "status": str(agent.status),
        }

    rpc.register("spawnAgent", handle_spawn_agent)
    rpc.register("tasksPut", handle_tasks_put)
    rpc.register("taskUpdate", handle_task_update)
    rpc.register("dismissAgent", handle_dismiss_agent)
    rpc.register("sendNotification", handle_send_notification)
    rpc.register("presentOptions", handle_present_options)
    rpc.register("submitApproval", handle_submit_approval)
    rpc.register("dismissApproval", handle_dismiss_approval)
    rpc.register("listPendingReviews", handle_list_pending_reviews)
    rpc.register("promptAgent", handle_prompt_agent)
    rpc.register("cancelAgent", handle_cancel_agent)
    rpc.register("messageNamespacePeer", handle_message_namespace_peer)
    rpc.register("listNamespacePeers", handle_list_namespace_peers)

    return rpc


def register_peer(session_id: str, peer_info: dict[str, Any], ns_mgr: NamespaceManager | None = None) -> None:
    """Register peer info for namespace peer discovery."""
    if ns_mgr is not None:
        from ..models.namespace import Peer
        from datetime import datetime, timezone
        peer = Peer(
            pid=peer_info.get("pid", 0),
            hostname=peer_info.get("hostname", ""),
            project_root=peer_info.get("project_root", ""),
            namespace=peer_info.get("namespace", ""),
            connected_at=datetime.now(timezone.utc),
        )
        ns_mgr.register_peer(session_id, peer)


def unregister_peer(session_id: str, ns_mgr: NamespaceManager | None = None) -> None:
    """Remove peer info on disconnect."""
    if ns_mgr is not None:
        ns_mgr.unregister_peer(session_id)


def resolve_approval(request_id: str, approval_mgr: ApprovalManager) -> bool:
    """Dismiss a pending approval via the manager. Returns True if it existed."""
    return approval_mgr.dismiss(request_id)


@router.websocket("/ws/{session_id}")
async def websocket_endpoint(websocket: WebSocket, session_id: str) -> None:
    """Main WebSocket endpoint — JSON-RPC 2.0 message loop."""
    conn_mgr: ConnectionManager = websocket.app.state.connection_manager
    await conn_mgr.connect(session_id, websocket)

    rpc = build_rpc_router(session_id, websocket)

    try:
        while True:
            text = await websocket.receive_text()
            try:
                raw = json.loads(text)
            except json.JSONDecodeError:
                logger.warning("ws.invalid_json", session_id=session_id)
                continue

            response = await rpc.dispatch(raw)
            if response is not None:
                await conn_mgr.send_to(session_id, websocket, response)
    except WebSocketDisconnect:
        logger.info("ws.client_disconnected", session_id=session_id)
    except Exception:
        logger.exception("ws.error", session_id=session_id)
    finally:
        conn_mgr.disconnect(session_id, websocket)
        unregister_peer(session_id, _get_namespace_manager(websocket))
