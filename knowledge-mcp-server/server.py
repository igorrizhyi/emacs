"""MCP server for hybrid vector+graph knowledge system."""

import asyncio
import json
import logging
import os
import sys

from mcp.server import Server
from mcp.server.stdio import stdio_server
import mcp.types as types

from common import (
    GRAPH_NAME, KNOWLEDGE_LLM_BACKEND, NAMESPACE, PROJECT_ROOT,
    EMACS_SERVER_NAME, KNOWLEDGE_PROJECT_ROOT,
    get_graph, init_schema, ingest_chunks, query_knowledge, chunk_id,
    chunk_report, create_similarity_edges_for_chunks,
    create_cross_role_edges,
    detect_supersession, create_supersedes_edges,
    _resolve_project, _CLASSIFY_PROMPT,
    CLASSIFICATION_MODEL,
)
from entities import (
    extract_and_store_entities,
    merge_and_upsert_entities, merge_and_upsert_relationships,
    parse_extraction_output,
)
from llm_queue import (
    queue_llm_task, get_llm_task as _get_llm_task,
    submit_llm_result as _submit_llm_result, cleanup_task,
)

logger = logging.getLogger(__name__)

_project = _resolve_project()
_ns_info = f", namespace={NAMESPACE}" if NAMESPACE else ""
print(f"Knowledge graph: {GRAPH_NAME} (project: {_project}{_ns_info})", file=sys.stderr)

server = Server("knowledge")

# Lazy-initialized graph
_graph = None
_graph_lock = asyncio.Lock()
_store_lock = asyncio.Lock()


async def _ensure_graph():
    """Lazy init: get graph + ensure schema on first call."""
    global _graph
    async with _graph_lock:
        if _graph is None:
            _graph = get_graph()
            init_schema(_graph)
    return _graph


TOOLS = [
    types.Tool(
        name="query_knowledge",
        description="Query the team knowledge graph using semantic search. Returns relevant knowledge chunks with sources.",
        inputSchema={
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Natural language question"},
                "role": {"type": "string", "description": "Filter by role: dev, tester, researcher, lead"},
                "mode": {"type": "string", "enum": ["summary", "technical"], "description": "Response mode: 'summary' for narrative answers, 'technical' for structured technical briefs suitable as dev context"},
                "project": {"type": "string", "description": "Filter by project (omit to search all projects in the namespace)"},
            },
            "required": ["query"],
        },
    ),
    types.Tool(
        name="store_knowledge",
        description="Store new knowledge in the graph. Content is chunked, embedded, and linked.",
        inputSchema={
            "type": "object",
            "properties": {
                "content": {"type": "string", "description": "Knowledge text (bullet points or paragraphs)"},
                "roles": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Target roles: dev, tester, researcher, lead",
                },
                "source": {"type": "string", "description": "Source identifier (e.g. 'dev.md', 'session-notes')"},
                "namespace": {"type": "string", "description": "Namespace tag for the stored knowledge (auto-detected from .agent-shell/namespace.json if omitted)"},
            },
            "required": ["content", "roles"],
        },
    ),
    types.Tool(
        name="get_llm_task",
        description="Get a pending LLM task by ID. Returns the task prompt and metadata for processing by an agent.",
        inputSchema={
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Task UUID (8-char hex)"},
            },
            "required": ["id"],
        },
    ),
    types.Tool(
        name="submit_llm_result",
        description="Submit the result of a processed LLM task. Triggers post-processing (entity extraction, supersession edges) based on task type.",
        inputSchema={
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Task UUID (8-char hex)"},
                "result": {"type": "string", "description": "The LLM response text"},
            },
            "required": ["id", "result"],
        },
    ),
]


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    if not os.environ.get("AGENT_SHELL_TEAM"):
        return []
    return TOOLS


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    if not os.environ.get("AGENT_SHELL_TEAM"):
        return [types.TextContent(type="text", text="Knowledge system only available in team sessions")]

    try:
        if name == "query_knowledge":
            return await _handle_query(arguments)
        elif name == "store_knowledge":
            return await _handle_store(arguments)
        elif name == "get_llm_task":
            return await _handle_get_llm_task(arguments)
        elif name == "submit_llm_result":
            return await _handle_submit_llm_result(arguments)
        else:
            return [types.TextContent(type="text", text=f"Unknown tool: {name}")]
    except Exception as e:
        return [types.TextContent(type="text", text=f"Error: {e}")]


