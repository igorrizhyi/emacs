"""Task queue management, dispatch, group tracking, and deduplication."""

from datetime import datetime, timezone
from uuid import uuid4

from ..models.enums import AgentRole, TaskPriority, TaskStatus
from ..models.task import Task, TaskCreate, TaskGroup, TaskUpdate


# Terminal statuses that indicate a task is done (success or failure).
_TERMINAL_STATUSES = frozenset({TaskStatus.FINISHED, TaskStatus.BLOCKED})


class TaskManager:
    """Manages the full lifecycle of tasks: enqueue, assign, complete, group."""

    def __init__(self, reports_dir: str = "reports") -> None:
        self._reports_dir = reports_dir
        self._queue: list[Task] = []  # FIFO pending tasks
        self._active_tasks: dict[str, Task] = {}  # request_id → assigned task
        self._completed_tasks: dict[str, Task] = {}  # request_id → completed task
        self._groups: dict[str, TaskGroup] = {}  # group_id → TaskGroup
        self._request_to_group: dict[str, str] = {}  # request_id → group_id
        self._request_to_session: dict[str, str] = {}  # request_id → session_id
        self._interrupt_queue: dict[str, list[Task]] = {}  # agent_id → interrupt tasks

    # ------------------------------------------------------------------
    # Enqueue
    # ------------------------------------------------------------------

    def enqueue_tasks(
        self, tasks: list[TaskCreate], session_id: str
    ) -> list[Task]:
        """Process a batch of task creation requests.

        Generates IDs, deduplicates, registers groups, and enqueues.
        Returns the list of newly created ``Task`` objects.
        """
        created: list[Task] = []
        for tc in tasks:
            request_id = tc.request_id or self._generate_request_id()

            # Dedup: skip if request_id already exists anywhere.
            if self._find_existing(request_id) is not None:
                continue

            # Dedup: skip if an active task has the same role+message.
            if self._is_duplicate_content(tc.role, tc.message):
                continue

            report_path = f"{self._reports_dir}/{session_id}/{request_id}.md"

            task = Task(
                id=uuid4().hex[:12],
                request_id=request_id,
                role=tc.role,
                message=tc.message,
                group_id=tc.group_id,
                target=tc.target,
                priority=tc.priority,
                model=tc.model,
                session_id=session_id,
                report_path=report_path,
                status=TaskStatus.PENDING,
            )

            self._request_to_session[request_id] = session_id

            # Group registration.
            if tc.group_id:
                self._request_to_group[request_id] = tc.group_id
                group = self._groups.get(tc.group_id)
                if group is None:
                    group = TaskGroup(
                        group_id=tc.group_id,
                        session_id=session_id,
                    )
                    self._groups[tc.group_id] = group
                group.pending.append(request_id)

            # Interrupt-priority tasks go to the interrupt queue when targeted.
            if tc.priority == TaskPriority.INTERRUPT and tc.target:
                self._interrupt_queue.setdefault(tc.target, []).append(task)
            else:
                self._queue.append(task)

            created.append(task)
        return created

    # ------------------------------------------------------------------
    # Assignment
    # ------------------------------------------------------------------

    def get_next_task_for_role(
        self, role: AgentRole, agent_id: str | None = None
    ) -> Task | None:
        """Return the highest-priority pending task for *role*.

        Priority order:
        1. Interrupt queue for this *agent_id*.
        2. Queue tasks targeted at this *agent_id*.
        3. Any untargeted queue task matching *role*.
        """
        if agent_id:
            # 1. Interrupt queue.
            task = self.get_interrupt(agent_id)
            if task is not None:
                return task

            # 2. Targeted tasks in main queue.
            for t in self._queue:
                if t.role == role and t.target == agent_id:
                    return t

        # 3. First untargeted task matching role.
        for t in self._queue:
            if t.role == role and t.target is None:
                return t

        return None

    def mark_assigned(self, request_id: str, agent_id: str) -> Task | None:
        """Move a task from the queue to active and mark it as assigned."""
        task = self._remove_from_queue(request_id)
        if task is None:
            return None

        task.status = TaskStatus.ASSIGNED
        task.assigned_at = datetime.now(timezone.utc)
        self._active_tasks[request_id] = task
        return task

    def get_pending_count(self) -> int:
        """Return the number of tasks waiting in the queue."""
        return len(self._queue)

    def get_pending_for_role(self, role: AgentRole) -> list[Task]:
        """Return all queued tasks for a given role."""
        return [t for t in self._queue if t.role == role]

    # ------------------------------------------------------------------
    # Completion & groups
    # ------------------------------------------------------------------

    def mark_completed(
        self, request_id: str, status: TaskStatus
    ) -> Task | None:
        """Mark an active task as completed with a terminal *status*."""
        task = self._active_tasks.pop(request_id, None)
        if task is None:
            return None

        task.status = status
        task.completed_at = datetime.now(timezone.utc)
        self._completed_tasks[request_id] = task

        # Update group tracking.
        group_id = self._request_to_group.get(request_id)
        if group_id and group_id in self._groups:
            group = self._groups[group_id]
            if request_id in group.pending:
                group.pending.remove(request_id)
            group.completed.append(request_id)

        return task

    def check_group_complete(self, group_id: str) -> bool:
        """Return ``True`` if every task in the group has a terminal status."""
        group = self._groups.get(group_id)
        if group is None:
            return False
        return len(group.pending) == 0 and len(group.completed) > 0

    def get_group_report(self, group_id: str) -> TaskGroup | None:
        """Return the ``TaskGroup`` for *group_id*, or ``None``."""
        return self._groups.get(group_id)

    # ------------------------------------------------------------------
    # Task updates from agents
    # ------------------------------------------------------------------

    def handle_task_update(self, update: TaskUpdate) -> Task | None:
        """Process an incoming ``TaskUpdate`` from an agent."""
        task = self._active_tasks.get(update.request_id)
        if task is None:
            return None

        if update.report_path:
            task.report_path = update.report_path

        if update.status in _TERMINAL_STATUSES:
            return self.mark_completed(update.request_id, update.status)

        # Non-terminal update (e.g. UPDATED) — keep task active.
        task.status = update.status
        return task

    # ------------------------------------------------------------------
    # Interrupt support
    # ------------------------------------------------------------------

    def enqueue_interrupt(self, agent_id: str, task: Task) -> None:
        """Add a high-priority interrupt task for a specific agent."""
        self._interrupt_queue.setdefault(agent_id, []).append(task)

    def get_interrupt(self, agent_id: str) -> Task | None:
        """Pop the next interrupt task for *agent_id*, or ``None``."""
        q = self._interrupt_queue.get(agent_id)
        if q:
            return q.pop(0)
        return None

    # ------------------------------------------------------------------
    # Query helpers
    # ------------------------------------------------------------------

    def get_task(self, request_id: str) -> Task | None:
        """Find a task by *request_id* across all collections."""
        return self._find_existing(request_id)

    def get_session_for_request(self, request_id: str) -> str | None:
        """Return the session_id associated with *request_id*."""
        return self._request_to_session.get(request_id)

    def get_active_tasks(self) -> list[Task]:
        """Return all currently assigned (in-flight) tasks."""
        return list(self._active_tasks.values())

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _generate_request_id() -> str:
        """Generate a unique 8-character hex request ID."""
        return uuid4().hex[:8]

    def _find_existing(self, request_id: str) -> Task | None:
        """Look up a task by *request_id* in queue, active, or completed."""
        for t in self._queue:
            if t.request_id == request_id:
                return t
        if request_id in self._active_tasks:
            return self._active_tasks[request_id]
        if request_id in self._completed_tasks:
            return self._completed_tasks[request_id]
        return None

    def _is_duplicate_content(self, role: AgentRole, message: str) -> bool:
        """Check if an active task already has the same role+message."""
        for task in self._active_tasks.values():
            if task.role == role and task.message == message:
                return True
        return False

    def _remove_from_queue(self, request_id: str) -> Task | None:
        """Remove and return a task from ``_queue`` by request_id."""
        for i, t in enumerate(self._queue):
            if t.request_id == request_id:
                return self._queue.pop(i)
        return None
