"""REST API routes for querying and mutating server state."""

from __future__ import annotations

from typing import TYPE_CHECKING

from fastapi import APIRouter, HTTPException, Query, Request

from .schemas import (
    AgentListResponse,
    AgentResponse,
    ApprovalListResponse,
    ApprovalResponse,
    ApprovalSubmitRequest,
    GroupResponse,
    PeerListResponse,
    PeerMessageRequest,
    PeerResponse,
    ReportResponse,
    SessionCreateRequest,
    SessionListResponse,
    SessionResponse,
    SuccessResponse,
    TaskCreateRequest,
    TaskListResponse,
    TaskResponse,
)
from ..models.enums import AgentRole, TaskStatus
from ..models.task import TaskCreate

if TYPE_CHECKING:
    from ..core.agent_manager import AgentManager

router = APIRouter(prefix="/api")


# ── Helpers ────────────────────────────────────────────────────────────

def _get_agent_manager(request: Request) -> AgentManager:
    mgr = getattr(request.app.state, "agent_manager", None)
    if mgr is None:
        raise HTTPException(503, "Agent manager not initialized")
    return mgr


def _agent_to_response(agent) -> AgentResponse:
    return AgentResponse(**agent.model_dump())


# ── Sessions ───────────────────────────────────────────────────────────

@router.get("/sessions", response_model=SessionListResponse)
async def list_sessions(request: Request):
    mgr = _get_agent_manager(request)
    sessions_map = getattr(request.app.state, "sessions", {})
    result = []
    for sid, session in sessions_map.items():
        agents = mgr.get_session_agents(sid)
        result.append(SessionResponse(
            id=session.id,
            project_root=session.project_root,
            created_at=session.created_at,
            agent_count=len(agents),
        ))
    return SessionListResponse(sessions=result)


@router.get("/sessions/{session_id}", response_model=SessionResponse)
async def get_session(session_id: str, request: Request):
    mgr = _get_agent_manager(request)
    sessions_map = getattr(request.app.state, "sessions", {})
    session = sessions_map.get(session_id)
    if session is None:
        raise HTTPException(404, f"Session {session_id} not found")
    agents = mgr.get_session_agents(session_id)
    return SessionResponse(
        id=session.id,
        project_root=session.project_root,
        created_at=session.created_at,
        agent_count=len(agents),
        agents=[_agent_to_response(a) for a in agents],
    )


@router.post("/sessions", response_model=SessionResponse, status_code=201)
async def create_session(body: SessionCreateRequest, request: Request):
    session_factory = getattr(request.app.state, "create_session", None)
    if session_factory is None:
        raise HTTPException(503, "Session creation not available")
    session = await session_factory(body.project_root)
    return SessionResponse(
        id=session.id,
        project_root=session.project_root,
        created_at=session.created_at,
        agent_count=0,
    )


@router.delete("/sessions/{session_id}", response_model=SuccessResponse)
async def delete_session(session_id: str, request: Request):
    destroy_fn = getattr(request.app.state, "destroy_session", None)
    if destroy_fn is None:
        raise HTTPException(503, "Session destruction not available")
    sessions_map = getattr(request.app.state, "sessions", {})
    if session_id not in sessions_map:
        raise HTTPException(404, f"Session {session_id} not found")
    await destroy_fn(session_id)
    return SuccessResponse(success=True, message=f"Session {session_id} destroyed")


# ── Agents ─────────────────────────────────────────────────────────────

@router.get("/sessions/{session_id}/agents", response_model=AgentListResponse)
async def list_session_agents(
    session_id: str,
    request: Request,
    role: AgentRole | None = Query(None),
):
    mgr = _get_agent_manager(request)
    agents = mgr.get_session_agents(session_id)
    if role is not None:
        agents = [a for a in agents if a.role == role]
    return AgentListResponse(agents=[_agent_to_response(a) for a in agents])


