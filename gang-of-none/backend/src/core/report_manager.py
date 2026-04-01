"""Report file management — create, read, list, and extract knowledge."""

from __future__ import annotations

import re
from pathlib import Path

import structlog

from ..models.report import ReportInfo

logger = structlog.get_logger()


class ReportManager:
    """Manages report files stored at ``{reports_dir}/{session_id}/{request_id}.md``."""

    def __init__(self, reports_dir: str = ".agent-shell/reports") -> None:
        self._reports_dir = reports_dir

    def _report_path(self, session_id: str, request_id: str) -> Path:
        return Path(self._reports_dir) / session_id / f"{request_id}.md"

    def pre_create(self, session_id: str, request_id: str) -> str:
        """Create an empty report file, ensuring parent directories exist.

        Returns the path as a string.
        """
        path = self._report_path(session_id, request_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            path.write_text("", encoding="utf-8")
        logger.debug("report.pre_created", session_id=session_id, request_id=request_id)
        return str(path)

    def read_report(self, session_id: str, request_id: str) -> str | None:
        """Read report file content, or ``None`` if the file doesn't exist."""
        path = self._report_path(session_id, request_id)
        if not path.is_file():
            return None
        return path.read_text(encoding="utf-8", errors="replace")

    def list_reports(self, session_id: str) -> list[ReportInfo]:
        """List all reports for a session."""
        session_dir = Path(self._reports_dir) / session_id
        if not session_dir.is_dir():
            return []

        reports: list[ReportInfo] = []
        for p in sorted(session_dir.glob("*.md")):
            request_id = p.stem
            stat = p.stat()
            reports.append(
                ReportInfo(
                    session_id=session_id,
                    request_id=request_id,
                    path=str(p),
                    exists=True,
                    size=stat.st_size,
                )
            )
        return reports

    @staticmethod
    def has_knowledge_discoveries(content: str) -> bool:
        """Check whether report content contains a '## Knowledge Discoveries' section."""
        return "## Knowledge Discoveries" in content

    @staticmethod
    def extract_knowledge_discoveries(content: str) -> str | None:
        """Extract the '## Knowledge Discoveries' section text.

        Returns the section body (everything after the heading until the next
        ``##`` heading or end of file), or ``None`` if not found.
        """
        match = re.search(
            r"## Knowledge Discoveries\s*\n(.*?)(?=\n## |\Z)",
            content,
            re.DOTALL,
        )
        if match is None:
            return None
        text = match.group(1).strip()
        if not text or text.lower() == "none":
            return None
        return text
