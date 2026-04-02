"""Integration tests — end-to-end flows with mocked ACP subprocess.

Tests the full request flow (REST → managers → orchestrator → ACP) using
a fake subprocess that responds to JSON-RPC messages over NDJSON stdio,
exactly as a real ACP agent would.
"""

from __future__ import annotations

import asyncio
import json
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, patch

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from src.api.connection_manager import ConnectionManager
from src.api.routes import router as rest_router
from src.api.ws import router as ws_router
from src.config import Settings
from src.core.acp_session import ACPSessionManager
from src.core.agent_manager import AgentManager
from src.core.approval_manager import ApprovalManager
from src.core.orchestrator import Orchestrator
from src.core.prompt_manager import PromptManager
from src.core.report_manager import ReportManager
from src.core.session_manager import SessionManager
from src.core.task_manager import TaskManager
from src.core.worktree_manager import WorktreeManager
from src.models.enums import AgentRole, AgentStatus, TaskStatus


# ── Fake ACP subprocess ──────────────────────────────────────────────


class _FakeStdout:
    """Async-readable queue simulating subprocess stdout (NDJSON stream)."""

    def __init__(self) -> None:
        self._queue: asyncio.Queue[bytes] = asyncio.Queue()

    async def read(self, _n: int) -> bytes:
        return await self._queue.get()

    def feed(self, data: bytes) -> None:
        self._queue.put_nowait(data)

    def feed_eof(self) -> None:
        self._queue.put_nowait(b"")


class _FakeStdin:
    """Writable buffer that auto-responds to JSON-RPC by feeding stdout."""

    def __init__(self, stdout: _FakeStdout, handler) -> None:
        self._stdout = stdout
        self._handler = handler
        self.history: list[dict] = []

    def write(self, data: bytes) -> None:
        line = data.decode().strip()
        if not line:
            return
        obj = json.loads(line)
        self.history.append(obj)
        response = self._handler(obj)
        if response is not None:
            self._stdout.feed((json.dumps(response) + "\n").encode())

    async def drain(self) -> None:
        pass


class FakeProcess:
    """Fake ``asyncio.subprocess.Process`` for ACP session testing."""

    def __init__(self, rpc_handler) -> None:
        self.stdout = _FakeStdout()
        self.stdin = _FakeStdin(self.stdout, rpc_handler)
        self.stderr = _FakeStdout()
        self.returncode: int | None = None
        self.pid = 99999

    def terminate(self) -> None:
        self.stdout.feed_eof()
        self.returncode = 0

    def kill(self) -> None:
        self.stdout.feed_eof()
        self.returncode = -9

    async def wait(self) -> int:
        return self.returncode or 0


def make_rpc_handler(*, fail_session_new: int = 0):
    """Create a JSON-RPC handler that simulates an ACP agent.

    Args:
        fail_session_new: number of ``session/new`` calls to reject with
            "No capacity available" before allowing success.
    """
    state = {"session_new_calls": 0}

    def handler(obj: dict) -> dict | None:
        method = obj.get("method")
        rid = obj.get("id")

        if rid is None:  # notification — no response
            return None

        if method == "initialize":
            return {
                "jsonrpc": "2.0",
                "id": rid,
                "result": {"protocolVersion": "0.1.0"},
            }

        if method == "session/new":
            state["session_new_calls"] += 1
            if state["session_new_calls"] <= fail_session_new:
                return {
                    "jsonrpc": "2.0",
                    "id": rid,
                    "error": {
                        "code": -1,
                        "message": "No capacity available",
                    },
                }
            return {
                "jsonrpc": "2.0",
                "id": rid,
                "result": {"sessionId": f"test-session-{rid}"},
            }

        if method == "session/prompt":
            return {
                "jsonrpc": "2.0",
                "id": rid,
                "result": {"content": "Task completed"},
            }

        # Catch-all success for unknown methods
        return {"jsonrpc": "2.0", "id": rid, "result": {}}

    return handler


# ── Fixtures ─────────────────────────────────────────────────────────

_TEST_SETTINGS = Settings(
    retry_backoff_seconds=[0.0, 0.0, 0.0],
    drain_interval_seconds=9999,
    acp_binary="fake-acp",
    reports_dir="/tmp/gon-test-reports",
    db_path=":memory:",
)


