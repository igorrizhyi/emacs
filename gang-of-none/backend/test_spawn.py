#!/usr/bin/env python3
"""Manual test script for gang-of-none backend agent spawn and communication flow.

Tests the full lifecycle: session creation → task submission → agent spawn →
WebSocket event streaming → task completion → result retrieval.

Usage:
    python test_spawn.py [--host HOST] [--project-root PATH] [--timeout SECS]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from datetime import datetime, timezone

try:
    import aiohttp

    HAS_AIOHTTP = True
except ImportError:
    HAS_AIOHTTP = False

DEFAULT_HOST = "http://localhost:8000"
DEFAULT_PROJECT_ROOT = "/var/home/igorrizhyi/.config/doom"
DEFAULT_TIMEOUT = 120


def ts() -> str:
    """Current timestamp for log output."""
    return datetime.now(timezone.utc).strftime("%H:%M:%S.%f")[:-3]


def log(step: str, msg: str) -> None:
    print(f"[{ts()}] [{step}] {msg}")


# ---------------------------------------------------------------------------
# aiohttp-based async implementation
# ---------------------------------------------------------------------------


async def run_aiohttp(host: str, project_root: str, timeout: float) -> None:
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

        # 2. Connect WebSocket (background listener)
        ws_url = f"{ws_host}/ws/{session_id}"
        log("WS", f"Connecting to {ws_url}")
        ws = await http.ws_connect(ws_url)
        log("WS", "Connected")

        task_finished = asyncio.Event()
        request_id: str | None = None

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
            # 3. Submit researcher task
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

            # 4. Poll agent status + wait for task completion
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
                if request_id:
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

            # 5. Fetch final task result
            if request_id:
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
            await ws.close()

    elapsed = time.monotonic() - start
    log("DONE", f"Total time: {elapsed:.1f}s")


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
        default=DEFAULT_HOST,
        help=f"Backend base URL (default: {DEFAULT_HOST})",
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
    args = parser.parse_args()

    print(f"=== gang-of-none spawn test ===")
    print(f"Host: {args.host}")
    print(f"Project root: {args.project_root}")
    print(f"Timeout: {args.timeout}s")
    print(f"Transport: {'aiohttp (async+WS)' if HAS_AIOHTTP else 'requests (sync, no WS)'}")
    print()

    if HAS_AIOHTTP:
        asyncio.run(run_aiohttp(args.host, args.project_root, args.timeout))
    else:
        run_sync(args.host, args.project_root, args.timeout)


if __name__ == "__main__":
    main()
