"""MCP server for hybrid vector+graph knowledge system."""

import asyncio
import logging
import os
import sys

from mcp.server import Server
from mcp.server.stdio import stdio_server
import mcp.types as types

from common import (
    GRAPH_NAME, NAMESPACE, PROJECT_ROOT,
    get_graph, init_schema, ingest_chunks, query_knowledge, chunk_id,
    chunk_report, create_topic_links, create_similarity_edges_for_chunks,
    create_cross_role_edges,
    detect_supersession, create_supersedes_edges,
    _resolve_project,
)
from entities import extract_and_store_entities

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

    parts = [result["response"]]
    if result.get("sources"):
        parts.append("\n**Sources:** " + ", ".join(result["sources"]))
    if result.get("chunks"):
        parts.append(f"\n({len(result['chunks'])} chunks retrieved, {result.get('expanded_count', 0)} via graph expansion)")

    return [types.TextContent(type="text", text="\n".join(parts))]


async def _handle_store(arguments: dict) -> list[types.TextContent]:
    content = arguments["content"]
    source = arguments.get("source", "mcp")
    roles = arguments["roles"]
    asyncio.create_task(_store_knowledge_bg(content, source, roles))
    return [types.TextContent(type="text", text="Knowledge storage initiated.")]


async def _store_knowledge_bg(content: str, source: str, roles: list[str]):
    """Background task: chunk, ingest, link, and extract entities."""
    try:
        async with _store_lock:
            graph = await _ensure_graph()
            roles_str = ",".join(roles)

            # Resolve project from PROJECT_ROOT — required when namespace is active
            project = _resolve_project() if NAMESPACE else None

            if source.startswith("report:"):
                request_id = source.split(":", 1)[1]
                chunks = chunk_report(content, request_id, roles_str, project=project)
            elif content.startswith("- "):
                chunks = [{"id": chunk_id(source, content[2:].strip()),
                           "content": content[2:].strip(), "section": "General",
                           "source": source, "roles": roles_str, "type": "knowledge",
                           "project": project}]
            else:
                raw = [l.strip() for l in content.split("\n") if l.strip() and not l.strip().startswith("#")]
                chunks = [{"id": chunk_id(source, t), "content": t, "section": "General",
                           "source": source, "roles": roles_str, "type": "knowledge",
                           "project": project} for t in raw]

            if not chunks:
                logger.info("store_knowledge_bg: no content to store")
                return

            ingest_chunks(graph, chunks, project=project)
            create_topic_links(graph, chunks)
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


async def main():
    async with stdio_server() as (read, write):
        await server.run(read, write, server.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
