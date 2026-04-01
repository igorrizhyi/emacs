"""ACP Session Manager — JSON-RPC 2.0 over NDJSON stdio transport.

Manages ACP (Agent Communication Protocol) sessions by spawning CLI agent
processes and communicating via newline-delimited JSON on stdin/stdout.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable
from typing import Any

from ..config import Settings

logger = logging.getLogger(__name__)

PROTOCOL_VERSION = "0.1.0"
CLIENT_NAME = "gang-of-none"
CLIENT_VERSION = "0.1.0"


# ---------------------------------------------------------------------------
# ACP message builders
# ---------------------------------------------------------------------------

def make_initialize_request(request_id: int) -> dict[str, Any]:
    """Build ACP initialize request."""
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "initialize",
        "params": {
            "clientInfo": {"name": CLIENT_NAME, "version": CLIENT_VERSION},
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
        },
    }


def make_session_new_request(
    request_id: int,
    work_dir: str,
    model: str | None = None,
    system_prompt: str | None = None,
) -> dict[str, Any]:
    """Build session/new request."""
    params: dict[str, Any] = {
        "cwd": work_dir,
        "mcpServers": [],
    }
    meta: dict[str, Any] = {}
    if model:
        meta["model"] = model
    if system_prompt:
        meta["systemPrompt"] = system_prompt
    if meta:
        params["_meta"] = meta
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "session/new",
        "params": params,
    }


def make_session_prompt_request(
    request_id: int, session_id: str, message: str
) -> dict[str, Any]:
    """Build session/prompt request."""
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "session/prompt",
        "params": {
            "sessionId": session_id,
            "prompt": list(message),  # ACP expects prompt as array of chars
        },
    }


def make_session_cancel_notification(session_id: str) -> dict[str, Any]:
    """Build session/cancel notification (no id — fire-and-forget)."""
    return {
        "jsonrpc": "2.0",
        "method": "session/cancel",
        "params": {"sessionId": session_id},
    }


def make_session_fork_request(
    request_id: int,
    session_id: str,
    work_dir: str,
) -> dict[str, Any]:
    """Build session/fork request."""
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "session/fork",
        "params": {
            "sessionId": session_id,
            "cwd": work_dir,
            "mcpServers": [],
        },
    }


# ---------------------------------------------------------------------------
# ACPSession — single agent process
# ---------------------------------------------------------------------------

class ACPSession:
    """Manages a single ACP session (one CLI agent process)."""

    def __init__(
        self,
        agent_id: str,
        binary: str,
        work_dir: str,
        model: str | None = None,
        system_prompt: str | None = None,
        on_notification: Callable[[dict[str, Any]], None] | None = None,
    ) -> None:
        self.agent_id = agent_id
        self.binary = binary
        self.work_dir = work_dir
        self.model = model
        self.system_prompt = system_prompt
        self.on_notification = on_notification

        self.process: asyncio.subprocess.Process | None = None
        self.session_id: str | None = None
        self._pending_requests: dict[int, asyncio.Future[dict[str, Any]]] = {}
        self._request_counter: int = 0
        self._reader_task: asyncio.Task[None] | None = None

    # -- lifecycle ----------------------------------------------------------

    async def start(self) -> None:
        """Spawn the CLI process and initialize ACP session."""
        self.process = await asyncio.create_subprocess_exec(
            self.binary,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=self.work_dir,
        )
        self._reader_task = asyncio.create_task(
            self._read_stdout(), name=f"acp-reader-{self.agent_id}"
        )

        # Initialize protocol
        init_resp = await self._send_request("initialize", make_initialize_request)
        logger.info("ACP initialized for %s: %s", self.agent_id, init_resp)

        # Create session
        session_resp = await self._send_request(
            "session/new",
            lambda rid: make_session_new_request(
                rid, self.work_dir, self.model, self.system_prompt
            ),
        )
        self.session_id = session_resp.get("sessionId")
        if not self.session_id:
            raise RuntimeError(
                f"session/new did not return sessionId: {session_resp}"
            )
        logger.info(
            "ACP session %s created for agent %s", self.session_id, self.agent_id
        )

    async def stop(self) -> None:
        """Terminate the CLI process and clean up."""
        if self._reader_task and not self._reader_task.done():
            self._reader_task.cancel()
            try:
                await self._reader_task
            except asyncio.CancelledError:
                pass
            self._reader_task = None

        if self.process:
            try:
                self.process.terminate()
                await asyncio.wait_for(self.process.wait(), timeout=5.0)
            except (asyncio.TimeoutError, ProcessLookupError):
                self.process.kill()
            self.process = None

        # Fail any pending requests
        for fut in self._pending_requests.values():
            if not fut.done():
                fut.cancel()
        self._pending_requests.clear()

    async def prompt(self, message: str) -> dict[str, Any]:
        """Send a session/prompt request and return the response."""
        if not self.session_id:
            raise RuntimeError("Session not started")
        return await self._send_request(
            "session/prompt",
            lambda rid: make_session_prompt_request(rid, self.session_id, message),  # type: ignore[arg-type]
        )

    async def cancel(self) -> None:
        """Send session/cancel notification (fire-and-forget)."""
        if not self.session_id:
            return
        self._send_notification(make_session_cancel_notification(self.session_id))

    async def fork(self) -> str:
        """Fork the session and return the new session ID."""
        if not self.session_id:
            raise RuntimeError("Session not started")
        resp = await self._send_request(
            "session/fork",
            lambda rid: make_session_fork_request(rid, self.session_id, self.work_dir),  # type: ignore[arg-type]
        )
        new_id = resp.get("sessionId")
        if not new_id:
            raise RuntimeError(f"session/fork did not return sessionId: {resp}")
        return new_id

    # -- JSON-RPC transport -------------------------------------------------

    async def _send_request(
        self,
        method: str,
        builder: Callable[[int], dict[str, Any]],
    ) -> dict[str, Any]:
        """Send a JSON-RPC request and await the response.

        *builder* receives the assigned request-id and must return the full
        JSON-RPC object (already containing that id).
        """
        assert self.process and self.process.stdin  # noqa: S101
        self._request_counter += 1
        rid = self._request_counter
        loop = asyncio.get_running_loop()
        fut: asyncio.Future[dict[str, Any]] = loop.create_future()
        self._pending_requests[rid] = fut

        msg = builder(rid)
        line = json.dumps(msg, separators=(",", ":")) + "\n"
        self.process.stdin.write(line.encode())
        await self.process.stdin.drain()
        logger.debug("→ %s id=%d", method, rid)

        return await fut

    def _send_notification(self, notification: dict[str, Any]) -> None:
        """Send a JSON-RPC notification (no response expected)."""
        if not (self.process and self.process.stdin):
            return
        line = json.dumps(notification, separators=(",", ":")) + "\n"
        self.process.stdin.write(line.encode())
        # drain is async; schedule it but don't await from a sync context
        asyncio.ensure_future(self.process.stdin.drain())

    async def _read_stdout(self) -> None:
        """Continuously read NDJSON lines from stdout and route them."""
        assert self.process and self.process.stdout  # noqa: S101
        buffer = ""
        try:
            while True:
                raw = await self.process.stdout.read(65536)
                if not raw:
                    break
                buffer += raw.decode(errors="replace")
                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        logger.warning("Invalid JSON from agent %s: %s", self.agent_id, line[:200])
                        continue
                    await self._route_message(obj)
        except asyncio.CancelledError:
            return
        except Exception:
            logger.exception("Reader crashed for agent %s", self.agent_id)

    async def _route_message(self, obj: dict[str, Any]) -> None:
        """Route a parsed JSON-RPC message."""
        has_id = "id" in obj
        has_method = "method" in obj

        if has_id and not has_method:
            # Response to one of our requests
            rid = obj["id"]
            fut = self._pending_requests.pop(rid, None)
            if fut and not fut.done():
                if "error" in obj:
                    fut.set_exception(
                        RuntimeError(f"ACP error: {obj['error']}")
                    )
                else:
                    fut.set_result(obj.get("result", {}))
            return

        if has_method and has_id:
            # Request FROM the agent (permission, fs operations)
            await self._handle_agent_request(obj)
            return

        if has_method and not has_id:
            # Notification from the agent
            if self.on_notification:
                try:
                    self.on_notification(obj)
                except Exception:
                    logger.exception("Notification handler error for %s", self.agent_id)
            return

        logger.warning("Unroutable message from %s: %s", self.agent_id, obj)

    async def _handle_agent_request(self, request: dict[str, Any]) -> None:
        """Handle requests FROM the agent (permission, fs operations).

        For now: auto-approve permission requests, stub fs operations.
        """
        method = request.get("method", "")
        rid = request["id"]
        logger.debug("← agent request: %s id=%d", method, rid)

        if method == "session/request_permission":
            # Auto-approve: pick the first option
            options = (
                request.get("params", {})
                .get("options", [])
            )
            option_id = options[0]["id"] if options else "allow"
            response = {
                "jsonrpc": "2.0",
                "id": rid,
                "result": {
                    "outcome": {
                        "outcome": "selected",
                        "optionId": option_id,
                    }
                },
            }
        elif method == "fs/read_text_file":
            path = request.get("params", {}).get("path", "")
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    content = f.read()
                response = {
                    "jsonrpc": "2.0",
                    "id": rid,
                    "result": {"content": content},
                }
            except OSError as exc:
                response = {
                    "jsonrpc": "2.0",
                    "id": rid,
                    "error": {"code": -32603, "message": str(exc)},
                }
        elif method == "fs/write_text_file":
            path = request.get("params", {}).get("path", "")
            content = request.get("params", {}).get("content", "")
            try:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(content)
                response = {
                    "jsonrpc": "2.0",
                    "id": rid,
                    "result": None,
                }
            except OSError as exc:
                response = {
                    "jsonrpc": "2.0",
                    "id": rid,
                    "error": {"code": -32603, "message": str(exc)},
                }
        else:
            response = {
                "jsonrpc": "2.0",
                "id": rid,
                "error": {
                    "code": -32601,
                    "message": f"Method not found: {method}",
                },
            }

        self._send_notification(response)  # reuse the write helper


# ---------------------------------------------------------------------------
# ACPSessionManager — manages multiple sessions
# ---------------------------------------------------------------------------

class ACPSessionManager:
    """Manages multiple ACP sessions keyed by agent_id."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._sessions: dict[str, ACPSession] = {}

    async def create_session(
        self,
        agent_id: str,
        work_dir: str,
        model: str | None = None,
        system_prompt: str | None = None,
        on_notification: Callable[[dict[str, Any]], None] | None = None,
    ) -> ACPSession:
        """Create and start a new ACP session."""
        if agent_id in self._sessions:
            raise ValueError(f"Session already exists for agent {agent_id}")
        session = ACPSession(
            agent_id=agent_id,
            binary=self.settings.acp_binary,
            work_dir=work_dir,
            model=model or self.settings.default_model or None,
            system_prompt=system_prompt,
            on_notification=on_notification,
        )
        await session.start()
        self._sessions[agent_id] = session
        return session

    async def destroy_session(self, agent_id: str) -> None:
        """Stop and remove an ACP session."""
        session = self._sessions.pop(agent_id, None)
        if session:
            await session.stop()

    def get_session(self, agent_id: str) -> ACPSession | None:
        """Look up a session by agent_id."""
        return self._sessions.get(agent_id)

    async def shutdown(self) -> None:
        """Stop all sessions."""
        ids = list(self._sessions.keys())
        for agent_id in ids:
            await self.destroy_session(agent_id)
