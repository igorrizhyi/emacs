#!/usr/bin/env python3
"""Manual test script for gang-of-none backend agent spawn and communication flow.

Tests two flows:
1. REST task flow: session creation → task submission → polling for completion.
2. WS agent flow: spawnAgent → promptAgent → dismissAgent via JSON-RPC over WebSocket.

Usage:
    python test_spawn.py [--host HOST] [--project-root PATH] [--timeout SECS]
    python test_spawn.py --skip-task-test   # run only the WS agent flow
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    import aiohttp

    HAS_AIOHTTP = True
except ImportError:
    HAS_AIOHTTP = False

DEFAULT_HOST = "http://localhost:8000"
DEFAULT_PROJECT_ROOT = "/var/home/igorrizhyi/.config/doom"
DEFAULT_TIMEOUT = 120


# ---------------------------------------------------------------------------
# In-process server helpers
# ---------------------------------------------------------------------------


def _start_server_in_background(
    project_root: str, host: str = "127.0.0.1", port: int = 8000
) -> "uvicorn.Server":
    """Start the FastAPI app in a background thread.

    CWD is set to *project_root* so that relative paths (e.g. the SQLite DB
    at ``.agent-shell/gang-of-none.db``) resolve correctly.

    Returns the ``uvicorn.Server`` instance for later shutdown.
    """
    import uvicorn

    # Ensure CWD is set before the app module is imported (it reads
    # relative paths at import / startup time).
    os.chdir(project_root)

    from src.main import app  # noqa: E402  (import after chdir)

    config = uvicorn.Config(app, host=host, port=port, log_level="info")
    server = uvicorn.Server(config)

    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()

    return server


def _wait_for_server(host: str, timeout: float = 10.0) -> bool:
    """Poll until the server responds (or *timeout* seconds elapse)."""
    import urllib.request
    import urllib.error

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            urllib.request.urlopen(f"{host}/docs", timeout=2)
            return True
        except (urllib.error.URLError, OSError):
            time.sleep(0.3)
    return False


def ts() -> str:
    """Current timestamp for log output."""
    return datetime.now(timezone.utc).strftime("%H:%M:%S.%f")[:-3]


def log(step: str, msg: str) -> None:
    print(f"[{ts()}] [{step}] {msg}")


# ---------------------------------------------------------------------------
# JSON-RPC helper for WS communication
# ---------------------------------------------------------------------------


async def ws_rpc(
    ws: aiohttp.ClientWebSocketResponse,
    rpc_id: int,
    method: str,
    params: dict,
    timeout: float,
) -> dict:
    """Send a JSON-RPC request over WS and wait for the matching response by id.

    Non-matching messages (notifications, other responses) are logged but skipped.
    """
    request = {"jsonrpc": "2.0", "id": rpc_id, "method": method, "params": params}
    log("WS-RPC", f"→ {method}(id={rpc_id}) {json.dumps(params)}")
    await ws.send_json(request)

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            msg = await asyncio.wait_for(ws.receive(), timeout=remaining)
        except asyncio.TimeoutError:
            break

        if msg.type == aiohttp.WSMsgType.TEXT:
            try:
                data = json.loads(msg.data)
            except json.JSONDecodeError:
                log("WS-RPC", f"Non-JSON: {msg.data[:200]}")
                continue

            # Check if this is our response (has matching id)
            if "id" in data and data["id"] == rpc_id:
                if "error" in data:
                    log("WS-RPC", f"← ERROR(id={rpc_id}): {json.dumps(data['error'])}")
                else:
                    log("WS-RPC", f"← OK(id={rpc_id}): {json.dumps(data.get('result', {}))}")
                return data

            # It's a notification or different response — log and continue
            notif_method = data.get("method", "?")
            log("WS-RPC", f"  (notification: {notif_method})")
        elif msg.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
            log("WS-RPC", f"Connection closed/error while waiting for id={rpc_id}")
            return {"jsonrpc": "2.0", "id": rpc_id, "error": {"code": -1, "message": "WS closed"}}

    log("WS-RPC", f"Timeout waiting for response id={rpc_id}")
    return {"jsonrpc": "2.0", "id": rpc_id, "error": {"code": -2, "message": "Timeout"}}


# ---------------------------------------------------------------------------
# WS agent spawn/prompt test flow
# ---------------------------------------------------------------------------


async def run_ws_agent_test(
    ws: aiohttp.ClientWebSocketResponse,
    timeout: float,
) -> None:
    """Exercise spawnAgent → promptAgent → dismissAgent over WS JSON-RPC."""
    print()
    print("=" * 60)
    log("WS-TEST", "=== WS Agent Spawn/Prompt Test ===")
    print("=" * 60)

    # 1. spawnAgent
    log("SPAWN", "Spawning researcher agent via WS JSON-RPC")
    resp = await ws_rpc(ws, 2, "spawnAgent", {"role": "researcher"}, timeout)
    if "error" in resp:
        log("SPAWN", f"FAILED: {resp['error']}")
        return

    result = resp.get("result", {})
    agent_id = result.get("agent_id") or result.get("id", "")
    if not agent_id:
        log("SPAWN", f"No agent_id in response: {json.dumps(result)}")
        return
    log("SPAWN", f"Agent spawned: agent_id={agent_id}")

    # 2. promptAgent
    prompt_msg = "What is 2+2? Reply with just the number."
    log("PROMPT", f"Sending prompt to agent {agent_id}: {prompt_msg!r}")

    prompt_timeout = min(timeout, 60)
    resp = await ws_rpc(
        ws, 3, "promptAgent",
        {"agent_id": agent_id, "message": prompt_msg},
        prompt_timeout,
    )
    if "error" in resp:
        err = resp["error"]
        # If timeout, try cancel
        if err.get("code") == -2:
            log("CANCEL", f"Prompt timed out after {prompt_timeout}s, attempting cancelAgent")
            cancel_resp = await ws_rpc(ws, 4, "cancelAgent", {"agent_id": agent_id}, 10)
            if "error" in cancel_resp:
                log("CANCEL", f"cancelAgent failed: {cancel_resp['error']}")
            else:
                log("CANCEL", f"cancelAgent OK: {json.dumps(cancel_resp.get('result', {}))}")
        else:
            log("PROMPT", f"FAILED: {err}")
    else:
        result = resp.get("result", {})
        answer = result.get("response") or result.get("content") or json.dumps(result)
        log("PROMPT", f"Agent answer: {answer}")

    # 3. dismissAgent
    log("DISMISS", f"Dismissing agent {agent_id}")
    resp = await ws_rpc(ws, 5, "dismissAgent", {"target": agent_id}, 15)
    if "error" in resp:
        log("DISMISS", f"FAILED: {resp['error']}")
    else:
        log("DISMISS", f"Agent dismissed: {json.dumps(resp.get('result', {}))}")

    log("WS-TEST", "=== WS Agent Test Complete ===")


# ---------------------------------------------------------------------------
# aiohttp-based async implementation
# ---------------------------------------------------------------------------


async def run_aiohttp(
    host: str,
    project_root: str,
    timeout: float,
    skip_task_test: bool = False,
) -> None:
    start = time.monotonic()
    ws_host = host.replace("http://", "ws://").replace("https://", "wss://")

    async with aiohttp.ClientSession() as http:
        # 1. Create session
        log("SESSION", f"Creating session (project_root={project_root})")
        async with http.post(
            f"{host}/api/sessions",
            json={"project_root": project_root},
        ) as resp:
            if resp.status != 201:
                body = await resp.text()
                log("SESSION", f"FAILED ({resp.status}): {body}")
                return
            session = await resp.json()

        session_id = session["id"]
        log("SESSION", f"Created: id={session_id}")

        # 2. Connect WebSocket
        ws_url = f"{ws_host}/ws/{session_id}"
        log("WS", f"Connecting to {ws_url}")
        ws = await http.ws_connect(ws_url)
        log("WS", "Connected")

        try:
            # --- REST task flow (skippable) ---
            if not skip_task_test:
                await _run_rest_task_flow(http, ws, host, session_id, timeout)
            else:
                log("SKIP", "Skipping REST task test (--skip-task-test)")

            # --- WS agent spawn/prompt flow ---
            await run_ws_agent_test(ws, timeout)

        finally:
            await ws.close()

    elapsed = time.monotonic() - start
    log("DONE", f"Total time: {elapsed:.1f}s")


async def _run_rest_task_flow(
    http: aiohttp.ClientSession,
    ws: aiohttp.ClientWebSocketResponse,
    host: str,
    session_id: str,
    timeout: float,
) -> None:
    """Original REST task submission + polling flow."""
    print("=" * 60)
    log("TASK-TEST", "=== REST Task Submission Test ===")
    print("=" * 60)

    task_finished = asyncio.Event()

    async def ws_listener() -> None:
        """Read WebSocket messages and print them."""
        try:
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.TEXT:
                    try:
                        data = json.loads(msg.data)
                    except json.JSONDecodeError:
                        log("WS", f"Non-JSON: {msg.data[:200]}")
                        continue

                    method = data.get("method", "")
                    params = data.get("params", {})
                    log("WS", f"Event: {method} → {json.dumps(params, indent=None)}")

                    # Detect task completion
                    if method == "task/statusChanged":
                        status = params.get("status", "")
                        if status in ("finished", "blocked"):
                            task_finished.set()
                elif msg.type in (
                    aiohttp.WSMsgType.CLOSED,
                    aiohttp.WSMsgType.ERROR,
                ):
                    log("WS", f"Connection closed/error: {msg.type}")
                    break
        except asyncio.CancelledError:
            pass

    listener_task = asyncio.create_task(ws_listener())

    try:
        # Submit researcher task
        task_msg = "List files in the current directory and report back"
        log("TASK", f"Submitting researcher task: {task_msg!r}")
        async with http.post(
            f"{host}/api/sessions/{session_id}/tasks",
            json={"role": "researcher", "message": task_msg},
        ) as resp:
            if resp.status != 201:
                body = await resp.text()
                log("TASK", f"FAILED ({resp.status}): {body}")
                return
            task_resp = await resp.json()

        tasks = task_resp.get("tasks", [])
        if not tasks:
            log("TASK", "No tasks returned")
            return
        request_id = tasks[0]["request_id"]
        log("TASK", f"Submitted: request_id={request_id}, status={tasks[0]['status']}")

        # Poll agent status + wait for task completion
        log("POLL", "Polling agents every 2s until task completes…")
        deadline = time.monotonic() + timeout
        prev_agents_summary = ""

        while not task_finished.is_set():
            if time.monotonic() > deadline:
                log("TIMEOUT", f"Task did not complete within {timeout}s")
                break

            # Poll agents
            async with http.get(
                f"{host}/api/sessions/{session_id}/agents",
            ) as resp:
                if resp.status == 200:
                    agents_data = await resp.json()
                    agents = agents_data.get("agents", [])
                    summary = "; ".join(
                        f"{a['role']}({a['id'][:8]}): {a['status']}"
                        + (f" task={a['current_task_id'][:8]}" if a.get("current_task_id") else "")
                        for a in agents
                    ) or "(none)"
                    if summary != prev_agents_summary:
                        log("POLL", f"Agents: {summary}")
                        prev_agents_summary = summary

            # Also poll task status directly
            async with http.get(
                f"{host}/api/tasks/{request_id}",
            ) as resp:
                if resp.status == 200:
                    task_data = await resp.json()
                    task_status = task_data.get("status", "unknown")
                    if task_status in ("finished", "blocked"):
                        task_finished.set()
                        log("POLL", f"Task status: {task_status}")
                        break

            try:
                await asyncio.wait_for(
                    task_finished.wait(),
                    timeout=2.0,
                )
            except asyncio.TimeoutError:
                pass

        # Fetch final task result
        log("RESULT", f"Fetching task {request_id}")
        async with http.get(
            f"{host}/api/tasks/{request_id}",
        ) as resp:
            if resp.status == 200:
                result = await resp.json()
                log("RESULT", f"Status: {result.get('status')}")
                log("RESULT", f"Full: {json.dumps(result, indent=2, default=str)}")
            else:
                body = await resp.text()
                log("RESULT", f"FAILED ({resp.status}): {body}")

    finally:
        listener_task.cancel()
        try:
            await listener_task
        except asyncio.CancelledError:
            pass


# ---------------------------------------------------------------------------
# Synchronous fallback (requests + websocket-client)
# ---------------------------------------------------------------------------


def run_sync(host: str, project_root: str, timeout: float) -> None:
    try:
        import requests
    except ImportError:
        print("ERROR: Neither aiohttp nor requests is available. Install one:")
        print("  pip install aiohttp   # preferred")
        print("  pip install requests")
        sys.exit(1)

    start = time.monotonic()

    # 1. Create session
    log("SESSION", f"Creating session (project_root={project_root})")
    resp = requests.post(
        f"{host}/api/sessions",
        json={"project_root": project_root},
        timeout=10,
    )
    if resp.status_code != 201:
        log("SESSION", f"FAILED ({resp.status_code}): {resp.text}")
        return
    session = resp.json()
    session_id = session["id"]
    log("SESSION", f"Created: id={session_id}")

    # 2. Submit researcher task
    task_msg = "List files in the current directory and report back"
    log("TASK", f"Submitting researcher task: {task_msg!r}")
    resp = requests.post(
        f"{host}/api/sessions/{session_id}/tasks",
        json={"role": "researcher", "message": task_msg},
        timeout=10,
    )
    if resp.status_code != 201:
        log("TASK", f"FAILED ({resp.status_code}): {resp.text}")
        return
    task_resp = resp.json()
    tasks = task_resp.get("tasks", [])
    if not tasks:
        log("TASK", "No tasks returned")
        return
    request_id = tasks[0]["request_id"]
    log("TASK", f"Submitted: request_id={request_id}, status={tasks[0]['status']}")

    # 3. Poll until completion (no WS in sync mode)
    log("POLL", "Polling agents + task every 2s (no WebSocket in sync mode)…")
    deadline = time.monotonic() + timeout
    prev_agents_summary = ""

    while time.monotonic() < deadline:
        # Poll agents
        resp = requests.get(
            f"{host}/api/sessions/{session_id}/agents",
            timeout=5,
        )
        if resp.status_code == 200:
            agents = resp.json().get("agents", [])
            summary = "; ".join(
                f"{a['role']}({a['id'][:8]}): {a['status']}"
                + (f" task={a['current_task_id'][:8]}" if a.get("current_task_id") else "")
                for a in agents
            ) or "(none)"
            if summary != prev_agents_summary:
                log("POLL", f"Agents: {summary}")
                prev_agents_summary = summary

        # Poll task
        resp = requests.get(f"{host}/api/tasks/{request_id}", timeout=5)
        if resp.status_code == 200:
            task_data = resp.json()
            status = task_data.get("status", "unknown")
            if status in ("finished", "blocked"):
                log("POLL", f"Task reached terminal state: {status}")
                break

        time.sleep(2)
    else:
        log("TIMEOUT", f"Task did not complete within {timeout}s")

    # 4. Fetch final result
    log("RESULT", f"Fetching task {request_id}")
    resp = requests.get(f"{host}/api/tasks/{request_id}", timeout=5)
    if resp.status_code == 200:
        result = resp.json()
        log("RESULT", f"Status: {result.get('status')}")
        log("RESULT", f"Full: {json.dumps(result, indent=2, default=str)}")
    else:
        log("RESULT", f"FAILED ({resp.status_code}): {resp.text}")

    elapsed = time.monotonic() - start
    log("DONE", f"Total time: {elapsed:.1f}s")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Test gang-of-none agent spawn and communication flow",
    )
    parser.add_argument(
        "--host",
        default=None,
        help=(
            "Backend base URL.  When omitted the server is started in-process; "
            f"when provided the script connects to the external server (e.g. {DEFAULT_HOST})"
        ),
    )
    parser.add_argument(
        "--project-root",
        default=DEFAULT_PROJECT_ROOT,
        help=f"Project root for session (default: {DEFAULT_PROJECT_ROOT})",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT,
        help=f"Timeout in seconds (default: {DEFAULT_TIMEOUT})",
    )
    parser.add_argument(
        "--skip-task-test",
        action="store_true",
        help="Skip the REST task submission test, run only the WS agent spawn/prompt test",
    )
    args = parser.parse_args()

    # Determine whether to start an in-process server.
    use_inprocess = args.host is None
    host = args.host if args.host is not None else DEFAULT_HOST

    print("=== gang-of-none spawn test ===")
    print(f"Host: {host}")
    print(f"Project root: {args.project_root}")
    print(f"Timeout: {args.timeout}s")
    print(f"Server: {'in-process' if use_inprocess else 'external'}")
    print(f"Transport: {'aiohttp (async+WS)' if HAS_AIOHTTP else 'requests (sync, no WS)'}")
    if args.skip_task_test:
        print("Mode: WS agent test only (--skip-task-test)")
    print()

    if args.skip_task_test and not HAS_AIOHTTP:
        print("ERROR: --skip-task-test requires aiohttp (WS agent test needs WebSocket)")
        print("  pip install aiohttp")
        sys.exit(1)

    # --- In-process server startup ---
    server = None
    if use_inprocess:
        log("SERVER", "Starting in-process uvicorn server …")
        server = _start_server_in_background(args.project_root)
        if not _wait_for_server(host):
            log("SERVER", "FAILED: server did not become ready within 10s")
            sys.exit(1)
        log("SERVER", "Server is ready")

    try:
        if HAS_AIOHTTP:
            asyncio.run(run_aiohttp(host, args.project_root, args.timeout, args.skip_task_test))
        else:
            run_sync(host, args.project_root, args.timeout)
    finally:
        if server is not None:
            log("SERVER", "Shutting down in-process server …")
            server.should_exit = True
            # Give the server thread a moment to exit cleanly.
            time.sleep(0.5)
            log("SERVER", "Done")


if __name__ == "__main__":
    main()
