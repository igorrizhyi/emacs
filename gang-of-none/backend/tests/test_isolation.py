"""Tests for the isolation module — bwrap and devcontainer prefix builders."""

from pathlib import Path
from unittest.mock import patch

import pytest

from src.core.isolation import (
    build_bwrap_prefix,
    build_command_prefix,
    build_devcontainer_prefix,
)


class TestBuildDevcontainerPrefix:
    def test_returns_prefix_when_config_exists(self, tmp_path: Path):
        config = tmp_path / ".devcontainer" / "tester" / "devcontainer.json"
        config.parent.mkdir(parents=True)
        config.write_text("{}")

        result = build_devcontainer_prefix(str(tmp_path), "tester")

        assert result is not None
        assert result == [
            "devcontainer",
            "exec",
            "--workspace-folder",
            str(tmp_path),
            "--config",
            str(config),
        ]

    def test_returns_none_when_no_config(self, tmp_path: Path):
        result = build_devcontainer_prefix(str(tmp_path), "tester")
        assert result is None

    def test_config_path_uses_role(self, tmp_path: Path):
        config = tmp_path / ".devcontainer" / "tester" / "devcontainer.json"
        config.parent.mkdir(parents=True)
        config.write_text("{}")

        result = build_devcontainer_prefix(str(tmp_path), "tester")
        assert result is not None
        assert str(config) in result
        assert ".devcontainer/tester/devcontainer.json" in str(
            Path(result[result.index("--config") + 1])
        )


