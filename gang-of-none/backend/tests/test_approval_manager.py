"""Tests for ApprovalManager — create, submit, dismiss, list."""

import pytest

from src.core.approval_manager import ApprovalManager
from src.models.approval import ApprovalItem
from src.models.enums import ApprovalType


@pytest.fixture
def am() -> ApprovalManager:
    return ApprovalManager()


SESSION = "test-session"


class TestCreateRequest:
    def test_create_checklist(self, am: ApprovalManager):
        req = am.create_request(
            request_id="ap-1",
            title="Pick items",
            type=ApprovalType.CHECKLIST,
            items=[
                {"id": "a", "label": "Item A"},
                {"id": "b", "label": "Item B", "default_selected": True},
            ],
            session_id=SESSION,
        )
        assert req.request_id == "ap-1"
        assert req.type == ApprovalType.CHECKLIST
        assert len(req.items) == 2
        assert req.items[1].default_selected is True

    def test_create_choice(self, am: ApprovalManager):
        req = am.create_request(
            request_id="ap-2",
            title="Choose one",
            type=ApprovalType.CHOICE,
            items=[ApprovalItem(id="x", label="Option X")],
            description="Pick wisely",
            session_id=SESSION,
        )
        assert req.type == ApprovalType.CHOICE
        assert req.description == "Pick wisely"

    def test_create_replaces_existing(self, am: ApprovalManager):
        am.create_request(
            request_id="dup",
            title="V1",
            type=ApprovalType.CHECKLIST,
            items=[{"id": "a", "label": "A"}],
            session_id=SESSION,
        )
        am.create_request(
            request_id="dup",
            title="V2",
            type=ApprovalType.CHECKLIST,
            items=[{"id": "b", "label": "B"}],
            session_id=SESSION,
        )
        req = am.get_request("dup")
        assert req is not None
        assert req.title == "V2"


class TestSubmit:
    def test_submit_removes_from_pending(self, am: ApprovalManager):
        am.create_request(
            request_id="sub-1",
            title="T",
            type=ApprovalType.CHECKLIST,
            items=[{"id": "a", "label": "A"}],
            session_id=SESSION,
        )
        submission = am.submit("sub-1", selected_items=["a"], notes="lgtm")
        assert submission.request_id == "sub-1"
        assert submission.selected_items == ["a"]
        assert submission.notes == "lgtm"
        assert am.get_request("sub-1") is None

    def test_submit_with_refine(self, am: ApprovalManager):
        am.create_request(
            request_id="sub-2",
            title="T",
            type=ApprovalType.CHOICE,
            items=[{"id": "x", "label": "X"}],
            session_id=SESSION,
        )
        submission = am.submit("sub-2", selected_items=["x"], refine="change name")
        assert submission.refine == "change name"


class TestDismiss:
    def test_dismiss_existing(self, am: ApprovalManager):
        am.create_request(
            request_id="d-1",
            title="T",
            type=ApprovalType.CHECKLIST,
            items=[{"id": "a", "label": "A"}],
            session_id=SESSION,
        )
        assert am.dismiss("d-1") is True
        assert am.get_request("d-1") is None

    def test_dismiss_nonexistent(self, am: ApprovalManager):
        assert am.dismiss("ghost") is False


class TestListPending:
    def test_list_all(self, am: ApprovalManager):
        am.create_request(
            request_id="l1",
            title="T1",
            type=ApprovalType.CHECKLIST,
            items=[{"id": "a", "label": "A"}],
            session_id=SESSION,
        )
        am.create_request(
            request_id="l2",
            title="T2",
            type=ApprovalType.CHOICE,
            items=[{"id": "b", "label": "B"}],
            session_id="other",
        )
        assert len(am.list_pending()) == 2

    def test_list_filtered_by_session(self, am: ApprovalManager):
        am.create_request(
            request_id="f1",
            title="T",
            type=ApprovalType.CHECKLIST,
            items=[{"id": "a", "label": "A"}],
            session_id=SESSION,
        )
        am.create_request(
            request_id="f2",
            title="T",
            type=ApprovalType.CHECKLIST,
            items=[{"id": "b", "label": "B"}],
            session_id="other",
        )
        filtered = am.list_pending(session_id=SESSION)
        assert len(filtered) == 1
        assert filtered[0].request_id == "f1"


class TestUpdateRequest:
    def test_update_items(self, am: ApprovalManager):
        am.create_request(
            request_id="up-1",
            title="T",
            type=ApprovalType.CHECKLIST,
            items=[{"id": "a", "label": "Old"}],
            session_id=SESSION,
        )
        updated = am.update_request("up-1", items=[{"id": "b", "label": "New"}])
        assert updated is not None
        assert len(updated.items) == 1
        assert updated.items[0].label == "New"

    def test_update_nonexistent(self, am: ApprovalManager):
        assert am.update_request("ghost") is None