@router.get("/agents/{agent_id}", response_model=AgentResponse)
async def get_agent(agent_id: str, request: Request):
    mgr = _get_agent_manager(request)
    agent = mgr.get_agent(agent_id)
    if agent is None:
        raise HTTPException(404, f"Agent {agent_id} not found")
    return _agent_to_response(agent)


@router.post("/agents/{agent_id}/reserve", response_model=AgentResponse)
async def toggle_reserve(agent_id: str, request: Request):
    mgr = _get_agent_manager(request)
    agent = mgr.get_agent(agent_id)
    if agent is None:
        raise HTTPException(404, f"Agent {agent_id} not found")
    mgr.set_reserved(agent_id, not agent.reserved)
    agent = mgr.get_agent(agent_id)
    return _agent_to_response(agent)


@router.post("/agents/{agent_id}/cancel", response_model=SuccessResponse)
async def cancel_agent_task(agent_id: str, request: Request):
    mgr = _get_agent_manager(request)
    agent = mgr.get_agent(agent_id)
    if agent is None:
        raise HTTPException(404, f"Agent {agent_id} not found")
    session_mgr = getattr(request.app.state, "acp_session_manager", None)
    if session_mgr:
        acp_session = session_mgr.get_session(agent_id)
        if acp_session:
            await acp_session.cancel()
    return SuccessResponse(success=True, message=f"Cancel sent to agent {agent_id}")


# ── Tasks ──────────────────────────────────────────────────────────────

@router.get("/sessions/{session_id}/tasks", response_model=TaskListResponse)
async def list_session_tasks(
    session_id: str,
    request: Request,
    status: TaskStatus | None = Query(None),
    role: AgentRole | None = Query(None),
):
    task_mgr = getattr(request.app.state, "task_manager", None)
    if task_mgr is None:
        raise HTTPException(503, "Task manager not initialized")
    tasks = task_mgr.get_session_tasks(session_id)
    if status is not None:
        tasks = [t for t in tasks if t.status == status]
    if role is not None:
        tasks = [t for t in tasks if t.role == role]
    return TaskListResponse(tasks=[TaskResponse(**t.model_dump()) for t in tasks])


@router.post(
    "/sessions/{session_id}/tasks",
    response_model=TaskListResponse,
    status_code=201,
)
async def create_task(session_id: str, body: TaskCreateRequest, request: Request):
    task_mgr = getattr(request.app.state, "task_manager", None)
    if task_mgr is None:
        raise HTTPException(503, "Task manager not initialized")
    tc = TaskCreate(
        role=body.role,
        message=body.message,
        priority=body.priority,
        group_id=body.group_id,
        target=body.target,
        model=body.model,
    )
    tasks = task_mgr.enqueue_tasks(tasks=[tc], session_id=session_id)
    orchestrator = getattr(request.app.state, "orchestrator", None)
    if orchestrator is not None:
        await orchestrator.try_assign_tasks(session_id)
    return TaskListResponse(tasks=[TaskResponse(**t.model_dump()) for t in tasks])


@router.get("/tasks/{request_id}", response_model=TaskResponse)
async def get_task(request_id: str, request: Request):
    task_mgr = getattr(request.app.state, "task_manager", None)
    if task_mgr is None:
        raise HTTPException(503, "Task manager not initialized")
    task = task_mgr.get_task(request_id)
    if task is None:
        raise HTTPException(404, f"Task {request_id} not found")
    return TaskResponse(**task.model_dump())


@router.get("/groups/{group_id}", response_model=GroupResponse)
async def get_group(group_id: str, request: Request):
    task_mgr = getattr(request.app.state, "task_manager", None)
    if task_mgr is None:
        raise HTTPException(503, "Task manager not initialized")
    group = task_mgr.get_group(group_id)
    if group is None:
        raise HTTPException(404, f"Group {group_id} not found")
    tasks = []
    for tid in group.pending + group.completed:
        t = task_mgr.get_task(tid)
        if t:
            tasks.append(TaskResponse(**t.model_dump()))
    return GroupResponse(
        group_id=group.group_id,
        session_id=group.session_id,
        pending=group.pending,
        completed=group.completed,
        tasks=tasks,
    )


