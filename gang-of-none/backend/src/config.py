from pydantic import BaseModel, Field


class Settings(BaseModel):
    max_agents_per_role: int = 3
    reports_dir: str = ".agent-shell/reports"
    reviews_dir: str = ".agent-shell/reviews"
    acp_binary: str = "claude-agent-acp"
    default_model: str = ""
    drain_interval_seconds: float = 2.0
    tasks_dir: str = ".agent-shell/tasks"
    db_path: str = ".agent-shell/gang-of-none.db"
    worktree_subdir: str = ".claude/worktrees"
    retry_max_attempts: int = 3
    retry_backoff_seconds: list[float] = [2.0, 5.0, 15.0]
    model_fallback_chains: dict[str, list[str]] = Field(default_factory=lambda: {
        "gemini-2.5-flash": ["gemini-2.5-flash-lite", "gemini-2.5-pro"],
    })
