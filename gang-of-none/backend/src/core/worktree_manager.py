"""Worktree manager — git worktree lifecycle for agent isolation."""

from __future__ import annotations

import asyncio
import shutil

import structlog

from ..config import Settings
from ..models.agent import WorktreeInfo

logger = structlog.get_logger()


class WorktreeError(Exception):
    """Raised when a git worktree operation fails."""


class WorktreeManager:
    """Manages git worktree creation, removal, and cleanup for agents."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    # ── Helpers ────────────────────────────────────────────────────

    @staticmethod
    async def _run_git(
        *args: str, cwd: str | None = None,
    ) -> tuple[int, str, str]:
        """Run a git command asynchronously. Returns (returncode, stdout, stderr)."""
        proc = await asyncio.create_subprocess_exec(
            "git", *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=cwd,
        )
        stdout_bytes, stderr_bytes = await proc.communicate()
        return (
            proc.returncode or 0,
            stdout_bytes.decode().strip(),
            stderr_bytes.decode().strip(),
        )

    async def _is_inside_worktree(self, project_root: str) -> bool:
        """Detect if project_root is itself inside a worktree (not the main repo).

        Compares git toplevel with the parent of the common git dir.
        If they differ, we're inside a worktree.
        """
        rc_top, toplevel, _ = await self._run_git(
            "rev-parse", "--show-toplevel", cwd=project_root,
        )
        rc_common, common_dir, _ = await self._run_git(
            "rev-parse", "--path-format=absolute", "--git-common-dir",
            cwd=project_root,
        )
        if rc_top != 0 or rc_common != 0:
            return False

        # For a main worktree, common_dir is <toplevel>/.git
        # For a linked worktree, common_dir is <main-repo>/.git
        # If toplevel/.git != common_dir, we're in a linked worktree
        import os
        expected_git_dir = os.path.join(toplevel, ".git")
        return os.path.normpath(expected_git_dir) != os.path.normpath(common_dir)

    # ── Create ────────────────────────────────────────────────────

    async def create_worktree(
        self, agent_name: str, project_root: str,
    ) -> WorktreeInfo:
        """Create a git worktree for an agent.

        Args:
            agent_name: Name for the worktree (becomes branch name too).
            project_root: Root of the git repository.

        Returns:
            WorktreeInfo with path, name, and branch.

        Raises:
            WorktreeError: If creation fails or nesting is detected.
        """
        if await self._is_inside_worktree(project_root):
            raise WorktreeError(
                f"Refusing to create nested worktree: {project_root} "
                "is already inside a worktree"
            )

        import os
        wt_path = os.path.join(
            project_root, self.settings.worktree_subdir, agent_name,
        )

        rc, stdout, stderr = await self._run_git(
            "worktree", "add", wt_path, "-b", agent_name,
            cwd=project_root,
        )
        if rc != 0:
            raise WorktreeError(
                f"git worktree add failed (rc={rc}): {stderr or stdout}"
            )

        logger.info(
            "worktree.created",
            path=wt_path, name=agent_name, branch=agent_name,
        )
        return WorktreeInfo(path=wt_path, name=agent_name, branch=agent_name)

    # ── Remove ────────────────────────────────────────────────────

    async def remove_worktree(self, path: str) -> bool:
        """Remove a git worktree by path.

        Falls back to shutil.rmtree + git worktree prune if git remove fails.
        Returns True on success.
        """
        rc, _, stderr = await self._run_git("worktree", "remove", "--force", path)
        if rc == 0:
            logger.info("worktree.removed", path=path)
            return True

        logger.warning(
            "worktree.remove_failed_fallback",
            path=path, stderr=stderr,
        )
        try:
            shutil.rmtree(path)
        except FileNotFoundError:
            pass
        except OSError as exc:
            logger.error("worktree.rmtree_failed", path=path, error=str(exc))
            return False

        # Prune stale worktree references
        await self._run_git("worktree", "prune")
        logger.info("worktree.removed_fallback", path=path)
        return True

    # ── List ──────────────────────────────────────────────────────

    async def list_worktrees(self, project_root: str) -> list[WorktreeInfo]:
        """List all worktrees under the configured worktree_subdir.

        Parses `git worktree list --porcelain` output.
        """
        rc, stdout, stderr = await self._run_git(
            "worktree", "list", "--porcelain", cwd=project_root,
        )
        if rc != 0:
            logger.warning("worktree.list_failed", stderr=stderr)
            return []

        results: list[WorktreeInfo] = []
        # Porcelain format: blocks separated by blank lines
        # Each block has lines like:
        #   worktree /path/to/worktree
        #   HEAD <sha>
        #   branch refs/heads/<name>
        subdir = self.settings.worktree_subdir
        current_path: str | None = None
        current_branch: str | None = None

        for line in stdout.split("\n"):
            if line.startswith("worktree "):
                current_path = line[len("worktree "):]
                current_branch = None
            elif line.startswith("branch "):
                ref = line[len("branch "):]
                # refs/heads/name -> name
                current_branch = ref.rsplit("/", 1)[-1]
            elif line == "" and current_path is not None:
                # End of a worktree block — check if it's under our subdir
                if subdir in current_path:
                    import os
                    name = os.path.basename(current_path)
                    results.append(WorktreeInfo(
                        path=current_path,
                        name=name,
                        branch=current_branch or name,
                    ))
                current_path = None
                current_branch = None

        # Handle last block if stdout doesn't end with blank line
        if current_path is not None and subdir in current_path:
            import os
            name = os.path.basename(current_path)
            results.append(WorktreeInfo(
                path=current_path,
                name=name,
                branch=current_branch or name,
            ))

        return results

    # ── Cleanup ───────────────────────────────────────────────────

    async def cleanup_all(self, project_root: str) -> int:
        """Remove all worktrees under the worktree_subdir.

        Returns the number of worktrees removed.
        """
        worktrees = await self.list_worktrees(project_root)
        removed = 0
        for wt in worktrees:
            if await self.remove_worktree(wt.path):
                removed += 1

        # Final prune to clean up any stale refs
        await self._run_git("worktree", "prune", cwd=project_root)
        logger.info("worktree.cleanup_all", removed=removed)
        return removed
