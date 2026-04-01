"""Tests for TaskManager — enqueue, assign, complete, groups, updates."""

import pytest

from src.core.task_manager import TaskManager
from src.models.enums import AgentRole, TaskPriority, TaskStatus
from src.models.task import TaskCreate, TaskUpdate


@pytest.fixture
def tm() -> TaskManager:
    return TaskManager(reports_dir="/tmp/reports")


SESSION = "test-session"


def _make_create(
    role: AgentRole = AgentRole.DEV,
    message: str = "do stuff",
    request_id: str | None = None,
    group_id: str | None = None,
    target: str | None = None,
    priority: TaskPriority = TaskPriority.NORMAL,
) -> TaskCreate:
    return TaskCreate(
        role=role,
        message=message,
        request_id=request_id,
        group_id=group_id,
        target=target,
        priority=priority,
    )


class TestEnqueue:
    def test_create_task_fields(self, tm: TaskManager):
        tasks = tm.enqueue_tasks(
            [_make_create(request_id="req-1", message="build widget")], SESSION
        )
        assert len(tasks) == 1
        t = tasks[0]
        assert t.request_id == "req-1"
        assert t.role == AgentRole.DEV
        assert t.message == "build widget"
        assert t.status == TaskStatus.PENDING
        assert t.session_id == SESSION
        assert t.report_path == f"/tmp/reports/{SESSION}/req-1.md"

    def test_auto_generates_request_id(self, tm: TaskManager):
        tasks = tm.enqueue_tasks([_make_create()], SESSION)
        assert len(tasks) == 1
        assert len(tasks[0].request_id) == 8

    def test_dedup_by_request_id(self, tm: TaskManager):
        tm.enqueue_tasks([_make_create(request_id="dup")], SESSION)
        second = tm.enqueue_tasks([_make_create(request_id="dup")], SESSION)
        assert len(second) == 0

    def test_dedup_by_role_message(self, tm: TaskManager):
        """Active tasks with same role+message are skipped."""
        tasks = tm.enqueue_tasks(
            [_make_create(request_id="a", message="same")], SESSION
        )
        # Mark it assigned (active) so content dedup kicks in.
        tm.mark_assigned("a", "agent-1")
        second = tm.enqueue_tasks(
            [_make_create(request_id="b", message="same")], SESSION
        )
        assert len(second) == 0

    def test_pending_count(self, tm: TaskManager):
        tm.enqueue_tasks(
            [_make_create(request_id="x"), _make_create(request_id="y")], SESSION
        )
        assert tm.get_pending_count() == 2

    def test_interrupt_priority_goes_to_interrupt_queue(self, tm: TaskManager):
        tm.enqueue_tasks(
            [
                _make_create(
                    request_id="int-1",
                    priority=TaskPriority.INTERRUPT,
                    target="agent-x",
                )
            ],
            SESSION,
        )
        # Not in main queue.
        assert tm.get_pending_count() == 0
        # Available via get_interrupt.
        task = tm.get_interrupt("agent-x")
        assert task is not None
        assert task.request_id == "int-1"


class TestAssignment:
    def test_assign_removes_from_queue(self, tm: TaskManager):
        tm.enqueue_tasks([_make_create(request_id="a1")], SESSION)
        task = tm.mark_assigned("a1", "agent-1")
        assert task is not None
        assert task.status == TaskStatus.ASSIGNED
        assert task.assigned_at is not None
        assert tm.get_pending_count() == 0

    def test_get_next_task_for_role(self, tm: TaskManager):
        tm.enqueue_tasks(
            [
                _make_create(request_id="dev1", role=AgentRole.DEV),
                _make_create(request_id="test1", role=AgentRole.TESTER),
            ],
            SESSION,
        )
        task = tm.get_next_task_for_role(AgentRole.TESTER)
        assert task is not None
        assert task.request_id == "test1"

    def test_targeted_task_preferred(self, tm: TaskManager):
        tm.enqueue_tasks(
            [
                _make_create(request_id="gen", role=AgentRole.DEV),
                _make_create(request_id="tgt", role=AgentRole.DEV, target="agent-a"),
            ],
            SESSION,
        )
        task = tm.get_next_task_for_role(AgentRole.DEV, agent_id="agent-a")
        assert task is not None
        assert task.request_id == "tgt"

    def test_interrupt_takes_priority(self, tm: TaskManager):
        tm.enqueue_tasks([_make_create(request_id="normal")], SESSION)
        tm.enqueue_interrupt(
            "agent-b",
            tm.enqueue_tasks(
                [_make_create(request_id="urgent", priority=TaskPriority.INTERRUPT)],
                SESSION,
            )[0],
        )
        task = tm.get_next_task_for_role(AgentRole.DEV, agent_id="agent-b")
        assert task is not None
        assert task.request_id == "urgent"

    def test_no_task_for_role(self, tm: TaskManager):
        tm.enqueue_tasks([_make_create(role=AgentRole.DEV)], SESSION)
        assert tm.get_next_task_for_role(AgentRole.TESTER) is None