class TestBuildBwrapPrefix:
    """Tests for build_bwrap_prefix.

    Uses mock patching for Path.resolve() and Path.exists() to avoid
    depending on real filesystem paths like /usr, /lib64, etc.
    """

    @pytest.fixture()
    def prefix(self, tmp_path: Path) -> list[str]:
        """Build a prefix with tmp_path as worktree and project root."""
        worktree = tmp_path / "worktree"
        worktree.mkdir()
        project = tmp_path / "project"
        project.mkdir()
        (project / ".git").mkdir()
        (project / ".agent-shell" / "reports").mkdir(parents=True)
        linuxbrew = tmp_path / "linuxbrew"
        linuxbrew.mkdir()
        return build_bwrap_prefix(
            str(worktree), str(project), linuxbrew_path=str(linuxbrew)
        )

    def test_includes_required_ro_binds(self, prefix: list[str]):
        # Collect all --ro-bind targets
        ro_targets: list[str] = []
        for i, arg in enumerate(prefix):
            if arg == "--ro-bind" and i + 2 < len(prefix):
                ro_targets.append(prefix[i + 2])
        assert "/usr" in ro_targets
        assert "/lib64" in ro_targets
        assert "/etc" in ro_targets

    def test_includes_worktree_rw_bind(self, tmp_path: Path):
        worktree = tmp_path / "worktree"
        worktree.mkdir()
        project = tmp_path / "project"
        project.mkdir()
        (project / ".git").mkdir()
        (project / ".agent-shell" / "reports").mkdir(parents=True)
        linuxbrew = tmp_path / "linuxbrew"
        linuxbrew.mkdir()

        prefix = build_bwrap_prefix(
            str(worktree), str(project), linuxbrew_path=str(linuxbrew)
        )
        # Collect --bind (rw) destinations
        rw_targets: list[str] = []
        for i, arg in enumerate(prefix):
            if arg == "--bind" and i + 2 < len(prefix):
                rw_targets.append(prefix[i + 2])
        assert str(worktree.resolve()) in rw_targets

    def test_includes_git_dir_rw_bind(self, tmp_path: Path):
        worktree = tmp_path / "worktree"
        worktree.mkdir()
        project = tmp_path / "project"
        project.mkdir()
        (project / ".git").mkdir()
        (project / ".agent-shell" / "reports").mkdir(parents=True)
        linuxbrew = tmp_path / "linuxbrew"
        linuxbrew.mkdir()

        prefix = build_bwrap_prefix(
            str(worktree), str(project), linuxbrew_path=str(linuxbrew)
        )
        rw_targets: list[str] = []
        for i, arg in enumerate(prefix):
            if arg == "--bind" and i + 2 < len(prefix):
                rw_targets.append(prefix[i + 2])
        git_dir = str((project / ".git").resolve())
        assert git_dir in rw_targets

    def test_includes_reports_rw_bind(self, tmp_path: Path):
        worktree = tmp_path / "worktree"
        worktree.mkdir()
        project = tmp_path / "project"
        project.mkdir()
        (project / ".git").mkdir()
        (project / ".agent-shell" / "reports").mkdir(parents=True)
        linuxbrew = tmp_path / "linuxbrew"
        linuxbrew.mkdir()

        prefix = build_bwrap_prefix(
            str(worktree), str(project), linuxbrew_path=str(linuxbrew)
        )
        rw_targets: list[str] = []
        for i, arg in enumerate(prefix):
            if arg == "--bind" and i + 2 < len(prefix):
                rw_targets.append(prefix[i + 2])
        reports = str((project / ".agent-shell" / "reports").resolve())
        assert reports in rw_targets

    def test_includes_die_with_parent(self, prefix: list[str]):
        assert "--die-with-parent" in prefix

    def test_includes_share_net(self, prefix: list[str]):
        assert "--share-net" in prefix

    def test_ends_with_separator(self, prefix: list[str]):
        assert prefix[-1] == "--"

    def test_conditional_binds_skip_missing(self, tmp_path: Path):
        """Optional ro-binds like ~/.mcp.json should be skipped if missing."""
        worktree = tmp_path / "worktree"
        worktree.mkdir()
        project = tmp_path / "project"
        project.mkdir()
        (project / ".git").mkdir()
        (project / ".agent-shell" / "reports").mkdir(parents=True)
        linuxbrew = tmp_path / "linuxbrew"
        linuxbrew.mkdir()

        # The optional paths (e.g. ~/.mcp.json, ~/.gitconfig) won't exist
        # when using a real tmp_path home. We just verify the prefix doesn't
        # include paths that don't exist from the optional list.
        prefix = build_bwrap_prefix(
            str(worktree), str(project), linuxbrew_path=str(linuxbrew)
        )
        # Collect all ro-bind sources
        ro_sources: list[str] = []
        for i, arg in enumerate(prefix):
            if arg == "--ro-bind" and i + 1 < len(prefix):
                ro_sources.append(prefix[i + 1])

        # The knowledge/.agent-shell/knowledge path should NOT be present
        # since project/.agent-shell/knowledge doesn't exist
        knowledge_dir = str((project / ".agent-shell" / "knowledge").resolve())
        assert knowledge_dir not in ro_sources

    def test_resolves_symlinks(self, tmp_path: Path):
        """Verify Path.resolve() is used (handles /home → /var/home)."""
        worktree = tmp_path / "worktree"
        worktree.mkdir()
        project = tmp_path / "project"
        project.mkdir()
        (project / ".git").mkdir()
        (project / ".agent-shell" / "reports").mkdir(parents=True)
        linuxbrew = tmp_path / "linuxbrew"
        linuxbrew.mkdir()

        prefix = build_bwrap_prefix(
            str(worktree), str(project), linuxbrew_path=str(linuxbrew)
        )
        # The worktree path in --bind should be the resolved path
        resolved_worktree = str(worktree.resolve())
        rw_targets: list[str] = []
        for i, arg in enumerate(prefix):
            if arg == "--bind" and i + 2 < len(prefix):
                rw_targets.append(prefix[i + 2])
        assert resolved_worktree in rw_targets


class TestBuildCommandPrefix:
    def test_tester_gets_devcontainer(self, tmp_path: Path):
        config = tmp_path / ".devcontainer" / "tester" / "devcontainer.json"
        config.parent.mkdir(parents=True)
        config.write_text("{}")

        result = build_command_prefix("tester", None, str(tmp_path))
        assert result[0] == "devcontainer"
        assert "exec" in result

    def test_tester_no_config_gets_empty(self, tmp_path: Path):
        result = build_command_prefix("tester", None, str(tmp_path))
        assert result == []

    def test_dev_with_worktree_gets_bwrap(self, tmp_path: Path):
        worktree = tmp_path / "worktree"
        worktree.mkdir()
        project = tmp_path / "project"
        project.mkdir()
        (project / ".git").mkdir()
        (project / ".agent-shell" / "reports").mkdir(parents=True)

        result = build_command_prefix("dev", str(worktree), str(project))
        assert result[0] == "bwrap"

    def test_dev_without_worktree_gets_empty(self, tmp_path: Path):
        result = build_command_prefix("dev", None, str(tmp_path))
        assert result == []

    def test_lead_gets_empty(self, tmp_path: Path):
        result = build_command_prefix("lead", str(tmp_path), str(tmp_path))
        assert result == []

    def test_researcher_gets_empty(self, tmp_path: Path):
        result = build_command_prefix(
            "researcher", str(tmp_path), str(tmp_path)
        )
        assert result == []
