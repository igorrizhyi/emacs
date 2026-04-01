"""Agent lifecycle manager: registration, status, spawn decisions, dismissal."""

from __future__ import annotations

import random

from ..config import Settings
from ..models.agent import Agent, AgentCreate
from ..models.enums import AgentRole, AgentStatus

_ADJECTIVES = [
    "brave", "calm", "daring", "eager", "fair", "gentle", "happy",
    "jolly", "keen", "lively", "merry", "noble", "proud", "quick",
    "sharp", "tender", "vibrant", "warm", "zealous", "bold",
    "focused", "gracious", "humble", "inventive", "jovial",
    "kind", "lucid", "modest", "nimble", "optimistic",
    "patient", "quirky", "resilient", "serene", "thoughtful",
    "upbeat", "vivid", "witty", "xenial", "youthful",
    "agile", "bright", "clever", "diligent", "earnest",
    "fervent", "gifted", "heroic", "inspired", "judicious",
    "pedantic", "distracted",
]

_SCIENTISTS = [
    "turing", "lovelace", "dijkstra", "knuth", "hopper",
    "curie", "einstein", "feynman", "shannon", "bohr",
    "euler", "gauss", "newton", "pascal", "babbage",
    "tesla", "faraday", "maxwell", "planck", "heisenberg",
    "noether", "ramanujan", "erdos", "hilbert", "godel",
    "church", "kleene", "curry", "mccarthy", "backus",
    "ritchie", "thompson", "kernighan", "wirth", "hoare",
    "milner", "strachey", "landin", "wadler", "hughes",
    "khorana", "elgamal", "pare", "leakey", "cartwright",
]


