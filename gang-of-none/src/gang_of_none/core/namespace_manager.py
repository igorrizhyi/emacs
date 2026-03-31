"""Namespace manager — peer discovery, config, and file-based IPC event bus."""

from __future__ import annotations

import asyncio
import json
import os
import socket
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Coroutine

import structlog

from gang_of_none.models.namespace import NamespaceConfig, Peer

logger = structlog.get_logger()

# Type alias for message callbacks
MessageCallback = Callable[[dict[str, Any]], Coroutine[Any, Any, None]]


class NamespaceManager:
    """Manages namespace config, peer registry, and file-based IPC bus."""

    def __init__(self) -> None:
        self._config: NamespaceConfig | None = None
        self._peers: dict[str, Peer] = {}  # session_id → Peer
        self._message_callbacks: list[MessageCallback] = []

        # Bus state
        self._bus_dir: Path | None = None
        self._own_pid: int | None = None
        self._poll_task: asyncio.Task[None] | None = None
        self._seen_events: dict[str, int] = {}  # filename → last-read byte offset
        self._seen_inbox: set[str] = set()  # processed inbox file names

    # ── Config ─────────────────────────────────────────────────────────

    def load_config(self, config_path: str) -> NamespaceConfig:
        """Read namespace config from a JSON file."""
        path = Path(config_path)
        if not path.is_file():
            raise FileNotFoundError(f"Namespace config not found: {config_path}")
        data = json.loads(path.read_text(encoding="utf-8"))
        self._config = NamespaceConfig(**data)
        return self._config

    def get_config(self) -> NamespaceConfig | None:
        return self._config

    # ── Peer Registry ──────────────────────────────────────────────────

    def register_peer(self, session_id: str, peer: Peer) -> None:
        self._peers[session_id] = peer

    def unregister_peer(self, session_id: str) -> None:
        self._peers.pop(session_id, None)

    def list_peers(self) -> list[Peer]:
        return list(self._peers.values())

    def get_peer(self, session_id: str) -> Peer | None:
        return self._peers.get(session_id)

    def find_peer_by_pid(self, pid: int) -> tuple[str, Peer] | None:
        for sid, peer in self._peers.items():
            if peer.pid == pid:
                return (sid, peer)
        return None

    # ── Event Bus (file-based IPC) ─────────────────────────────────────

    async def start_bus(self, namespace: str, pid: int) -> None:
        """Set up bus directories and start the polling watcher."""
        cache_home = os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))
        self._bus_dir = Path(cache_home) / "agent-shell" / f"ns-{namespace}"
        self._own_pid = pid

        # Create directory structure
        (self._bus_dir / "peers").mkdir(parents=True, exist_ok=True)
        (self._bus_dir / "events").mkdir(parents=True, exist_ok=True)
        (self._bus_dir / "inbox" / str(pid)).mkdir(parents=True, exist_ok=True)

        # Write our own presence file
        self._write_presence()

        # Read existing peers and clean stale ones
        self._scan_peers()

        # Start polling watcher
        self._poll_task = asyncio.create_task(
            self._poll_loop(), name="ns-bus-poll"
        )
        logger.info("namespace.bus_started", namespace=namespace, pid=pid)

    async def stop_bus(self) -> None:
        """Clean up presence file and stop watcher."""
        if self._poll_task is not None:
            self._poll_task.cancel()
            try:
                await self._poll_task
            except asyncio.CancelledError:
                pass
            self._poll_task = None

        # Remove our presence file
        if self._bus_dir and self._own_pid:
            presence = self._bus_dir / "peers" / f"{self._own_pid}.json"
            presence.unlink(missing_ok=True)
            # Clean up our inbox directory
            inbox = self._bus_dir / "inbox" / str(self._own_pid)
            if inbox.is_dir():
                for f in inbox.iterdir():
                    f.unlink(missing_ok=True)
                inbox.rmdir()

        logger.info("namespace.bus_stopped")

    def _write_presence(self) -> None:
        """Write our presence file to the peers directory."""
        if not self._bus_dir or not self._own_pid:
            return
        presence_path = self._bus_dir / "peers" / f"{self._own_pid}.json"
        # Find our own session_id — pick the first registered peer with our PID,
        # or use a placeholder
        session_id = ""
        for sid, peer in self._peers.items():
            if peer.pid == self._own_pid:
                session_id = sid
                break

        data = {
            "pid": self._own_pid,
            "hostname": socket.gethostname(),
            "project_root": "",
            "session_id": session_id,
            "joined_at": datetime.now(timezone.utc).isoformat(),
        }
        presence_path.write_text(json.dumps(data), encoding="utf-8")

    def _scan_peers(self) -> None:
        """Read existing peer presence files, removing stale ones."""
        if not self._bus_dir:
            return
        peers_dir = self._bus_dir / "peers"
        for pfile in peers_dir.glob("*.json"):
            try:
                data = json.loads(pfile.read_text(encoding="utf-8"))
                pid = data.get("pid")
                if pid is None:
                    continue
                # Check if the process is still alive (skip our own)
                if pid != self._own_pid and not _pid_alive(pid):
                    logger.info("namespace.stale_peer_removed", pid=pid)
                    pfile.unlink(missing_ok=True)
                    continue
                # Don't re-register ourselves from the file
                if pid == self._own_pid:
                    continue
                # Register as a discovered peer (use pid as a synthetic session_id)
                peer = Peer(
                    pid=pid,
                    hostname=data.get("hostname", ""),
                    project_root=data.get("project_root", ""),
                    namespace=self._config.namespace if self._config else "",
                    connected_at=datetime.fromisoformat(
                        data.get("joined_at", datetime.now(timezone.utc).isoformat())
                    ),
                )
                synthetic_sid = f"file-peer-{pid}"
                self._peers[synthetic_sid] = peer
            except (json.JSONDecodeError, OSError) as exc:
                logger.warning("namespace.peer_file_error", path=str(pfile), error=str(exc))

    async def _poll_loop(self) -> None:
        """Poll for new events, inbox messages, and peer changes."""
        try:
            while True:
                await asyncio.sleep(1.0)
                self._scan_peers()
                await self._poll_events()
                await self._poll_inbox()
        except asyncio.CancelledError:
            return

    async def _poll_events(self) -> None:
        """Read new JSONL entries from broadcast event files."""
        if not self._bus_dir:
            return
        events_dir = self._bus_dir / "events"
        for efile in events_dir.glob("*.jsonl"):
            # Skip our own event file
            if efile.stem == str(self._own_pid):
                continue
            try:
                offset = self._seen_events.get(efile.name, 0)
                size = efile.stat().st_size
                if size <= offset:
                    continue
                with efile.open("r", encoding="utf-8") as fh:
                    fh.seek(offset)
                    for line in fh:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            event = json.loads(line)
                            await self._dispatch_message(event)
                        except json.JSONDecodeError:
                            pass
                    self._seen_events[efile.name] = fh.tell()
            except OSError:
                pass

    async def _poll_inbox(self) -> None:
        """Read new messages from our inbox directory."""
        if not self._bus_dir or not self._own_pid:
            return
        inbox_dir = self._bus_dir / "inbox" / str(self._own_pid)
        if not inbox_dir.is_dir():
            return
        for mfile in inbox_dir.glob("*.json"):
            if mfile.name in self._seen_inbox:
                continue
            try:
                data = json.loads(mfile.read_text(encoding="utf-8"))
                self._seen_inbox.add(mfile.name)
                mfile.unlink(missing_ok=True)
                await self._dispatch_message(data)
            except (json.JSONDecodeError, OSError):
                pass

    async def _dispatch_message(self, message: dict[str, Any]) -> None:
        """Invoke all registered message callbacks."""
        for cb in self._message_callbacks:
            try:
                await cb(message)
            except Exception:
                logger.exception("namespace.callback_error")

    # ── Broadcasting ───────────────────────────────────────────────────

    def _broadcast(self, event: dict[str, Any]) -> None:
        """Append an event to our JSONL broadcast file."""
        if not self._bus_dir or not self._own_pid:
            return
        event_file = self._bus_dir / "events" / f"{self._own_pid}.jsonl"
        with event_file.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(event) + "\n")

    def broadcast_agent_spawn(self, agent_info: dict[str, Any]) -> None:
        self._broadcast({
            "type": "agent_spawn",
            "pid": self._own_pid,
            "agent": agent_info,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        })

    def broadcast_agent_status(self, agent_id: str, status: str) -> None:
        self._broadcast({
            "type": "agent_status",
            "pid": self._own_pid,
            "agent_id": agent_id,
            "status": status,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        })

    def broadcast_agent_dismiss(self, agent_id: str) -> None:
        self._broadcast({
            "type": "agent_dismiss",
            "pid": self._own_pid,
            "agent_id": agent_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        })

    # ── Message Routing ────────────────────────────────────────────────

    async def send_message(self, target_pid: int, message: str) -> None:
        """Async wrapper for send_to_peer (used by REST routes)."""
        self.send_to_peer(target_pid, message)

    def send_to_peer(self, target_pid: int, message: str) -> None:
        """Write a JSON message to a peer's inbox directory."""
        if not self._bus_dir:
            return
        inbox_dir = self._bus_dir / "inbox" / str(target_pid)
        inbox_dir.mkdir(parents=True, exist_ok=True)
        msg_file = inbox_dir / f"{uuid.uuid4().hex[:12]}.json"
        msg_file.write_text(
            json.dumps({
                "from_pid": self._own_pid,
                "message": message,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }),
            encoding="utf-8",
        )

    def on_peer_message(self, callback: MessageCallback) -> None:
        """Register a handler for incoming messages."""
        self._message_callbacks.append(callback)


def _pid_alive(pid: int) -> bool:
    """Check if a process with the given PID is still running."""
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False
    except OSError:
        return False
