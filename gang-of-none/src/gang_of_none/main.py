from contextlib import asynccontextmanager
import os

from fastapi import FastAPI
import structlog

from gang_of_none.api.connection_manager import ConnectionManager
from gang_of_none.api.routes import router as rest_router
from gang_of_none.api.ws import router as ws_router
from gang_of_none.config import Settings
from gang_of_none.core.acp_session import ACPSessionManager
from gang_of_none.core.agent_manager import AgentManager
from gang_of_none.core.approval_manager import ApprovalManager
from gang_of_none.core.namespace_manager import NamespaceManager
from gang_of_none.core.orchestrator import Orchestrator
from gang_of_none.core.report_manager import ReportManager
from gang_of_none.core.session_manager import SessionManager
from gang_of_none.core.task_manager import TaskManager
from gang_of_none.core.worktree_manager import WorktreeManager

logger = structlog.get_logger()


def _make_create_session(session_mgr: SessionManager):
    """Return an async callable that creates a session via SessionManager."""
    async def create_session(project_root: str):
        return session_mgr.create_session(project_root)
    return create_session


def _make_destroy_session(session_mgr: SessionManager, orchestrator: Orchestrator):
    """Return an async callable that destroys a session with full cleanup."""
    async def destroy_session(session_id: str):
        session = session_mgr.get_session(session_id)
        if session is not None:
            await orchestrator.cleanup_session(session_id, session.project_root)
        session_mgr.destroy_session(session_id)
    return destroy_session


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("gang-of-none starting")

    settings = Settings()

    # Initialize core managers
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
    )
    app.state.orchestrator = Orchestrator(
        settings=settings,
        task_manager=app.state.task_manager,
        agent_manager=app.state.agent_manager,
        acp_session_manager=app.state.acp_session_manager,
        worktree_manager=app.state.worktree_manager,
        report_manager=app.state.report_manager,
        session_manager=app.state.session_manager,
    )

    # Wire session registry and factory/destroy callables for REST routes
    app.state.sessions = app.state.session_manager.list_sessions()
    app.state.create_session = _make_create_session(app.state.session_manager)
    app.state.destroy_session = _make_destroy_session(
        app.state.session_manager, app.state.orchestrator,
    )

    # Initialize namespace manager
    ns_mgr = NamespaceManager()
    app.state.namespace_manager = ns_mgr

    # Try to load namespace config from .agent-shell/namespace.json
    ns_config_path = os.environ.get(
        "NAMESPACE_CONFIG", ".agent-shell/namespace.json"
    )
    try:
        config = ns_mgr.load_config(ns_config_path)
        app.state.namespace_config = config
        # Start the file-based IPC bus
        await ns_mgr.start_bus(config.namespace, os.getpid())
    except FileNotFoundError:
        logger.info("namespace.no_config", path=ns_config_path)
        app.state.namespace_config = None

    # Start the periodic drain loop
    await app.state.orchestrator.start_drain_loop()

    yield

    # Shutdown
    await app.state.orchestrator.stop_drain_loop()
    await ns_mgr.stop_bus()
    await app.state.acp_session_manager.shutdown()
    logger.info("gang-of-none shutting down")


app = FastAPI(title="gang-of-none", lifespan=lifespan)
app.include_router(ws_router)
app.include_router(rest_router)


@app.get("/health")
async def health():
    return {"status": "ok"}
