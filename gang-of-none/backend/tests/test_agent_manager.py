"""Tests for AgentManager — registration, status, lookup, spawn, dismissal."""

import pytest

from src.config import Settings
from src.core.agent_manager import AgentManager
from src.models.agent import Agent, AgentCreate
from src.models.enums import AgentRole, AgentStatus


@pytest.fixture
def settings() -> Settings:
    return Settings(max_agents_per_role=2)


@pytest.fixture
def am(settings: Settings) -> AgentManager:
    return AgentManager(settings)


SESSION = "test-session"


def _agent_create(role: AgentRole = AgentRole.DEV) -> AgentCreate:
    return AgentCreate(role=role, session_id=SESSION)


class TestCreateAndRegister:
    def test_create_agent(self, am: AgentManager):
        agent = am.create_agent(_agent_create())
        assert agent.role == AgentRole.DEV
        assert agent.session_id == SESSION
        assert agent.status == AgentStatus.INITIALIZING
        assert am.get_agent(agent.id) is agent

    def test_unique_names(self, am: AgentManager):
        ids = set()
        for _ in range(10):
            a = am.create_agent(_agent_create())
            ids.add(a.id)
        assert len(ids) == 10

    def test_register_raw_agent(self, am: AgentManager):
        agent = Agent(id="custom-id", role=AgentRole.TESTER, session_id=SESSION)
        am.register_agent(agent)
        assert am.get_agent("custom-id") is agent


class TestLookup:
    def test_get_by_id(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        assert am.get_agent(a.id) is a
        assert am.get_agent("no-such") is None

    def test_get_agents_by_role(self, am: AgentManager):
        am.create_agent(_agent_create(AgentRole.DEV))
        am.create_agent(_agent_create(AgentRole.DEV))
        am.create_agent(_agent_create(AgentRole.TESTER))
        devs = am.get_agents_by_role(AgentRole.DEV)
        assert len(devs) == 2
        testers = am.get_agents_by_role(AgentRole.TESTER)
        assert len(testers) == 1

    def test_get_agents_by_role_filtered_by_session(self, am: AgentManager):
        am.create_agent(_agent_create(AgentRole.DEV))
        other = AgentCreate(role=AgentRole.DEV, session_id="other")
        am.create_agent(other)
        devs = am.get_agents_by_role(AgentRole.DEV, session_id=SESSION)
        assert len(devs) == 1

    def test_get_session_agents(self, am: AgentManager):
        am.create_agent(_agent_create())
        am.create_agent(_agent_create(AgentRole.TESTER))
        agents = am.get_session_agents(SESSION)
        assert len(agents) == 2

    def test_find_agent_by_name_exact(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        found = am.find_agent_by_name(a.id)
        assert found is a

    def test_find_agent_by_name_substring(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        # Use a substring of the agent id (first 4 chars).
        found = am.find_agent_by_name(a.id[:4])
        assert found is not None

    def test_get_lead(self, am: AgentManager):
        am.create_agent(AgentCreate(role=AgentRole.LEAD, session_id=SESSION))
        lead = am.get_lead(SESSION)
        assert lead is not None
        assert lead.role == AgentRole.LEAD


class TestStatus:
    def test_status_transitions(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        assert am.get_status(a.id) == AgentStatus.INITIALIZING

        am.mark_init_finished(a.id)
        assert am.get_status(a.id) == AgentStatus.IDLE
        assert a.init_finished is True

        am.mark_busy(a.id, "task-1")
        assert am.get_status(a.id) == AgentStatus.BUSY
        assert a.current_task_id == "task-1"

        am.mark_idle(a.id)
        assert am.get_status(a.id) == AgentStatus.IDLE
        assert a.current_task_id is None

    def test_set_status(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        am.set_status(a.id, AgentStatus.DEAD)
        assert am.get_status(a.id) == AgentStatus.DEAD

    def test_get_idle_agents(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        am.mark_init_finished(a.id)
        b = am.create_agent(_agent_create())
        am.mark_init_finished(b.id)
        am.mark_busy(b.id, "t")
        idle = am.get_idle_agents(AgentRole.DEV, SESSION)
        assert len(idle) == 1
        assert idle[0].id == a.id

    def test_idle_excludes_reserved(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        am.mark_init_finished(a.id)
        am.set_reserved(a.id, True)
        idle = am.get_idle_agents(AgentRole.DEV, SESSION)
        assert len(idle) == 0


class TestAutoSpawn:
    def test_should_spawn_when_no_idle(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        am.mark_init_finished(a.id)
        am.mark_busy(a.id, "t")
        assert am.should_auto_spawn(AgentRole.DEV, SESSION) is True

    def test_no_spawn_when_idle_exists(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        am.mark_init_finished(a.id)
        assert am.should_auto_spawn(AgentRole.DEV, SESSION) is False

    def test_no_spawn_at_max(self, am: AgentManager):
        """max_agents_per_role=2, so third should not spawn."""
        a = am.create_agent(_agent_create())
        am.mark_init_finished(a.id)
        am.mark_busy(a.id, "t1")
        b = am.create_agent(_agent_create())
        am.mark_init_finished(b.id)
        am.mark_busy(b.id, "t2")
        assert am.should_auto_spawn(AgentRole.DEV, SESSION) is False

    def test_no_spawn_for_lead(self, am: AgentManager):
        assert am.should_auto_spawn(AgentRole.LEAD, SESSION) is False


class TestDismissal:
    def test_dismiss_agent(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        dismissed = am.dismiss_agent(a.id)
        assert dismissed is not None
        assert dismissed.id == a.id
        assert am.get_agent(a.id) is None

    def test_can_dismiss(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        ok, _ = am.can_dismiss(a.id)
        assert ok is True

    def test_cannot_dismiss_reserved(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        am.set_reserved(a.id, True)
        ok, reason = am.can_dismiss(a.id)
        assert ok is False
        assert "reserved" in reason

    def test_can_force_dismiss_reserved(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        am.set_reserved(a.id, True)
        ok, _ = am.can_dismiss(a.id, force=True)
        assert ok is True

    def test_dismiss_nonexistent(self, am: AgentManager):
        ok, reason = am.can_dismiss("ghost")
        assert ok is False

    def test_unregister_cleans_up(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        am.assign_request("req-1", a.id)
        am.unregister_agent(a.id)
        assert am.get_agent_for_request("req-1") is None
        assert am.get_session_agents(SESSION) == []


class TestRequestTracking:
    def test_assign_and_lookup(self, am: AgentManager):
        a = am.create_agent(_agent_create())
        am.assign_request("req-x", a.id)
        found = am.get_agent_for_request("req-x")
        assert found is a

    def test_lookup_unknown(self, am: AgentManager):
        assert am.get_agent_for_request("nope") is None
