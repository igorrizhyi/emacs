"""Agent process isolation — bwrap and devcontainer command prefix builders.

Builds command prefixes that sandbox agent processes using either bubblewrap
(bwrap) for dev agents or devcontainer exec for tester agents.
"""

from __future__ import annotations

import os
from pathlib import Path


def build_devcontainer_prefix(project_dir: str, role: str) -> list[str] | None:
    """Build a devcontainer exec command prefix if a role-specific config exists.

    Checks for ``<project_dir>/.devcontainer/<role>/devcontainer.json``.
    Returns the prefix list or ``None`` if no config is found.
    """
    config_path = Path(project_dir) / ".devcontainer" / role / "devcontainer.json"
    if not config_path.exists():
        return None
    return [
        "devcontainer",
        "exec",
        "--workspace-folder",
        project_dir,
        "--config",
        str(config_path),
    ]


def build_bwrap_prefix(
    worktree_path: str,
    project_root: str,
    *,
    linuxbrew_path: str = "/var/home/linuxbrew/.linuxbrew",
) -> list[str]:
    """Build a bubblewrap (bwrap) command prefix for filesystem sandboxing.

    Uses ``pathlib.Path.resolve()`` for all paths to handle Fedora's
    ``/home`` → ``/var/home`` symlink transparently.
    """
    worktree = Path(worktree_path).resolve()
    project = Path(project_root).resolve()
    linuxbrew = Path(linuxbrew_path).resolve()
    uid = os.getuid()

    home = Path.home().resolve()
    claude_data = home / ".local" / "share" / "claude"
    claude_config = home / ".claude"
    git_dir = project / ".git"
    reports_dir = project / ".agent-shell" / "reports"

    cmd: list[str] = [
        "bwrap",
        # System dirs (ro)
        "--ro-bind", "/usr", "/usr",
        "--ro-bind", "/lib64", "/lib64",
        "--ro-bind", "/etc", "/etc",
        # Fedora symlinks
        "--symlink", "/var/home", "/home",
        "--symlink", "usr/bin", "/bin",
        "--symlink", "usr/sbin", "/sbin",
        # Homebrew (ro) — provides node, claude-agent-acp
        "--ro-bind", str(linuxbrew), str(linuxbrew),
        # Claude data (ro) and config (rw)
        "--ro-bind", str(claude_data), str(claude_data),
        "--bind", str(claude_config), str(claude_config),
    ]

    # Conditional ro-binds (only if path exists)
    optional_ro: list[Path] = [
        home / ".mcp.json",
        home / ".gitconfig",
        home / ".config" / "git",
        project / ".agent-shell" / "knowledge",
        home / ".config" / "doom",
        home / ".config" / "emacs" / ".local" / "straight",
    ]
    for p in optional_ro:
        resolved = p.resolve()
        if resolved.exists():
            cmd.extend(["--ro-bind", str(resolved), str(resolved)])

    cmd.extend([
        # Git (rw)
        "--bind", str(git_dir), str(git_dir),
        # Worktree (rw)
        "--bind", str(worktree), str(worktree),
        # Reports (rw)
        "--bind", str(reports_dir), str(reports_dir),
        # Virtual filesystems
        "--dev", "/dev",
        "--proc", "/proc",
        "--tmpfs", "/tmp",
        # DNS resolver (Fedora systemd-resolved)
        "--ro-bind", "/run/systemd/resolve", "/run/systemd/resolve",
        # Emacs server sockets (rw)
        "--bind", f"/run/user/{uid}/emacs", f"/run/user/{uid}/emacs",
        # Flags
        "--share-net",
        "--die-with-parent",
        "--chdir", str(worktree),
        "--",
    ])

    return cmd


def build_command_prefix(
    role: str,
    worktree_path: str | None,
    project_root: str | None,
    *,
    linuxbrew_path: str = "/var/home/linuxbrew/.linuxbrew",
) -> list[str]:
    """Build the isolation command prefix based on agent role.

    Decision logic (matches Elisp reference):
    - ``tester`` → try devcontainer, fall back to no isolation
    - ``dev`` with a worktree → bwrap
    - everything else → no isolation
    """
    if role == "tester" and project_root:
        prefix = build_devcontainer_prefix(project_root, role)
        if prefix is not None:
            return prefix
        return []

    if role == "dev" and worktree_path and project_root:
        return build_bwrap_prefix(
            worktree_path,
            project_root,
            linuxbrew_path=linuxbrew_path,
        )

    return []
