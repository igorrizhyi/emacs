"""WebSocket endpoint — JSON-RPC 2.0 transport for client connections."""

from __future__ import annotations

import json
from typing import Any

import structlog
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from gang_of_none.api.connection_manager import ConnectionManager
from gang_of_none.api.rpc_router import RPCRouter
from gang_of_none.core.agent_manager import AgentManager
from gang_of_none.core.namespace_manager import NamespaceManager
from gang_of_none.core.task_manager import TaskManager
from gang_of_none.models.enums import ApprovalType, TaskStatus
from gang_of_none.models.task import TaskCreate, TaskUpdate

logger = structlog.get_logger()

router = APIRouter()

# Pending approval requests: request_id → approval data
_pending_approvals: dict[str, dict[str, Any]] = {}

def _get_managers(ws: WebSocket) -> tuple[ConnectionManager, AgentManager, TaskManager]:
    """Retrieve managers from app state (set during lifespan)."""
    app = ws.app
    return app.state.connection_manager, app.state.agent_manager, app.state.task_manager


def _get_orchestrator(ws: WebSocket):
    """Retrieve orchestrator from app state."""
    return ws.app.state.orchestrator


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
        request_id = params.get("request_id", "")
        title = params.get("title", "")
        approval_type = params.get("type", ApprovalType.CHECKLIST)
        items = params.get("items", [])
        description = params.get("description")

        _pending_approvals[request_id] = {
            "request_id": request_id,
            "title": title,
            "type": approval_type,
            "items": items,
            "description": description,
            "session_id": session_id,
        }

        await conn_mgr.broadcast(session_id, {
            "jsonrpc": "2.0",
            "method": "approval/request",
            "params": _pending_approvals[request_id],
        })
        return {"success": True, "message": f"Options presented: {title}"}

    async def handle_list_pending_reviews(params: dict[str, Any]) -> dict[str, Any]:
        pending = [
            rid for rid, data in _pending_approvals.items()
            if data.get("session_id") == session_id
        ]
        return {"success": True, "pending": pending, "count": len(pending)}

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

    rpc.register("tasksPut", handle_tasks_put)
    rpc.register("taskUpdate", handle_task_update)
    rpc.register("dismissAgent", handle_dismiss_agent)
    rpc.register("sendNotification", handle_send_notification)
    rpc.register("presentOptions", handle_present_options)
    rpc.register("listPendingReviews", handle_list_pending_reviews)
    rpc.register("messageNamespacePeer", handle_message_namespace_peer)
    rpc.register("listNamespacePeers", handle_list_namespace_peers)

    return rpc


def register_peer(session_id: str, peer_info: dict[str, Any], ns_mgr: NamespaceManager | None = None) -> None:
    """Register peer info for namespace peer discovery."""
    if ns_mgr is not None:
        from gang_of_none.models.namespace import Peer
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


def resolve_approval(request_id: str) -> dict[str, Any] | None:
    """Remove and return a pending approval."""
    return _pending_approvals.pop(request_id, None)


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
