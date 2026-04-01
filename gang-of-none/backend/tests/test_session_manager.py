import pytest
import uuid
from unittest.mock import MagicMock, AsyncMock

from src.core.session_manager import SessionManager
from src.core.database import Database
from src.config import Settings
from src.models.session import Session

pytestmark = pytest.mark.asyncio


@pytest.fixture
async def db():
    database = Database(":memory:")
    await database.init()
    yield database
    await database.close()


@pytest.fixture
def settings():
    return Settings(db_path=":memory:")


@pytest.fixture
def agent_manager(settings):
    return MagicMock()


@pytest.fixture
def session_manager(settings, agent_manager, db):
    return SessionManager(settings=settings, agent_manager=agent_manager, db=db)


async def test_create_session(session_manager: SessionManager, db: Database):
    project_root = "/tmp/project1"
    session = await session_manager.create_session_async(project_root)

    assert session is not None
    assert session.project_root == project_root
    assert session.id in session_manager.list_sessions()

    # Verify persistence
    retrieved_from_db = await db.get_session(session.id)
    assert retrieved_from_db is not None
    assert retrieved_from_db.id == session.id


async def test_get_session(session_manager: SessionManager):
    project_root = "/tmp/project2"
    session = await session_manager.create_session_async(project_root)

    retrieved = session_manager.get_session(session.id)
    assert retrieved is not None
    assert retrieved.id == session.id


async def test_destroy_session(session_manager: SessionManager, db: Database):
    project_root = "/tmp/project3"
    session = await session_manager.create_session_async(project_root)
    session_id = session.id

    await session_manager.destroy_session_async(session_id)

    assert session_manager.get_session(session_id) is None
    assert session_id not in session_manager.list_sessions()

    # Verify deletion from DB
    retrieved_from_db = await db.get_session(session_id)
    assert retrieved_from_db is None


async def test_restore_from_db(db: Database):
    # 1. Manually insert a session into the DB
    session_id = uuid.uuid4().hex[:8]
    session = Session(id=session_id, project_root="/tmp/restored_project")
    await db.save_session(session)

    # 2. Create a new SessionManager that will restore from the DB
    new_agent_manager = MagicMock()
    new_settings = Settings(db_path=":memory:")
    new_session_manager = SessionManager(
        settings=new_settings, agent_manager=new_agent_manager, db=db
    )

    # 3. Trigger restoration
    await new_session_manager.restore_from_db()

    # 4. Verify session was loaded into memory
    restored_session = new_session_manager.get_session(session_id)
    assert restored_session is not None
    assert restored_session.id == session_id
    assert restored_session.project_root == "/tmp/restored_project"


async def test_session_lifecycle(session_manager: SessionManager, db: Database):
    # Create
    project_root = "/tmp/lifecycle"
    session = await session_manager.create_session_async(project_root)
    session_id = session.id
    assert session_manager.get_session(session_id) is not None
    assert await db.get_session(session_id) is not None

    # "Active" is implicit by being in the manager's dict
    assert session_id in session_manager.list_sessions()

    # Destroy (completes the lifecycle)
    await session_manager.destroy_session_async(session_id)
    assert session_manager.get_session(session_id) is None
    assert await db.get_session(session_id) is None
