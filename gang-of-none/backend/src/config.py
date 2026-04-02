from pathlib import Path

from pydantic import BaseModel, Field

_BACKEND_DIR = Path(__file__).resolve().parent.parent


class Settings(BaseModel):
    max_agents_per_role: int = 3
    reports_dir: str = str(_BACKEND_DIR / "reports")
    reviews_dir: str = str(_BACKEND_DIR / "reviews")
    acp_binary: str = "claude-agent-acp"
    default_model: str = ""
    drain_interval_seconds: float = 2.0
    tasks_dir: str = str(_BACKEND_DIR / "tasks")
    db_path: str = str(_BACKEND_DIR / "gang-of-none.db")
    worktree_subdir: str = ".claude/worktrees"
    bwrap_binary: str = "bwrap"
    devcontainer_binary: str = "devcontainer"
    linuxbrew_path: str = "/var/home/linuxbrew/.linuxbrew"
    retry_max_attempts: int = 3
    retry_backoff_seconds: list[float] = [2.0, 5.0, 15.0]
    mcp_server_port: int = 8000
    knowledge_mcp_url: str | None = None
    model_fallback_chains: dict[str, list[str]] = Field(default_factory=lambda: {
        "gemini-2.5-flash": ["gemini-2.5-flash-lite", "gemini-2.5-pro"],
    })
