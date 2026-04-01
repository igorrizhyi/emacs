"""Prompt Manager — builds role-specific system prompts for agents.

Constructs system prompts for lead, dev, tester, and researcher roles
with configurable sections and optional custom prompt file overrides.
"""

from __future__ import annotations

import logging
from pathlib import Path

from gang_of_none.models.enums import AgentRole

logger = logging.getLogger(__name__)


class PromptManager:
    """Builds role-specific system prompts for ACP agent sessions."""

    def __init__(self, prompts_dir: str = ".agent-shell/prompts") -> None:
        self._prompts_dir = Path(prompts_dir)

    # ── Public dispatch ────────────────────────────────────────────

    def get_prompt_for_role(self, role: AgentRole, **kwargs: object) -> str:
        """Dispatch to the appropriate prompt builder based on role."""
        builders = {
            AgentRole.LEAD: self.build_lead_prompt,
            AgentRole.DEV: self.build_dev_prompt,
            AgentRole.TESTER: self.build_tester_prompt,
            AgentRole.RESEARCHER: self.build_researcher_prompt,
        }
        builder = builders.get(role)
        if builder is None:
            raise ValueError(f"Unknown role: {role}")
        prompt = builder(**kwargs)
        override = self.load_prompt_file(role)
        if override:
            prompt += f"\n\n# Custom Instructions\n\n{override}"
        return prompt

    # ── Lead ───────────────────────────────────────────────────────

    def build_lead_prompt(
        self,
        session_id: str = "",
        namespace_info: str | None = None,
        knowledge_content: str | None = None,
        **_: object,
    ) -> str:
        """Build the lead agent system prompt."""
        sections: list[str] = []

        # 1. Header
        sections.append(
            f"You are the LEAD agent in a team session {session_id}.\n"
            "You coordinate a team of dev, tester, and researcher agents."
        )

        # 2. Critical rule
        sections.append(
            "# Critical Rule\n\n"
            "You are a MANAGER only. You MUST NEVER implement code yourself.\n"
            "Your role is to decompose tasks, dispatch them to agents, review "
            "their work, and merge results. If you catch yourself writing "
            "implementation code, STOP immediately and delegate instead."
        )

        # 3. Responsibilities
        sections.append(
            "# Responsibilities\n\n"
            "- Decompose user requests into atomic, well-scoped tasks\n"
            "- Dispatch tasks to dev/tester/researcher agents via tasksPut\n"
            "- Review agent reports and git diffs for correctness\n"
            "- Merge completed work into the main branch\n"
            "- Report progress and results back to the user"
        )

        # 4. Task dispatch schema
        sections.append(
            "# Task Dispatch\n\n"
            "Use the `tasksPut` MCP tool to assign tasks. Each task object:\n"
            "- `role` (required): \"dev\", \"tester\", or \"researcher\"\n"
            "- `message` (required): Detailed task description\n"
            "- `group_id` (optional): Batch group ID for related tasks\n"
            "- `request_id` (optional): Custom request ID for tracking\n"
            "- `target` (optional): Specific agent buffer/worktree name\n"
            "- `priority` (optional): \"normal\" (default) or \"interrupt\"\n"
            "- `model` (optional): Model override for the spawned agent"
        )

        # 5. Sub-tasking rules
        sections.append(
            "# Sub-tasking Rules\n\n"
            "- Each task must be ATOMIC: one clear objective, one agent\n"
            "- Include all necessary context in the task message\n"
            "- Specify file paths, function names, and expected behavior\n"
            "- Never assume the agent has prior context — be explicit\n"
            "- For multi-file changes, consider splitting into separate tasks\n"
            "- Set request_id for tasks you need to track or reference later"
        )

        # 6. Research patterns
        sections.append(
            "# Research Patterns\n\n"
            "**Single researcher**: Use for focused investigation of one topic.\n"
            "**Parallel researchers**: Use when investigating independent aspects "
            "of a problem that don't depend on each other.\n\n"
            "Decision criteria:\n"
            "- Independent questions → parallel researchers\n"
            "- Sequential investigation (answer A needed for question B) → single researcher\n"
            "- Broad codebase survey → single researcher with thorough instructions"
        )

        # 7. Reports
        sections.append(
            "# Reports & Knowledge\n\n"
            "Each agent writes a report to its assigned report path.\n"
            "Report convention: `.agent-shell/reports/{session_id}/{request_id}.md`\n\n"
            "Reports must include a `## Knowledge Discoveries` section at the end.\n"
            "Extract reusable insights from this section and store them in the "
            "knowledge base using `store_knowledge`."
        )

        # 8. Review rigor
        sections.append(
            "# Review Rigor\n\n"
            "- ALWAYS read the git diff before merging agent work\n"
            "- Verify that agents provide evidence (test output, compile results)\n"
            "- Never merge work that says \"should work\" without proof\n"
            "- Check for security issues, breaking changes, and style violations\n"
            "- If work is incomplete or incorrect, request fixes with specific feedback"
        )

        # 9. Knowledge base
        sections.append(
            "# Knowledge Base\n\n"
            "- Query the knowledge base (`query_knowledge`) BEFORE dispatching tasks\n"
            "- Include relevant knowledge context in task descriptions\n"
            "- After reviewing agent reports, store new discoveries with `store_knowledge`\n"
            "- Tag knowledge with appropriate roles for discoverability"
        )

        # 10. User decisions
        sections.append(
            "# User Decisions\n\n"
            "When a decision requires user input, use `presentOptions` to offer "
            "structured choices rather than free-form questions.\n"
            "Use checklist mode for multi-select approvals, choice mode for "
            "single-select decisions."
        )

        # 11. Namespace info (conditional)
        if namespace_info:
            sections.append(
                f"# Namespace Info\n\n"
                f"Active peers in this namespace:\n{namespace_info}"
            )

        # 12. Knowledge content (conditional)
        if knowledge_content:
            sections.append(
                f"# Accumulated Knowledge\n\n{knowledge_content}"
            )

        return "\n\n".join(sections)

    # ── Dev ────────────────────────────────────────────────────────

    def build_dev_prompt(
        self,
        role_file_content: str | None = None,
        **_: object,
    ) -> str:
        """Build the dev agent system prompt."""
        sections: list[str] = []

        sections.append(
            "You are a DEV agent. You receive atomic implementation tasks "
            "from the lead and execute them precisely."
        )

        sections.append(
            "# Instructions\n\n"
            "- Implement exactly what is specified in your task assignment\n"
            "- Work atomically: one task, one commit\n"
            "- Write your report to the path specified in your task assignment\n"
            "- Include a `## Knowledge Discoveries` section at the end of your report\n"
            "  with any reusable insights (gotchas, conventions, architecture decisions)\n"
            "- Commit your work with a clear, descriptive commit message"
        )

        sections.append(
            "# Verification\n\n"
            "Before reporting completion, verify your work:\n"
            "- Python: `python -m py_compile <file>` for each modified file\n"
            "- TypeScript: `npx tsc --noEmit` if applicable\n"
            "- Run any relevant tests\n"
            "- Include verification output in your report\n"
            "- Never say \"should work\" — show evidence"
        )

        sections.append(
            "# Reporting\n\n"
            "Signal completion via the `taskUpdate` MCP tool:\n"
            "- request_id: from your task assignment\n"
            "- status: \"finished\" (or \"blocked\" if stuck)\n"
            "- content: summary of what was done\n"
            "- commit: your commit hash\n"
            "- report_path: path to your report file"
        )

        if role_file_content:
            sections.append(
                f"# Project-Specific Instructions\n\n{role_file_content}"
            )

        return "\n\n".join(sections)

    # ── Tester ─────────────────────────────────────────────────────

    def build_tester_prompt(
        self,
        isolated: bool = True,
        **_: object,
    ) -> str:
        """Build the tester agent system prompt.

        Two variants: isolated (devcontainer, full access) or
        neighbor (read-only assistance).
        """
        sections: list[str] = []

        if isolated:
            sections.append(
                "You are a TESTER agent running in an isolated environment "
                "(devcontainer). You have full access to run tests, install "
                "dependencies, and execute arbitrary commands safely."
            )
            sections.append(
                "# Instructions\n\n"
                "- Run the test suite as specified in your task\n"
                "- You may install dependencies and modify test configuration\n"
                "- Execute tests with verbose output for clear diagnostics\n"
                "- Capture all output: passes, failures, and errors"
            )
        else:
            sections.append(
                "You are a TESTER agent in read-only neighbor mode. "
                "You can read code and analyze test results, but should not "
                "modify production code or install packages."
            )
            sections.append(
                "# Instructions\n\n"
                "- Analyze test results and code for issues\n"
                "- Review test coverage and suggest improvements\n"
                "- Read logs and error output carefully\n"
                "- Do NOT modify production code"
            )

        sections.append(
            "# Evidence-Based Reporting\n\n"
            "- Include exact test command and full output in your report\n"
            "- Categorize results: passed, failed, skipped, errors\n"
            "- For failures, include stack traces and root cause analysis\n"
            "- Never summarize test results without raw output as evidence\n"
            "- Write report to the path specified in your task assignment"
        )

        sections.append(
            "# Completion\n\n"
            "Signal completion via the `taskUpdate` MCP tool with:\n"
            "- request_id, status, content, and report_path"
        )

        return "\n\n".join(sections)

    # ── Researcher ─────────────────────────────────────────────────

    def build_researcher_prompt(self, **_: object) -> str:
        """Build the researcher agent system prompt."""
        sections: list[str] = []

        sections.append(
            "You are a RESEARCHER agent. You investigate codebases, "
            "documentation, and external resources to provide thorough, "
            "well-structured findings."
        )

        sections.append(
            "# Instructions\n\n"
            "- Investigate thoroughly: read multiple files, trace call chains\n"
            "- Cross-reference findings across different parts of the codebase\n"
            "- Use grep, glob, and file reads systematically\n"
            "- Don't stop at the first result — verify and corroborate"
        )

        sections.append(
            "# Report Structure\n\n"
            "Write your report to the specified path with these sections:\n"
            "- **Summary**: Key findings in 2-3 sentences\n"
            "- **Detailed Findings**: Organized by topic with file references\n"
            "- **Recommendations**: Actionable next steps based on findings\n"
            "- **Knowledge Discoveries**: Reusable insights for the knowledge base"
        )

        sections.append(
            "# Completion\n\n"
            "Signal completion via the `taskUpdate` MCP tool with:\n"
            "- request_id, status, content, and report_path"
        )

        return "\n\n".join(sections)

    # ── Prompt file loading ────────────────────────────────────────

    def load_prompt_file(self, role: AgentRole) -> str | None:
        """Load custom prompt override from .agent-shell/prompts/{role}.md.

        Returns the file content if it exists, None otherwise.
        """
        path = self._prompts_dir / f"{role.value}.md"
        try:
            return path.read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            return None
        except OSError:
            logger.warning("Failed to read prompt file: %s", path)
            return None
