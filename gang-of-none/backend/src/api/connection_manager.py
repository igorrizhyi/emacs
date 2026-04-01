"""WebSocket connection manager — tracks connections per session."""

from __future__ import annotations

import json
from typing import Any

import structlog
from fastapi import WebSocket

logger = structlog.get_logger()


class ConnectionManager:
    """Tracks active WebSocket connections grouped by session_id."""

    def __init__(self) -> None:
        self._connections: dict[str, list[WebSocket]] = {}

    async def connect(self, session_id: str, websocket: WebSocket) -> None:
        """Accept and register a WebSocket connection for a session."""
        await websocket.accept()
        self._connections.setdefault(session_id, []).append(websocket)
        logger.info("ws.connect", session_id=session_id)

    def disconnect(self, session_id: str, websocket: WebSocket) -> None:
        """Remove a WebSocket connection from its session."""
        conns = self._connections.get(session_id)
        if conns is None:
            return
        try:
            conns.remove(websocket)
        except ValueError:
            pass
        if not conns:
            del self._connections[session_id]
        logger.info("ws.disconnect", session_id=session_id)

    async def broadcast(self, session_id: str, message: dict[str, Any]) -> None:
        """Send a JSON message to all connections in a session."""
        conns = self._connections.get(session_id, [])
        payload = json.dumps(message)
        stale: list[WebSocket] = []
        for ws in conns:
            try:
                await ws.send_text(payload)
            except Exception:
                stale.append(ws)
        for ws in stale:
            self.disconnect(session_id, ws)

    async def send_to(
        self, session_id: str, websocket: WebSocket, message: dict[str, Any]
    ) -> None:
        """Send a JSON message to a specific WebSocket connection."""
        _ = session_id  # kept for API symmetry / future use
        await websocket.send_text(json.dumps(message))

    def get_connections(self, session_id: str) -> list[WebSocket]:
        """Return all WebSocket connections for a session."""
        return list(self._connections.get(session_id, []))

    def get_all_session_ids(self) -> list[str]:
        """Return all session IDs with active connections."""
        return list(self._connections.keys())
