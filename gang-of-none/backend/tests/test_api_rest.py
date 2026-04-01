import pytest
from fastapi import FastAPI
from unittest.mock import MagicMock, AsyncMock
from contextlib import asynccontextmanager
from datetime import datetime, timezone
import uuid

from src.main import app as main_app
from src.models.session import Session
from src.models.agent import Agent
from src.models.task import Task
from src.models.approval import ApprovalRequest as Approval
from src.models.enums import AgentRole, AgentStatus, TaskStatus, ApprovalType

# All test coroutines will be treated as marked.
pytestmark = pytest.mark.asyncio


@pytest.fixture
def test_app():
    """Create a FastAPI app instance with mocked state for testing."""
    app = FastAPI()

    # Apply the routers from the main app
    app.include_router(main_app.router)
    # The /health route is directly on the app
    @app.get("/health")
    async def health():
        return {"status": "ok"}


    @asynccontextmanager
    async def lifespan_override(app: FastAPI):
        # Mock managers
        app.state.agent_manager = MagicMock()
        app.state.task_manager = MagicMock()
        app.state.approval_manager = MagicMock()
        app.state.session_manager = MagicMock()
        app.state.orchestrator = MagicMock()

        # Mock session creation/destruction functions
        app.state.create_session = AsyncMock()
        app.state.destroy_session = AsyncMock()

        # Mock sessions dictionary
        app.state.sessions = {}
        yield

    app.router.lifespan_context = lifespan_override
    return app


from httpx import ASGITransport, AsyncClient

@pytest.fixture
async def client(test_app):
    transport = ASGITransport(app=test_app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


async def test_get_health(client: AsyncClient):
    response = await client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_list_sessions(client: AsyncClient, test_app):
    session_id = uuid.uuid4().hex[:8]
    session = Session(id=session_id, project_root="/tmp/test", created_at=datetime.now(timezone.utc))
    
    # We need to ensure state is initialized before adding stuff to it
    # Since lifespan is not automatically run for tests unless using TestClient or explicit lifespan call
    # In FastAPI with AsyncClient, it is usually better to use it directly
    test_app.state.sessions = {session_id: session}
    test_app.state.agent_manager = MagicMock()
    test_app.state.agent_manager.get_session_agents.return_value = []

    response = await client.get("/api/sessions")
    assert response.status_code == 200
    data = response.json()
    assert len(data["sessions"]) == 1
    assert data["sessions"][0]["id"] == session_id
    assert data["sessions"][0]["agent_count"] == 0


async def test_create_session(client: AsyncClient, test_app):
    project_root = "/tmp/new_project"
    session_id = uuid.uuid4().hex[:8]
    now = datetime.now(timezone.utc)
    
    # Mock the return value of the create_session function
    created_session = Session(id=session_id, project_root=project_root, created_at=now)
    test_app.state.create_session = AsyncMock(return_value=created_session)

    response = await client.post("/api/sessions", json={"project_root": project_root})
    
    assert response.status_code == 201
    data = response.json()
    assert data["id"] == session_id
    assert data["project_root"] == project_root
    assert "created_at" in data
    
    # Check that the factory was called
    test_app.state.create_session.assert_called_once_with(project_root)


async def test_list_agents(client: AsyncClient, test_app):
    session_id = uuid.uuid4().hex[:8]
    agent1 = Agent(id="a1", session_id=session_id, role=AgentRole.DEV, status=AgentStatus.IDLE, created_at=datetime.now(timezone.utc))
    agent2 = Agent(id="a2", session_id=session_id, role=AgentRole.TESTER, status=AgentStatus.IDLE, created_at=datetime.now(timezone.utc))
    
    test_app.state.agent_manager = MagicMock()
    test_app.state.agent_manager.get_session_agents.return_value = [agent1, agent2]

    # No filter
    response = await client.get(f"/api/sessions/{session_id}/agents")
    assert response.status_code == 200
    assert len(response.json()["agents"]) == 2

    # Filter by role
    response = await client.get(f"/api/sessions/{session_id}/agents?role=dev")
    assert response.status_code == 200
    data = response.json()
    assert len(data["agents"]) == 1
    assert data["agents"][0]["id"] == "a1"


async def test_list_tasks_with_filters(client: AsyncClient, test_app):
    session_id = uuid.uuid4().hex[:8]
    task1 = Task(id="1", request_id="req1", session_id=session_id, role=AgentRole.DEV, status=TaskStatus.PENDING, message="a")
    task2 = Task(id="2", request_id="req2", session_id=session_id, role=AgentRole.TESTER, status=TaskStatus.FINISHED, message="b")
    
    test_app.state.task_manager = MagicMock()
    test_app.state.task_manager.get_session_tasks.return_value = [task1, task2]

    # No filter
    response = await client.get(f"/api/sessions/{session_id}/tasks")
    assert response.status_code == 200
    assert len(response.json()["tasks"]) == 2

    # Filter by status
    response = await client.get(f"/api/sessions/{session_id}/tasks?status=pending")
    assert response.status_code == 200
    data = response.json()
    assert len(data["tasks"]) == 1
    assert data["tasks"][0]["request_id"] == "req1"

    # Filter by role
    response = await client.get(f"/api/sessions/{session_id}/tasks?role=tester")
    assert response.status_code == 200
    data = response.json()
    assert len(data["tasks"]) == 1
    assert data["tasks"][0]["request_id"] == "req2"


async def test_create_task(client: AsyncClient, test_app):
    session_id = uuid.uuid4().hex[:8]
    task_data = {
        "role": "dev",
        "message": "Write a feature",
        "priority": "normal"
    }
    
    # Mock task_manager.enqueue_tasks
    created_task = Task(
        id="task-123",
        request_id="req-123",
        session_id=session_id,
        role=AgentRole.DEV,
        message="Write a feature",
        status=TaskStatus.PENDING,
    )
    test_app.state.task_manager = MagicMock()
    test_app.state.task_manager.enqueue_tasks.return_value = [created_task]
    test_app.state.orchestrator = AsyncMock()

    response = await client.post(f"/api/sessions/{session_id}/tasks", json=task_data)
    
    assert response.status_code == 201
    data = response.json()
    assert data["tasks"][0]["request_id"] == "req-123"
    assert data["tasks"][0]["message"] == "Write a feature"
    
    # Check that orchestrator was triggered
    test_app.state.orchestrator.try_assign_tasks.assert_called_once_with(session_id)


async def test_list_pending_approvals(client: AsyncClient, test_app):
    request_id = uuid.uuid4().hex
    approval_request = Approval(
        request_id=request_id,
        title="Confirm changes",
        type=ApprovalType.CHECKLIST,
        items=[],
        session_id="test_session",
        created_at=datetime.now(timezone.utc),
    )
    test_app.state.approval_manager = MagicMock()
    test_app.state.approval_manager.list_pending.return_value = [approval_request]

    response = await client.get("/api/approvals")
    assert response.status_code == 200
    data = response.json()
    assert len(data["approvals"]) == 1
    assert data["approvals"][0]["request_id"] == request_id
    assert data["approvals"][0]["title"] == "Confirm changes"

