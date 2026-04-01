"""Tests for ReportManager — create, read, list, knowledge extraction."""

import pytest

from src.core.report_manager import ReportManager


SESSION = "test-session"


@pytest.fixture
def rm(tmp_path) -> ReportManager:
    return ReportManager(reports_dir=str(tmp_path / "reports"))


class TestPreCreate:
    def test_creates_empty_file(self, rm: ReportManager):
        path = rm.pre_create(SESSION, "req-1")
        assert path.endswith("req-1.md")
        from pathlib import Path

        assert Path(path).exists()
        assert Path(path).read_text() == ""

    def test_idempotent(self, rm: ReportManager):
        rm.pre_create(SESSION, "req-2")
        rm.pre_create(SESSION, "req-2")  # no error


class TestReadReport:
    def test_read_existing(self, rm: ReportManager):
        path = rm.pre_create(SESSION, "r1")
        from pathlib import Path

        Path(path).write_text("hello", encoding="utf-8")
        content = rm.read_report(SESSION, "r1")
        assert content == "hello"

    def test_read_nonexistent(self, rm: ReportManager):
        assert rm.read_report(SESSION, "nope") is None


class TestListReports:
    def test_list_reports(self, rm: ReportManager):
        rm.pre_create(SESSION, "a")
        rm.pre_create(SESSION, "b")
        reports = rm.list_reports(SESSION)
        assert len(reports) == 2
        ids = {r.request_id for r in reports}
        assert ids == {"a", "b"}
        for r in reports:
            assert r.exists is True
            assert r.session_id == SESSION

    def test_list_empty_session(self, rm: ReportManager):
        assert rm.list_reports("no-such") == []


class TestKnowledgeExtraction:
    def test_has_knowledge(self):
        content = "## Summary\nstuff\n## Knowledge Discoveries\n- item\n"
        assert ReportManager.has_knowledge_discoveries(content) is True

    def test_no_knowledge(self):
        assert ReportManager.has_knowledge_discoveries("just text") is False

    def test_extract_knowledge(self):
        content = (
            "## Summary\nstuff\n"
            "## Knowledge Discoveries\n"
            "- insight one\n"
            "- insight two\n"
            "## Next Section\n"
        )
        result = ReportManager.extract_knowledge_discoveries(content)
        assert result is not None
        assert "insight one" in result
        assert "insight two" in result
        assert "Next Section" not in result

    def test_extract_knowledge_none_text(self):
        content = "## Knowledge Discoveries\nNone\n"
        assert ReportManager.extract_knowledge_discoveries(content) is None

    def test_extract_knowledge_missing(self):
        assert ReportManager.extract_knowledge_discoveries("no section") is None

    def test_extract_knowledge_at_end_of_file(self):
        content = "## Knowledge Discoveries\n- final insight\n"
        result = ReportManager.extract_knowledge_discoveries(content)
        assert result is not None
        assert "final insight" in result
