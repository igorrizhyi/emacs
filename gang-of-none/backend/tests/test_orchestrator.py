"""Tests for Orchestrator — model fallback in _spawn_agent."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from src.config import Settings
from src.core.agent_manager import AgentManager
from src.core.orchestrator import Orchestrator
from src.core.worktree_manager import WorktreeManager
from src.models.enums import AgentRole, AgentStatus


def _make_orchestrator(
    settings: Settings | None = None,
    acp_create_session: AsyncMock | None = None,
) -> Orchestrator:
    """Build an Orchestrator with mocked dependencies."""
    settings = settings or Settings()
    agent_mgr = AgentManager(settings)
    acp_mgr = MagicMock()
    acp_mgr.create_session = acp_create_session or AsyncMock()
    worktree_mgr = MagicMock(spec=WorktreeManager)
    worktree_mgr.create_worktree = AsyncMock()
    worktree_mgr.remove_worktree = AsyncMock()

    return Orchestrator(
        settings=settings,
        task_manager=MagicMock(),
        agent_manager=agent_mgr,
        acp_session_manager=acp_mgr,
        worktree_manager=worktree_mgr,
    )


SESSION = "test-session"


class TestSpawnWithFallback:
    async def test_succeeds_on_second_model(self):
        """Primary model fails (retryable), fallback succeeds."""
        settings = Settings(
            model_fallback_chains={"flash": ["flash-lite"]},
        )
        mock_create = AsyncMock(
            side_effect=[
                RuntimeError("No capacity available"),
                None,  # flash-lite succeeds
            ]
        )
        orch = _make_orchestrator(settings=settings, acp_create_session=mock_create)

        agent = await orch._spawn_agent(AgentRole.DEV, SESSION, model="flash")

        assert agent is not None
        assert agent.model == "flash-lite"
        assert agent.status == AgentStatus.IDLE  # init finished
        assert mock_create.await_count == 2

    async def test_without_fallback_chain(self):
        """Model not in fallback_chains — single attempt, succeeds."""
        mock_create = AsyncMock()
        orch = _make_orchestrator(acp_create_session=mock_create)

        agent = await orch._spawn_agent(AgentRole.DEV, SESSION, model="opus")

        assert agent is not None
        assert agent.model == "opus"
        mock_create.assert_awaited_once()

    async def test_all_fallbacks_exhausted(self):
        """All models fail with retryable errors — returns None, agent dismissed."""
        settings = Settings(
            model_fallback_chains={"flash": ["flash-lite", "haiku"]},
        )
        mock_create = AsyncMock(
            side_effect=RuntimeError("No capacity available"),
        )
        orch = _make_orchestrator(settings=settings, acp_create_session=mock_create)

        agent = await orch._spawn_agent(AgentRole.DEV, SESSION, model="flash")

        assert agent is None
        assert mock_create.await_count == 3  # flash, flash-lite, haiku

    async def test_agent_model_field_set(self):
        """After fallback, agent.model reflects the actual model used."""
        settings = Settings(
            model_fallback_chains={"sonnet": ["haiku"]},
        )
        mock_create = AsyncMock(
            side_effect=[
                RuntimeError("No capacity available"),
                None,
            ]
        )
        orch = _make_orchestrator(settings=settings, acp_create_session=mock_create)

        agent = await orch._spawn_agent(AgentRole.DEV, SESSION, model="sonnet")

        assert agent is not None
        assert agent.model == "haiku"

    async def test_non_retryable_error_raises(self):
        """Non-retryable RuntimeError is not caught by fallback logic."""
        settings = Settings(
            model_fallback_chains={"flash": ["flash-lite"]},
        )
        mock_create = AsyncMock(
            side_effect=RuntimeError("Invalid API key"),
        )
        orch = _make_orchestrator(settings=settings, acp_create_session=mock_create)

        with pytest.raises(RuntimeError, match="Invalid API key"):
            await orch._spawn_agent(AgentRole.DEV, SESSION, model="flash")

        # Should fail on first attempt without trying fallback
        mock_create.assert_awaited_once()

    async def test_non_runtime_error_raises(self):
        """Non-RuntimeError exceptions are re-raised immediately."""
        mock_create = AsyncMock(
            side_effect=ValueError("unexpected"),
        )
        orch = _make_orchestrator(acp_create_session=mock_create)

        with pytest.raises(ValueError, match="unexpected"):
            await orch._spawn_agent(AgentRole.DEV, SESSION, model="flash")
