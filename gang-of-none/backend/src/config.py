from pydantic import BaseModel


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