class TestCompletion:
    def test_mark_completed(self, tm: TaskManager):
        tm.enqueue_tasks([_make_create(request_id="c1")], SESSION)
        tm.mark_assigned("c1", "agent-1")
        task = tm.mark_completed("c1", TaskStatus.FINISHED)
        assert task is not None
        assert task.status == TaskStatus.FINISHED
        assert task.completed_at is not None
        # Not in active tasks anymore.
        assert len(tm.get_active_tasks()) == 0

    def test_mark_completed_nonexistent(self, tm: TaskManager):
        assert tm.mark_completed("nope", TaskStatus.FINISHED) is None


class TestGroups:
    def test_group_creation_and_completion(self, tm: TaskManager):
        tm.enqueue_tasks(
            [
                _make_create(request_id="g1", group_id="grp"),
                _make_create(request_id="g2", group_id="grp"),
            ],
            SESSION,
        )
        assert not tm.check_group_complete("grp")

        tm.mark_assigned("g1", "a1")
        tm.mark_completed("g1", TaskStatus.FINISHED)
        assert not tm.check_group_complete("grp")

        tm.mark_assigned("g2", "a2")
        tm.mark_completed("g2", TaskStatus.FINISHED)
        assert tm.check_group_complete("grp")

    def test_group_report(self, tm: TaskManager):
        tm.enqueue_tasks(
            [_make_create(request_id="gr1", group_id="batch")], SESSION
        )
        group = tm.get_group_report("batch")
        assert group is not None
        assert group.group_id == "batch"
        assert "gr1" in group.pending

    def test_nonexistent_group(self, tm: TaskManager):
        assert not tm.check_group_complete("no-such-group")


class TestTaskUpdate:
    def test_handle_terminal_update(self, tm: TaskManager):
        tm.enqueue_tasks([_make_create(request_id="u1")], SESSION)
        tm.mark_assigned("u1", "a1")
        update = TaskUpdate(
            request_id="u1",
            status=TaskStatus.FINISHED,
            content="done",
            report_path="/tmp/r.md",
        )
        task = tm.handle_task_update(update)
        assert task is not None
        assert task.status == TaskStatus.FINISHED
        assert task.report_path == "/tmp/r.md"

    def test_handle_nonterminal_update(self, tm: TaskManager):
        tm.enqueue_tasks([_make_create(request_id="u2")], SESSION)
        tm.mark_assigned("u2", "a1")
        update = TaskUpdate(
            request_id="u2", status=TaskStatus.UPDATED, content="progress"
        )
        task = tm.handle_task_update(update)
        assert task is not None
        assert task.status == TaskStatus.UPDATED
        # Still in active tasks.
        assert len(tm.get_active_tasks()) == 1

    def test_handle_update_unknown_request(self, tm: TaskManager):
        update = TaskUpdate(
            request_id="nope", status=TaskStatus.FINISHED, content="?"
        )
        assert tm.handle_task_update(update) is None


class TestQueryHelpers:
    def test_get_task_across_collections(self, tm: TaskManager):
        tm.enqueue_tasks([_make_create(request_id="q1")], SESSION)
        assert tm.get_task("q1") is not None  # in queue
        tm.mark_assigned("q1", "a1")
        assert tm.get_task("q1") is not None  # in active
        tm.mark_completed("q1", TaskStatus.FINISHED)
        assert tm.get_task("q1") is not None  # in completed

    def test_get_session_tasks(self, tm: TaskManager):
        tm.enqueue_tasks([_make_create(request_id="s1")], SESSION)
        tm.enqueue_tasks([_make_create(request_id="s2")], "other")
        session_tasks = tm.get_session_tasks(SESSION)
        assert len(session_tasks) == 1
        assert session_tasks[0].request_id == "s1"

    def test_get_session_for_request(self, tm: TaskManager):
        tm.enqueue_tasks([_make_create(request_id="sr1")], SESSION)
        assert tm.get_session_for_request("sr1") == SESSION
        assert tm.get_session_for_request("nope") is None

    def test_get_pending_for_role(self, tm: TaskManager):
        tm.enqueue_tasks(
            [
                _make_create(request_id="r1", role=AgentRole.DEV),
                _make_create(request_id="r2", role=AgentRole.TESTER),
            ],
            SESSION,
        )
        devs = tm.get_pending_for_role(AgentRole.DEV)
        assert len(devs) == 1
        assert devs[0].request_id == "r1"
