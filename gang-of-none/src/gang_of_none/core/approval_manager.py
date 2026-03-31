"""Approval request management — create, query, submit, dismiss."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

import structlog

from gang_of_none.models.approval import (
    ApprovalItem,
    ApprovalRequest,
    ApprovalSubmission,
)
from gang_of_none.models.enums import ApprovalType

logger = structlog.get_logger()


class ApprovalManager:
    """Manages the lifecycle of approval requests (presentOptions flow)."""

    def __init__(self) -> None:
        self._pending: dict[str, ApprovalRequest] = {}
        self._submissions: dict[str, ApprovalSubmission] = {}

    def create_request(
        self,
        request_id: str,
        title: str,
        type: ApprovalType,
        items: list[dict[str, Any] | ApprovalItem],
        description: str | None = None,
        session_id: str = "",
    ) -> ApprovalRequest:
        """Store a new approval request (or replace an existing one with the same ID)."""
        parsed_items = [
            item if isinstance(item, ApprovalItem) else ApprovalItem(**item)
            for item in items
        ]
        req = ApprovalRequest(
            request_id=request_id,
            title=title,
            type=type,
            items=parsed_items,
            description=description,
            session_id=session_id,
            created_at=datetime.now(timezone.utc),
        )
        self._pending[request_id] = req
        logger.debug("approval.created", request_id=request_id, title=title)
        return req

    def get_request(self, request_id: str) -> ApprovalRequest | None:
        """Return a pending approval request, or ``None``."""
        return self._pending.get(request_id)

    # Alias used by REST routes
    get_approval = get_request

    def list_pending(self, session_id: str | None = None) -> list[ApprovalRequest]:
        """Return all pending approval requests, optionally filtered by session."""
        if session_id is None:
            return list(self._pending.values())
        return [
            r for r in self._pending.values() if r.session_id == session_id
        ]

    def submit(
        self,
        request_id: str,
        selected_items: list[str],
        refine: str | None = None,
        notes: str | None = None,
    ) -> ApprovalSubmission:
        """Record a submission for *request_id* and remove it from pending."""
        submission = ApprovalSubmission(
            request_id=request_id,
            selected_items=selected_items,
            refine=refine,
            notes=notes,
            submitted_at=datetime.now(timezone.utc),
        )
        self._submissions[request_id] = submission
        self._pending.pop(request_id, None)
        logger.debug("approval.submitted", request_id=request_id)
        return submission

    def dismiss(self, request_id: str) -> bool:
        """Remove an approval request without submitting."""
        removed = self._pending.pop(request_id, None)
        if removed is not None:
            logger.debug("approval.dismissed", request_id=request_id)
            return True
        return False

    def update_request(
        self,
        request_id: str,
        items: list[dict[str, Any] | ApprovalItem] | None = None,
        description: str | None = None,
    ) -> ApprovalRequest | None:
        """Update an existing pending request (for slug reuse)."""
        req = self._pending.get(request_id)
        if req is None:
            return None
        if items is not None:
            req.items = [
                item if isinstance(item, ApprovalItem) else ApprovalItem(**item)
                for item in items
            ]
        if description is not None:
            req.description = description
        logger.debug("approval.updated", request_id=request_id)
        return req