@pytest.fixture
def _fake_subprocess():
    """Patch ``asyncio.create_subprocess_exec`` with a default success handler.

    Returns a list of all FakeProcess instances created, for assertions.
    """
    processes: list[FakeProcess] = []

    async def factory(*args, **kwargs):
        proc = FakeProcess(make_rpc_handler())
        processes.append(proc)
        return proc

    with patch("asyncio.create_subprocess_exec", side_effect=factory):
        yield processes


def _build_app() -> FastAPI:
    """Create a bare FastAPI app with routers attached (no state yet)."""
    app = FastAPI()
    app.include_router(ws_router)
    app.include_router(rest_router)

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    return app


def _wire_managers(app: FastAPI, settings: Settings | None = None) -> None:
    """Attach real manager instances to ``app.state``."""
    settings = settings or _TEST_SETTINGS
    app.state.connection_manager = ConnectionManager()
    app.state.agent_manager = AgentManager(settings)
    app.state.task_manager = TaskManager(reports_dir=settings.reports_dir)
    app.state.acp_session_manager = ACPSessionManager(settings)
    app.state.worktree_manager = WorktreeManager(settings)
    app.state.report_manager = ReportManager(reports_dir=settings.reports_dir)
    app.state.approval_manager = ApprovalManager()
    app.state.session_manager = SessionManager(
        settings=settings,
        agent_manager=app.state.agent_manager,
        db=None,
    )
    app.state.prompt_manager = PromptManager()
    app.state.orchestrator = Orchestrator(
        settings=settings,
        task_manager=app.state.task_manager,
        agent_manager=app.state.agent_manager,
        acp_session_manager=app.state.acp_session_manager,
        worktree_manager=app.state.worktree_manager,
        report_manager=app.state.report_manager,
        session_manager=app.state.session_manager,
        prompt_manager=app.state.prompt_manager,
    )

    app.state.sessions = app.state.session_manager.list_sessions()

    async def _create_session(project_root: str):
        return app.state.session_manager.create_session(project_root)

    app.state.create_session = _create_session
    app.state.destroy_session = AsyncMock()
    app.state.namespace_manager = None
    app.state.namespace_config = None


@pytest.fixture
def integration_app(_fake_subprocess):
    """FastAPI app wired with real managers and a mocked ACP subprocess.

    httpx.ASGITransport does NOT trigger ASGI lifespan events, so we
    attach state eagerly instead of relying on a lifespan context.
    """
    app = _build_app()
    _wire_managers(app)
    return app