async def _handle_query(arguments: dict) -> list[types.TextContent]:
    graph = await _ensure_graph()
    query = arguments["query"]
    role = arguments.get("role")
    mode = arguments.get("mode", "summary")
    project = arguments.get("project")

    result = query_knowledge(graph, query, role=role, top_k=8, mode=mode, project=project)

    # Skip-synthesis mode: return raw context chunks without LLM answer
    if result.get("context_text") and result.get("response") is None:
        parts = []
        if result.get("sources"):
            parts.append("**Sources:** " + ", ".join(result["sources"]))
        parts.append(f"({len(result['chunks'])} chunks retrieved, {result.get('expanded_count', 0)} via graph expansion)")
        parts.append(f"\n**Context:**\n{result['context_text']}")
        return [types.TextContent(type="text", text="\n".join(parts))]

    # Agent backend: return sources + pending tasks (no synthesis yet)
    if result.get("pending_llm_tasks"):
        parts = []
        if result.get("sources"):
            parts.append("**Sources:** " + ", ".join(result["sources"]))
        parts.append(f"({len(result['chunks'])} chunks retrieved, {result.get('expanded_count', 0)} via graph expansion)")
        parts.append(f"\n**Pending LLM tasks:** {json.dumps(result['pending_llm_tasks'])}")
        return [types.TextContent(type="text", text="\n".join(parts))]

    parts = [result["response"]]
    if result.get("sources"):
        parts.append("\n**Sources:** " + ", ".join(result["sources"]))
    if result.get("chunks"):
        parts.append(f"\n({len(result['chunks'])} chunks retrieved, {result.get('expanded_count', 0)} via graph expansion)")

    return [types.TextContent(type="text", text="\n".join(parts))]


async def _dispatch_knowledge_agent(task_uuids: list[str]):
    """Fire-and-forget: spawn a knowledge agent via emacsclient to process LLM tasks.

    If EMACS_SERVER_NAME is not set, this is a no-op (caller should fall back).
    """
    if not EMACS_SERVER_NAME or not task_uuids:
        return

    uuid_str = ", ".join(task_uuids)
    timestamp = int(asyncio.get_event_loop().time())
    request_id = f"kb-auto-{timestamp}"
    project_root = KNOWLEDGE_PROJECT_ROOT or PROJECT_ROOT

    message = (
        f"Process knowledge LLM tasks: {uuid_str}\\n"
        "For each task UUID, call `get_llm_task(id=UUID)` to get the prompt, "
        "process it, then call `submit_llm_result(id=UUID, result=RESPONSE)`."
    )

    elisp = (
        f'(let ((default-directory "{project_root}/"))'
        " (agent-shell-team--handle-tasks-put"
        " (list (cons (quote tasks)"
        f' (vector (list (cons (quote role) "knowledge")'
        f' (cons (quote message) "{message}")'
        f' (cons (quote request_id) "{request_id}")))))))'
    )

    try:
        proc = await asyncio.create_subprocess_exec(
            "emacsclient", "-s", EMACS_SERVER_NAME, "--eval", elisp,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=10)
        if proc.returncode != 0:
            logger.error("emacsclient dispatch failed (rc=%d): %s",
                         proc.returncode, stderr.decode().strip())
        else:
            logger.info("Dispatched knowledge agent for %d tasks (request_id=%s)",
                        len(task_uuids), request_id)
    except asyncio.TimeoutError:
        logger.error("emacsclient dispatch timed out for tasks: %s", uuid_str)
    except Exception:
        logger.exception("Failed to dispatch knowledge agent via emacsclient")


async def _handle_store(arguments: dict) -> list[types.TextContent]:
    content = arguments["content"]
    source = arguments.get("source", "mcp")
    roles = arguments["roles"]

    if KNOWLEDGE_LLM_BACKEND == "agent":
        task_ids = await _store_and_queue_llm(content, source, roles)
        if EMACS_SERVER_NAME and task_ids:
            # Self-dispatch: fire-and-forget emacsclient call
            asyncio.create_task(_dispatch_knowledge_agent(task_ids))
            return [types.TextContent(type="text", text="Knowledge storage initiated.")]
        elif task_ids:
            # Fallback: return pending tasks for lead to dispatch
            return [types.TextContent(type="text", text=json.dumps({"pending_llm_tasks": task_ids}))]
        else:
            return [types.TextContent(type="text", text="Knowledge storage initiated.")]
    else:
        asyncio.create_task(_store_knowledge_bg(content, source, roles))
        return [types.TextContent(type="text", text="Knowledge storage initiated.")]


def _build_chunks(content: str, source: str, roles_str: str, project: str = None) -> list[dict]:
    """Parse content into chunk dicts (shared by both backends)."""
    if source.startswith("report:"):
        request_id = source.split(":", 1)[1]
        return chunk_report(content, request_id, roles_str, project=project)
    elif content.startswith("- "):
        return [{"id": chunk_id(source, content[2:].strip()),
                 "content": content[2:].strip(), "section": "General",
                 "source": source, "roles": roles_str, "type": "knowledge",
                 "project": project}]
    else:
        raw = [l.strip() for l in content.split("\n") if l.strip() and not l.strip().startswith("#")]
        return [{"id": chunk_id(source, t), "content": t, "section": "General",
                 "source": source, "roles": roles_str, "type": "knowledge",
                 "project": project} for t in raw]