# ── Approvals ──────────────────────────────────────────────────────────

@router.get("/approvals", response_model=ApprovalListResponse)
async def list_approvals(request: Request):
    approval_mgr = getattr(request.app.state, "approval_manager", None)
    if approval_mgr is None:
        raise HTTPException(503, "Approval manager not initialized")
    approvals = approval_mgr.list_pending()
    return ApprovalListResponse(
        approvals=[ApprovalResponse(**a.model_dump()) for a in approvals],
    )


@router.get("/approvals/{request_id}", response_model=ApprovalResponse)
async def get_approval(request_id: str, request: Request):
    approval_mgr = getattr(request.app.state, "approval_manager", None)
    if approval_mgr is None:
        raise HTTPException(503, "Approval manager not initialized")
    approval = approval_mgr.get_approval(request_id)
    if approval is None:
        raise HTTPException(404, f"Approval {request_id} not found")
    return ApprovalResponse(**approval.model_dump())


@router.post("/approvals/{request_id}/submit", response_model=SuccessResponse)
async def submit_approval(
    request_id: str,
    body: ApprovalSubmitRequest,
    request: Request,
):
    approval_mgr = getattr(request.app.state, "approval_manager", None)
    if approval_mgr is None:
        raise HTTPException(503, "Approval manager not initialized")
    approval = approval_mgr.get_approval(request_id)
    if approval is None:
        raise HTTPException(404, f"Approval {request_id} not found")
    approval_mgr.submit(
        request_id,
        selected_items=body.selected_items,
        refine=body.refine,
        notes=body.notes,
    )
    return SuccessResponse(success=True, message=f"Approval {request_id} submitted")


@router.delete("/approvals/{request_id}", response_model=SuccessResponse)
async def dismiss_approval(request_id: str, request: Request):
    approval_mgr = getattr(request.app.state, "approval_manager", None)
    if approval_mgr is None:
        raise HTTPException(503, "Approval manager not initialized")
    approval = approval_mgr.get_approval(request_id)
    if approval is None:
        raise HTTPException(404, f"Approval {request_id} not found")
    approval_mgr.dismiss(request_id)
    return SuccessResponse(success=True, message=f"Approval {request_id} dismissed")


# ── Namespace ──────────────────────────────────────────────────────────

@router.get("/namespace")
async def get_namespace(request: Request):
    ns = getattr(request.app.state, "namespace_config", None)
    if ns is None:
        raise HTTPException(503, "Namespace not configured")
    return ns.model_dump()


@router.get("/namespace/peers", response_model=PeerListResponse)
async def list_peers(request: Request):
    ns_mgr = getattr(request.app.state, "namespace_manager", None)
    if ns_mgr is None:
        raise HTTPException(503, "Namespace manager not initialized")
    peers = ns_mgr.list_peers()
    return PeerListResponse(
        peers=[PeerResponse(**p.model_dump()) for p in peers],
    )


@router.post("/namespace/peers/{pid}/message", response_model=SuccessResponse)
async def message_peer(pid: int, body: PeerMessageRequest, request: Request):
    ns_mgr = getattr(request.app.state, "namespace_manager", None)
    if ns_mgr is None:
        raise HTTPException(503, "Namespace manager not initialized")
    await ns_mgr.send_message(pid, body.message)
    return SuccessResponse(success=True, message=f"Message sent to peer {pid}")


# ── Reports ────────────────────────────────────────────────────────────

@router.get("/reports/{session_id}/{request_id}", response_model=ReportResponse)
async def get_report(session_id: str, request_id: str, request: Request):
    report_mgr = getattr(request.app.state, "report_manager", None)
    if report_mgr is None:
        raise HTTPException(503, "Report manager not initialized")
    content = report_mgr.read_report(session_id, request_id)
    if content is None:
        raise HTTPException(404, f"Report not found: {request_id}")
    return ReportResponse(request_id=request_id, content=content)
