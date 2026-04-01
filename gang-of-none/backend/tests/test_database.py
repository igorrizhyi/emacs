import pytest
import asyncio
from datetime import datetime, timezone
import uuid

from src.core.database import Database
from src.models.session import Session
from src.models.task import Task
from src.models.enums import AgentRole, TaskStatus, TaskPriority

# All test coroutines will be treated as marked.
pytestmark = pytest.mark.asyncio


@pytest.fixture
async def db():
    database = Database(":memory:")
    await database.init()
    yield database
    await database.close()


async def test_initialize_database(db: Database):
    # The fixture itself tests initialization.
    # We can check if tables were created.
    cursor = await db.conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('sessions', 'tasks', 'agents', 'task_groups')"
    )
    tables = await cursor.fetchall()
    assert len(tables) == 4


async def test_save_and_get_session(db: Database):
    session_id = str(uuid.uuid4())
    session = Session(id=session_id, project_root="/tmp/test")
    await db.save_session(session)

    retrieved = await db.get_session(session_id)
    assert retrieved is not None
    assert retrieved.id == session_id
    assert retrieved.project_root == "/tmp/test"


async def test_list_sessions(db: Database):
    session1 = Session(id=str(uuid.uuid4()), project_root="/tmp/test1")
    session2 = Session(id=str(uuid.uuid4()), project_root="/tmp/test2")
    await db.save_session(session1)
    # Ensure created_at is different for ordering
    await asyncio.sleep(0.01)
    await db.save_session(session2)

    sessions = await db.list_sessions()
    assert len(sessions) == 2
    assert sessions[0].id == session1.id
    assert sessions[1].id == session2.id


async def test_delete_session(db: Database):
    session_id = str(uuid.uuid4())
    session = Session(id=session_id, project_root="/tmp/test")
    await db.save_session(session)

    await db.delete_session(session_id)
    retrieved = await db.get_session(session_id)
    assert retrieved is None


async def test_save_and_get_task(db: Database):
    session_id = str(uuid.uuid4())
    session = Session(id=session_id, project_root="/tmp/project")
    await db.save_session(session)

    task_id = str(uuid.uuid4())
    request_id = str(uuid.uuid4())
    task = Task(
        id=task_id,
        request_id=request_id,
        session_id=session_id,
        role=AgentRole.TESTER,
        status=TaskStatus.PENDING,
        message="Write a test",
        priority=TaskPriority.NORMAL,
    )
    await db.save_task(task)

    retrieved = await db.get_task(request_id)
    assert retrieved is not None
    assert retrieved.id == task_id
    assert retrieved.request_id == request_id
    assert retrieved.session_id == session_id
    assert retrieved.role == AgentRole.TESTER
    assert retrieved.status == TaskStatus.PENDING
    assert retrieved.priority == TaskPriority.NORMAL


async def test_list_tasks(db: Database):
    session_id = str(uuid.uuid4())
    session = Session(id=session_id, project_root="/tmp/project")
    await db.save_session(session)

    task1 = Task(id=str(uuid.uuid4()), request_id=str(uuid.uuid4()), session_id=session_id, role=AgentRole.DEV, message="msg1")
    task2 = Task(id=str(uuid.uuid4()), request_id=str(uuid.uuid4()), session_id=session_id, role=AgentRole.DEV, message="msg2")
    await db.save_task(task1)
    await db.save_task(task2)

    tasks = await db.list_tasks(session_id)
    assert len(tasks) == 2
    assert {t.request_id for t in tasks} == {task1.request_id, task2.request_id}


async def test_update_task_status(db: Database):
    session_id = str(uuid.uuid4())
    session = Session(id=session_id, project_root="/tmp/project")
    await db.save_session(session)

    request_id = str(uuid.uuid4())
    task = Task(id=str(uuid.uuid4()), request_id=request_id, session_id=session_id, role=AgentRole.DEV, message="msg")
    await db.save_task(task)

    now = datetime.now(timezone.utc)
    await db.update_task_status(
        request_id, TaskStatus.FINISHED, completed_at=now, result="Success"
    )

    updated_task = await db.get_task(request_id)
    assert updated_task is not None
    assert updated_task.status == TaskStatus.FINISHED
    # Note: result is in DB but not in Task model, so we can't check it via updated_task.result
    # unless we use raw DB query or if it was added to the model.
    # Since _row_to_task doesn't include it, it's not on the model.
    
    # Check via raw DB query to be sure
    cursor = await db.conn.execute("SELECT result FROM tasks WHERE request_id = ?", (request_id,))
    row = await cursor.fetchone()
    assert row["result"] == "Success"
    
    # A bit lenient with timestamp comparison
    assert (updated_task.completed_at - now).total_seconds() < 1


async def test_save_and_get_agent(db: Database):
    session_id = str(uuid.uuid4())
    session = Session(id=session_id, project_root="/tmp/project")
    await db.save_session(session)

    agent_id = str(uuid.uuid4())
    await db.save_agent(
        agent_id=agent_id,
        session_id=session_id,
        role="engineer",
        status="idle",
        model="claude-3-opus-20240229",
    )

    agent = await db.get_agent(agent_id)
    assert agent is not None
    assert agent["id"] == agent_id
    assert agent["session_id"] == session_id
    assert agent["role"] == "engineer"
    assert agent["status"] == "idle"
    assert agent["model"] == "claude-3-opus-20240229"


async def test_task_group_operations(db: Database):
    session_id = str(uuid.uuid4())
    group_id = "group-1"
    session = Session(id=session_id, project_root="/tmp/project")
    await db.save_session(session)

    await db.save_task_group(group_id, session_id, total=5)
    group = await db.get_task_group(group_id)
    assert group is not None
    assert group["group_id"] == group_id
    assert group["session_id"] == session_id
    assert group["total"] == 5
    assert group["completed"] == 0

    await db.update_group_progress(group_id, completed=2)
    group = await db.get_task_group(group_id)
    assert group is not None
    assert group["completed"] == 2
    assert group["total"] == 5

    await db.update_group_progress(group_id, completed=3, total=6)
    group = await db.get_task_group(group_id)
    assert group is not None
    assert group["completed"] == 3
    assert group["total"] == 6