async def _store_and_queue_llm(content: str, source: str, roles: list[str]) -> list[str]:
    """Synchronous graph work + queue LLM tasks for agent backend.

    Does chunking, embedding, graph writes, and supersession detection
    synchronously, then queues entity extraction tasks for agents.
    Returns list of entity extraction task UUIDs.
    """
    async with _store_lock:
        graph = await _ensure_graph()
        roles_str = ",".join(roles)
        project = _resolve_project() if NAMESPACE else None

        chunks = _build_chunks(content, source, roles_str, project=project)
        if not chunks:
            return []

        # Synchronous graph work (fast: embedding + graph writes)
        ingest_chunks(graph, chunks, project=project)
        new_ids = [c["id"] for c in chunks]
        create_similarity_edges_for_chunks(graph, new_ids)
        create_cross_role_edges(graph, new_ids)

        task_ids = []

        # Supersession detection — run inline via litellm (same as openai backend)
        supersessions = detect_supersession(graph, chunks)
        if supersessions:
            create_supersedes_edges(graph, supersessions)

        # Entity extraction: queue one task per chunk
        # The prompt field contains only the chunk text; extraction
        # instructions live in the knowledge agent's system prompt.
        for chunk in chunks:
            tid = queue_llm_task(
                PROJECT_ROOT,
                "entity_extraction",
                chunk["content"],
                context={"chunk_ids": [chunk["id"]]},
            )
            task_ids.append(tid)

        proj_info = f" project={project}" if project else ""
        logger.info("Stored %d chunk(s), queued %d LLM tasks. Source: %s%s",
                    len(chunks), len(task_ids), source, proj_info)
        return task_ids


async def _store_knowledge_bg(content: str, source: str, roles: list[str]):
    """Background task: chunk, ingest, link, and extract entities."""
    try:
        async with _store_lock:
            graph = await _ensure_graph()
            roles_str = ",".join(roles)

            # Resolve project from PROJECT_ROOT — required when namespace is active
            project = _resolve_project() if NAMESPACE else None

            chunks = _build_chunks(content, source, roles_str, project=project)

            if not chunks:
                logger.info("store_knowledge_bg: no content to store")
                return

            ingest_chunks(graph, chunks, project=project)
            new_ids = [c["id"] for c in chunks]
            create_similarity_edges_for_chunks(graph, new_ids)
            create_cross_role_edges(graph, new_ids)

            # Supersession detection — find and mark chunks that replace older ones
            supersessions = detect_supersession(graph, chunks)
            if supersessions:
                create_supersedes_edges(graph, supersessions)

            # Entity extraction
            entity_count, rel_count = await extract_and_store_entities(graph, chunks)

            supersede_info = f", {len(supersessions)} supersession(s)" if supersessions else ""
            entity_info = f", {entity_count} entities, {rel_count} relationships" if entity_count else ""
            proj_info = f" project={project}" if project else ""
            logger.info("Stored %d chunk(s). Source: %s%s%s%s",
                        len(chunks), source, proj_info, supersede_info, entity_info)
    except Exception:
        logger.exception("Background store_knowledge failed")


async def _handle_get_llm_task(arguments: dict) -> list[types.TextContent]:
    """Return a pending LLM task by ID."""
    task_id = arguments["id"]
    task = _get_llm_task(PROJECT_ROOT, task_id)
    if task is None:
        return [types.TextContent(type="text", text=f"Task {task_id} not found")]
    if task.get("status") == "completed":
        task.pop("prompt", None)
    return [types.TextContent(type="text", text=json.dumps(task, indent=2))]


async def _handle_submit_llm_result(arguments: dict) -> list[types.TextContent]:
    """Submit a result for an LLM task and run post-processing."""
    task_id = arguments["id"]
    result_text = arguments["result"]

    # Write result to task file
    if not _submit_llm_result(PROJECT_ROOT, task_id, result_text):
        return [types.TextContent(type="text", text=f"Task {task_id} not found")]

    # Read back the full task for post-processing
    task = _get_llm_task(PROJECT_ROOT, task_id)
    if task is None:
        return [types.TextContent(type="text", text=f"Task {task_id} completed but could not read back")]

    task_type = task.get("type")
    context = task.get("context", {})

    try:
        if task_type == "synthesis":
            # No cleanup — lead reads the result via get_llm_task after the knowledge agent finishes
            return [types.TextContent(type="text", text=f"Synthesis task {task_id} completed. Result available via get_llm_task.")]

        elif task_type == "entity_extraction":
            graph = await _ensure_graph()
            entities, relationships = parse_extraction_output(result_text)
            chunk_ids = context.get("chunk_ids", [])

            # Build chunk_map: entity name -> set of chunk IDs
            chunk_map = {}
            for ent in entities:
                chunk_map[ent["name"]] = set(chunk_ids)

            entity_count = await merge_and_upsert_entities(graph, entities, chunk_map)
            rel_count = await merge_and_upsert_relationships(graph, relationships)
            cleanup_task(PROJECT_ROOT, task_id)
            return [types.TextContent(
                type="text",
                text=f"Entity extraction task {task_id} completed: {entity_count} entities, {rel_count} relationships.",
            )]

        else:
            cleanup_task(PROJECT_ROOT, task_id)
            return [types.TextContent(type="text", text=f"Unknown task type '{task_type}', result stored.")]

    except Exception as e:
        return [types.TextContent(type="text", text=f"Post-processing error for task {task_id}: {e}")]


async def main():
    async with stdio_server() as (read, write):
        await server.run(read, write, server.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