class AgentManager:
    """Manages agent lifecycle: registration, status, spawn, dismissal."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._agents: dict[str, Agent] = {}
        self._sessions: dict[str, list[str]] = {}
        self._request_to_agent: dict[str, str] = {}

    # ── Registration ──────────────────────────────────────────────

    def register_agent(self, agent: Agent) -> None:
        """Register an agent in the registry."""
        self._agents[agent.id] = agent
        self._sessions.setdefault(agent.session_id, []).append(agent.id)

    def unregister_agent(self, agent_id: str) -> Agent | None:
        """Remove agent from registry. Returns the removed Agent or None."""
        agent = self._agents.pop(agent_id, None)
        if agent is None:
            return None
        # Remove from session list
        session_ids = self._sessions.get(agent.session_id)
        if session_ids is not None:
            try:
                session_ids.remove(agent_id)
            except ValueError:
                pass
            if not session_ids:
                del self._sessions[agent.session_id]
        # Remove any request mappings pointing to this agent
        stale_keys = [k for k, v in self._request_to_agent.items() if v == agent_id]
        for k in stale_keys:
            del self._request_to_agent[k]
        return agent

    # ── Factory ───────────────────────────────────────────────────

    def create_agent(
        self,
        create: AgentCreate,
        worktree_name: str | None = None,
        worktree_path: str | None = None,
        ephemeral: bool = False,
    ) -> Agent:
        """Create a new Agent, register it, and return it."""
        agent_id = self._generate_agent_name()
        agent = Agent(
            id=agent_id,
            role=create.role,
            session_id=create.session_id,
            worktree_name=worktree_name or agent_id,
            worktree_path=worktree_path,
            ephemeral=ephemeral,
        )
        self.register_agent(agent)
        return agent

    def _generate_agent_name(self) -> str:
        """Generate a unique adjective-scientist name (e.g. 'vibrant-pare')."""
        existing = set(self._agents)
        for _ in range(200):
            name = f"{random.choice(_ADJECTIVES)}-{random.choice(_SCIENTISTS)}"
            if name not in existing:
                return name
        # Fallback: append a disambiguator
        base = f"{random.choice(_ADJECTIVES)}-{random.choice(_SCIENTISTS)}"
        return f"{base}-{random.randint(1000, 9999)}"

    # ── Status management ─────────────────────────────────────────

    def get_status(self, agent_id: str) -> AgentStatus | None:
        agent = self._agents.get(agent_id)
        return agent.status if agent else None

    def set_status(self, agent_id: str, status: AgentStatus) -> None:
        """Update agent status."""
        agent = self._agents.get(agent_id)
        if agent is not None:
            agent.status = status

    def mark_busy(self, agent_id: str, task_id: str) -> None:
        """Mark agent as busy with a specific task."""
        agent = self._agents.get(agent_id)
        if agent is not None:
            agent.status = AgentStatus.BUSY
            agent.current_task_id = task_id

    def mark_idle(self, agent_id: str) -> None:
        """Mark agent as idle, clear current task."""
        agent = self._agents.get(agent_id)
        if agent is not None:
            agent.status = AgentStatus.IDLE
            agent.current_task_id = None

    def mark_init_finished(self, agent_id: str) -> None:
        """Mark agent initialization as complete."""
        agent = self._agents.get(agent_id)
        if agent is not None:
            agent.init_finished = True
            agent.status = AgentStatus.IDLE

    # ── Lookup ────────────────────────────────────────────────────

    def get_agent(self, agent_id: str) -> Agent | None:
        return self._agents.get(agent_id)

    def get_agents_by_role(
        self, role: AgentRole, session_id: str | None = None,
    ) -> list[Agent]:
        agents = (a for a in self._agents.values() if a.role == role)
        if session_id is not None:
            agents = (a for a in agents if a.session_id == session_id)
        return list(agents)

    def get_idle_agents(
        self, role: AgentRole, session_id: str | None = None,
    ) -> list[Agent]:
        """Get idle, non-reserved agents for a role."""
        return [
            a for a in self.get_agents_by_role(role, session_id)
            if a.status == AgentStatus.IDLE and not a.reserved
        ]

    def get_session_agents(self, session_id: str) -> list[Agent]:
        ids = self._sessions.get(session_id, [])
        return [self._agents[aid] for aid in ids if aid in self._agents]

    def get_lead(self, session_id: str) -> Agent | None:
        """Get lead agent for session."""
        for agent in self.get_session_agents(session_id):
            if agent.role == AgentRole.LEAD:
                return agent
        return None

    def find_agent_by_name(self, name: str) -> Agent | None:
        """Find agent by worktree_name, buffer_name, id, or substring match."""
        # Exact matches first
        for agent in self._agents.values():
            if name in (agent.id, agent.worktree_name, agent.buffer_name):
                return agent
        # Substring match fallback
        name_lower = name.lower()
        for agent in self._agents.values():
            for field in (agent.id, agent.worktree_name, agent.buffer_name):
                if field and name_lower in field.lower():
                    return agent
        return None

    # ── Auto-spawn decision ───────────────────────────────────────

    def should_auto_spawn(self, role: AgentRole, session_id: str) -> bool:
        """Check if we should auto-spawn a new agent for this role."""
        if role in (AgentRole.LEAD,):
            return False
        current = self.get_agent_count(role, session_id)
        if current >= self.settings.max_agents_per_role:
            return False
        idle = self.get_idle_agents(role, session_id)
        return len(idle) == 0

    def get_agent_count(self, role: AgentRole, session_id: str | None = None) -> int:
        return len(self.get_agents_by_role(role, session_id))

    # ── Dismissal ─────────────────────────────────────────────────

    def can_dismiss(self, agent_id: str, force: bool = False) -> tuple[bool, str]:
        """Check if agent can be dismissed. Returns (allowed, reason)."""
        agent = self._agents.get(agent_id)
        if agent is None:
            return False, "agent not found"
        if agent.reserved and not force:
            return False, "agent is reserved (use force=True to override)"
        return True, ""

    def dismiss_agent(self, agent_id: str) -> Agent | None:
        """Dismiss and unregister agent. Returns the dismissed Agent."""
        return self.unregister_agent(agent_id)

    # ── Reserved / ephemeral ──────────────────────────────────────

    def set_reserved(self, agent_id: str, reserved: bool) -> None:
        agent = self._agents.get(agent_id)
        if agent is not None:
            agent.reserved = reserved

    def set_ephemeral(self, agent_id: str, ephemeral: bool) -> None:
        agent = self._agents.get(agent_id)
        if agent is not None:
            agent.ephemeral = ephemeral

    def get_reserved_agents(self) -> list[Agent]:
        return [a for a in self._agents.values() if a.reserved]

    # ── Request tracking ──────────────────────────────────────────

    def assign_request(self, request_id: str, agent_id: str) -> None:
        """Track which agent is handling which request."""
        self._request_to_agent[request_id] = agent_id

    def get_agent_for_request(self, request_id: str) -> Agent | None:
        """Find agent handling a specific request."""
        agent_id = self._request_to_agent.get(request_id)
        if agent_id is None:
            return None
        return self._agents.get(agent_id)
