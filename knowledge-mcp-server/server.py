"""MCP server for hybrid vector+graph knowledge system."""

import os
import json

from mcp.server import Server
from mcp.server.stdio import stdio_server
import mcp.types as types

from common import (
    get_graph, init_schema, ingest_chunks, query_knowledge, chunk_id,
    chunk_report, create_topic_links, create_similarity_edges_for_chunks,
)

server = Server("knowledge")

# Lazy-initialized graph
_graph = None


def _ensure_graph():
    """Lazy init: get graph + ensure schema on first call."""
    global _graph
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
    graph = _ensure_graph()
    query = arguments["query"]
    role = arguments.get("role")

    result = query_knowledge(graph, query, role=role, top_k=8)

    parts = [result["response"]]
    if result.get("sources"):
        parts.append("\n**Sources:** " + ", ".join(result["sources"]))
    if result.get("chunks"):
        parts.append(f"\n({len(result['chunks'])} chunks retrieved, {result.get('expanded_count', 0)} via graph expansion)")

    return [types.TextContent(type="text", text="\n".join(parts))]


async def _handle_store(arguments: dict) -> list[types.TextContent]:
    graph = _ensure_graph()
    content = arguments["content"]
    roles = arguments["roles"]
    source = arguments.get("source", "mcp")
    roles_str = ",".join(roles)

    if source.startswith("report:"):
        request_id = source.split(":", 1)[1]
        chunks = chunk_report(content, request_id, roles_str)
    elif content.startswith("- "):
        chunks = [{"id": chunk_id(source, content[2:].strip()),
                   "content": content[2:].strip(), "section": "General",
                   "source": source, "roles": roles_str}]
    else:
        raw = [l.strip() for l in content.split("\n") if l.strip() and not l.strip().startswith("#")]
        chunks = [{"id": chunk_id(source, t), "content": t, "section": "General",
                   "source": source, "roles": roles_str} for t in raw]

    if not chunks:
        return [types.TextContent(type="text", text="No content to store")]

    ingest_chunks(graph, chunks)
    create_topic_links(graph, chunks)
    new_ids = [c["id"] for c in chunks]
    create_similarity_edges_for_chunks(graph, new_ids)

    return [types.TextContent(type="text", text=f"Stored {len(chunks)} chunk(s). Source: {source}")]


async def main():
    async with stdio_server() as (read, write):
        await server.run(read, write, server.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
