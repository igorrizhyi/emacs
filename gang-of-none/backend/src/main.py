from contextlib import asynccontextmanager
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path

from fastapi import FastAPI
import structlog

from .api.connection_manager import ConnectionManager
from .api.mcp_server import create_mcp_server
from .api.routes import router as rest_router
from .api.ws import router as ws_router
from .config import Settings
from .core.acp_session import ACPSessionManager
from .core.agent_manager import AgentManager
from .core.approval_manager import ApprovalManager
from .core.database import Database
from .core.namespace_manager import NamespaceManager
from .core.orchestrator import Orchestrator
from .core.prompt_manager import PromptManager
from .core.report_manager import ReportManager
from .core.session_manager import SessionManager
from .core.task_manager import TaskManager
from .core.worktree_manager import WorktreeManager

# ── Logging setup ─────────────────────────────────────────────────────

_LOG_DIR = Path(__file__).resolve().parent.parent / "logs"
_LOG_FILE = _LOG_DIR / "server.log"
_LOG_FORMAT = "%(asctime)s %(levelname)-8s %(name)s  %(message)s"


def _setup_logging() -> None:
    """Configure dual output (console + rotating file) for all loggers."""
    _LOG_DIR.mkdir(parents=True, exist_ok=True)

    file_handler = RotatingFileHandler(
        _LOG_FILE,
        maxBytes=10 * 1024 * 1024,  # 10 MB
        backupCount=5,
        encoding="utf-8",
    )
    file_handler.setFormatter(logging.Formatter(_LOG_FORMAT))

    # Attach file handler to root logger so uvicorn + app logs are captured
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.addHandler(file_handler)

    # Configure structlog to render through stdlib logging (dual output)
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.stdlib.add_log_level,
            structlog.stdlib.add_logger_name,
            structlog.dev.set_exc_info,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            structlog.stdlib.ProcessorFormatter.wrap_for_formatter,
        ],
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
        cache_logger_on_first_use=True,
    )

    # Add a structlog-aware formatter to the file handler
    formatter = structlog.stdlib.ProcessorFormatter(
        processor=structlog.dev.ConsoleRenderer(colors=False),
    )
    file_handler.setFormatter(formatter)

    # Also apply the formatter to existing console handlers so structlog
    # output is consistent across both sinks.
    console_formatter = structlog.stdlib.ProcessorFormatter(
        processor=structlog.dev.ConsoleRenderer(),
    )
    for handler in root.handlers:
        if isinstance(handler, logging.StreamHandler) and not isinstance(
            handler, RotatingFileHandler
        ):
            handler.setFormatter(console_formatter)

    # Ensure uvicorn loggers propagate to root so the file handler catches them
    for name in ("uvicorn", "uvicorn.access", "uvicorn.error"):
        uv_logger = logging.getLogger(name)
        uv_logger.propagate = True


_setup_logging()

logger = structlog.get_logger()


def _make_create_session(session_mgr: SessionManager):
    """Return an async callable that creates a session via SessionManager."""
    async def create_session(project_root: str):
        return await session_mgr.create_session_async(project_root)
    return create_session


def _make_destroy_session(session_mgr: SessionManager, orchestrator: Orchestrator):
    """Return an async callable that destroys a session with full cleanup."""
    async def destroy_session(session_id: str):
        session = session_mgr.get_session(session_id)
        if session is not None:
            await orchestrator.cleanup_session(session_id, session.project_root)
        await session_mgr.destroy_session_async(session_id)
    return destroy_session


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("gang-of-none starting")

    settings = Settings()

    # Initialize database
    db = Database(settings.db_path)
    await db.init()
    app.state.db = db

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
        db=db,
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
        connection_manager=app.state.connection_manager,
    )

    # Restore sessions from database
    await app.state.session_manager.restore_from_db()

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

    # Create and mount MCP server
    mcp_server = create_mcp_server(
        task_manager=app.state.task_manager,
        agent_manager=app.state.agent_manager,
        approval_manager=app.state.approval_manager,
        connection_manager=app.state.connection_manager,
        orchestrator=app.state.orchestrator,
        acp_session_manager=app.state.acp_session_manager,
    )
    app.state.mcp_server = mcp_server
    mcp_http_app = mcp_server.streamable_http_app()
    app.mount("/mcp", mcp_http_app)

    # Start the periodic drain loop
    await app.state.orchestrator.start_drain_loop()

    yield

    # Shutdown
    await app.state.orchestrator.stop_drain_loop()
    await ns_mgr.stop_bus()
    await app.state.acp_session_manager.shutdown()
    await db.close()
    logger.info("gang-of-none shutting down")


app = FastAPI(title="gang-of-none", lifespan=lifespan)
app.include_router(ws_router)
app.include_router(rest_router)


@app.get("/health")
async def health():
    return {"status": "ok"}