@pytest.fixture
async def client(integration_app):
    """Async HTTP client wired to the integration app."""
    transport = ASGITransport(app=integration_app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


# ── Helpers ──────────────────────────────────────────────────────────


async def _create_session_via_rest(client: AsyncClient) -> str:
    """POST a new session and return its ID."""
    resp = await client.post(
        "/api/sessions", json={"project_root": "/tmp/test-project"}
    )
    assert resp.status_code == 201
    return resp.json()["id"]


def _sort_ws_messages(messages: list[dict]) -> tuple[dict | None, dict | None]:
    """Separate a broadcast notification from an RPC response."""
    broadcast = next((m for m in messages if "method" in m), None)
    rpc_resp = next((m for m in messages if "id" in m and "result" in m), None)
    return broadcast, rpc_resp


# ═════════════════════════════════════════════════════════════════════
# Test 1: Session + Agent Spawn Flow
# ═════════════════════════════════════════════════════════════════════


async def test_session_creation_and_listing(client: AsyncClient):
    """Create a session via REST and verify it appears in GET /api/sessions."""
    session_id = await _create_session_via_rest(client)

    resp = await client.get("/api/sessions")
    assert resp.status_code == 200
    sessions = resp.json()["sessions"]
    assert any(s["id"] == session_id for s in sessions)


async def test_agent_spawn_via_task_submission(
    client: AsyncClient, integration_app, _fake_subprocess
):
    """Submit a task → orchestrator auto-spawns agent → agent goes idle → task assigned."""
    session_id = await _create_session_via_rest(client)

    # Submit a dev task — orchestrator should auto-spawn an agent
    resp = await client.post(
        f"/api/sessions/{session_id}/tasks",
        json={"role": "dev", "message": "Implement feature X"},
    )
    assert resp.status_code == 201
    tasks = resp.json()["tasks"]
    assert len(tasks) == 1
    request_id = tasks[0]["request_id"]

    # Verify that a subprocess was spawned
    assert len(_fake_subprocess) == 1, "Expected exactly one ACP subprocess"

    # Verify agent exists and is busy (task was assigned)
    resp = await client.get(f"/api/sessions/{session_id}/agents")
    assert resp.status_code == 200
    agents = resp.json()["agents"]
    assert len(agents) == 1
    agent = agents[0]
    assert agent["role"] == "dev"
    assert agent["status"] == "busy"
    assert agent["current_task_id"] == request_id

    # Verify the task transitioned to assigned
    resp = await client.get(f"/api/tasks/{request_id}")
    assert resp.status_code == 200
    assert resp.json()["status"] == "assigned"

    # Cleanup
    await integration_app.state.acp_session_manager.shutdown()


# ═════════════════════════════════════════════════════════════════════
# Test 2: Task Assignment Flow
# ═════════════════════════════════════════════════════════════════════


async def test_task_lifecycle_pending_to_completed(
    client: AsyncClient, integration_app, _fake_subprocess
):
    """Full task lifecycle: pending → assigned → completed."""
    session_id = await _create_session_via_rest(client)

    # Submit task — auto-spawns agent and assigns
    resp = await client.post(
        f"/api/sessions/{session_id}/tasks",
        json={"role": "dev", "message": "Write tests"},
    )
    assert resp.status_code == 201
    request_id = resp.json()["tasks"][0]["request_id"]

    # Verify: task is assigned
    resp = await client.get(f"/api/tasks/{request_id}")
    assert resp.status_code == 200
    assert resp.json()["status"] == "assigned"

    # Simulate agent completing the task via the orchestrator
    orchestrator = integration_app.state.orchestrator
    await orchestrator.handle_agent_completion(
        request_id, TaskStatus.FINISHED, session_id
    )

    # Verify: task is now finished
    task_mgr = integration_app.state.task_manager
    task = task_mgr.get_task(request_id)
    assert task is not None
    assert task.status == TaskStatus.FINISHED
    assert task.completed_at is not None

    # Verify: agent is back to idle
    agent_mgr = integration_app.state.agent_manager
    agents = agent_mgr.get_session_agents(session_id)
    assert len(agents) == 1
    assert agents[0].status == AgentStatus.IDLE

    # Cleanup
    await integration_app.state.acp_session_manager.shutdown()


async def test_second_task_reuses_idle_agent(
    client: AsyncClient, integration_app, _fake_subprocess
):
    """A second task should reuse the idle agent instead of spawning a new one."""
    session_id = await _create_session_via_rest(client)

    # First task — spawns agent
    resp = await client.post(
        f"/api/sessions/{session_id}/tasks",
        json={"role": "dev", "message": "Task A"},
    )
    first_request_id = resp.json()["tasks"][0]["request_id"]

    # Complete first task
    orchestrator = integration_app.state.orchestrator
    await orchestrator.handle_agent_completion(
        first_request_id, TaskStatus.FINISHED, session_id
    )

    # Second task — should reuse the now-idle agent
    resp = await client.post(
        f"/api/sessions/{session_id}/tasks",
        json={"role": "dev", "message": "Task B"},
    )
    assert resp.status_code == 201
    second_request_id = resp.json()["tasks"][0]["request_id"]

    # Still only one subprocess spawned
    assert len(_fake_subprocess) == 1

    # The same agent is now busy with the second task
    resp = await client.get(f"/api/sessions/{session_id}/agents")
    agents = resp.json()["agents"]
    assert len(agents) == 1
    assert agents[0]["status"] == "busy"
    assert agents[0]["current_task_id"] == second_request_id

    # Cleanup
    await integration_app.state.acp_session_manager.shutdown()


# ═════════════════════════════════════════════════════════════════════
# Test 3: Model Fallback Integration
# ═════════════════════════════════════════════════════════════════════


async def test_model_fallback_on_capacity_error(_fake_subprocess):
    """When first model fails with 'No capacity', orchestrator falls back to next model."""
    settings = Settings(
        retry_backoff_seconds=[0.0],  # 1 retry = 2 total attempts
        drain_interval_seconds=9999,
        acp_binary="fake-acp",
        reports_dir="/tmp/gon-test-reports",
        model_fallback_chains={"model-A": ["model-B"]},
    )

    agent_mgr = AgentManager(settings)
    task_mgr = TaskManager(reports_dir=settings.reports_dir)
    acp_session_mgr = ACPSessionManager(settings)
    worktree_mgr = WorktreeManager(settings)
    prompt_mgr = PromptManager()

    orchestrator = Orchestrator(
        settings=settings,
        task_manager=task_mgr,
        agent_manager=agent_mgr,
        acp_session_manager=acp_session_mgr,
        worktree_manager=worktree_mgr,
        prompt_manager=prompt_mgr,
    )

    # The first process always fails session/new (for model-A attempts).
    # The second process succeeds (for model-B).
    proc_fail = FakeProcess(make_rpc_handler(fail_session_new=999))
    proc_ok = FakeProcess(make_rpc_handler())
    calls: list[FakeProcess] = [proc_fail, proc_ok]

    async def fake_exec(*args, **kwargs):
        return calls.pop(0)

    with patch("asyncio.create_subprocess_exec", side_effect=fake_exec):
        agent = await orchestrator._spawn_agent(
            AgentRole.DEV, "test-session", model="model-A"
        )

    assert agent is not None, "Agent should have been spawned with fallback model"
    assert agent.model == "model-B"
    assert agent.status == AgentStatus.IDLE

    # Cleanup
    await acp_session_mgr.shutdown()


# ═════════════════════════════════════════════════════════════════════
# Test 4: WebSocket Notification Flow
# ═════════════════════════════════════════════════════════════════════


def test_websocket_notification_broadcast(_fake_subprocess):
    """Send a notification via WS JSON-RPC and verify the broadcast arrives."""
    from starlette.testclient import TestClient

    app = _build_app()

    @asynccontextmanager
    async def test_lifespan(app: FastAPI):
        _wire_managers(app)
        yield
        await app.state.acp_session_manager.shutdown()

    app.router.lifespan_context = test_lifespan

    with TestClient(app) as tc:
        # Create a session so the WS endpoint has valid state
        resp = tc.post("/api/sessions", json={"project_root": "/tmp/ws-test"})
        assert resp.status_code == 201
        session_id = resp.json()["id"]

        with tc.websocket_connect(f"/ws/{session_id}") as ws:
            # Send a sendNotification RPC call
            ws.send_json(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "sendNotification",
                    "params": {
                        "title": "Build Complete",
                        "message": "All tests passed",
                    },
                }
            )

            # Receive both messages (broadcast + RPC response) in any order
            msg1 = ws.receive_json()
            msg2 = ws.receive_json()
            broadcast, rpc_resp = _sort_ws_messages([msg1, msg2])

            assert broadcast is not None
            assert broadcast["method"] == "notification"
            assert broadcast["params"]["title"] == "Build Complete"
            assert broadcast["params"]["message"] == "All tests passed"

            assert rpc_resp is not None
            assert rpc_resp["id"] == 1
            assert rpc_resp["result"]["success"] is True


