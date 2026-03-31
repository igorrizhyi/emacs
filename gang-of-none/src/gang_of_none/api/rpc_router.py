"""JSON-RPC 2.0 router — method dispatch and response building."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any

import structlog

logger = structlog.get_logger()

# JSON-RPC 2.0 error codes
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603

# Handler signature: async (params) -> result dict
Handler = Callable[[dict[str, Any]], Awaitable[dict[str, Any]]]


def make_response(request_id: int | str | None, result: dict[str, Any]) -> dict[str, Any]:
    """Build a JSON-RPC 2.0 success response."""
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def make_error(
    request_id: int | str | None, code: int, message: str, data: Any = None
) -> dict[str, Any]:
    """Build a JSON-RPC 2.0 error response."""
    error: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return {"jsonrpc": "2.0", "id": request_id, "error": error}


class RPCRouter:
    """Maps JSON-RPC method names to async handler functions."""

    def __init__(self) -> None:
        self._handlers: dict[str, Handler] = {}

    def register(self, method: str, handler: Handler) -> None:
        """Register a handler for a JSON-RPC method."""
        self._handlers[method] = handler

    async def dispatch(self, raw: dict[str, Any]) -> dict[str, Any] | None:
        """Parse a JSON-RPC request, dispatch to handler, return response.

        Returns ``None`` for notifications (requests without an ``id``).
        """
        request_id = raw.get("id")
        method = raw.get("method")

        if not method or not isinstance(method, str):
            if request_id is not None:
                return make_error(request_id, INVALID_REQUEST, "Missing or invalid method")
            return None

        is_notification = request_id is None

        handler = self._handlers.get(method)
        if handler is None:
            logger.warning("rpc.method_not_found", method=method)
            if is_notification:
                return None
            return make_error(request_id, METHOD_NOT_FOUND, f"Method not found: {method}")

        params = raw.get("params", {})
        if not isinstance(params, dict):
            if is_notification:
                return None
            return make_error(request_id, INVALID_PARAMS, "params must be an object")

        try:
            result = await handler(params)
        except Exception as exc:
            logger.exception("rpc.handler_error", method=method)
            if is_notification:
                return None
            return make_error(request_id, INTERNAL_ERROR, str(exc))

        if is_notification:
            return None
        return make_response(request_id, result)