def test_websocket_task_status_broadcast(_fake_subprocess):
    """Submit a task via REST, update status via WS, verify broadcast."""
    from starlette.testclient import TestClient

    app = _build_app()

    @asynccontextmanager
    async def test_lifespan(app: FastAPI):
        _wire_managers(app)
        yield
        await app.state.acp_session_manager.shutdown()

    app.router.lifespan_context = test_lifespan

    with TestClient(app) as tc:
        # Create session
        resp = tc.post("/api/sessions", json={"project_root": "/tmp/ws-test2"})
        session_id = resp.json()["id"]

        # Submit a task via REST — this auto-spawns an agent and assigns the task
        resp = tc.post(
            f"/api/sessions/{session_id}/tasks",
            json={"role": "dev", "message": "WS test task"},
        )
        assert resp.status_code == 201
        request_id = resp.json()["tasks"][0]["request_id"]

        # Connect WS and send a taskUpdate to mark the task finished
        with tc.websocket_connect(f"/ws/{session_id}") as ws:
            ws.send_json(
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "taskUpdate",
                    "params": {
                        "request_id": request_id,
                        "status": "finished",
                        "content": "All done",
                        "commit": "abc123",
                    },
                }
            )

            # Receive both messages in any order
            msg1 = ws.receive_json()
            msg2 = ws.receive_json()
            broadcast, rpc_resp = _sort_ws_messages([msg1, msg2])

            assert broadcast is not None
            assert broadcast["method"] == "task/statusChanged"
            assert broadcast["params"]["request_id"] == request_id
            assert broadcast["params"]["status"] == "finished"

            assert rpc_resp is not None
            assert rpc_resp["id"] == 2
            assert rpc_resp["result"]["success"] is True
