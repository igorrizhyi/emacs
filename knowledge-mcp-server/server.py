"""MCP server for FalkorDB GraphRAG knowledge system."""

import os
import json
from datetime import datetime, timezone

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import TextContent

from graphrag_sdk import Ontology, Source
from graphrag_sdk.source import Source_FromRawText

from common import (
    GRAPH_NAME,
    FALKORDB_HOST,
    FALKORDB_PORT,
    get_model,
    get_model_config,
    load_ontology,
    save_ontology,
    create_kg,
    write_temp_txt,
)

server = Server("knowledge-mcp-server")

# Lazy-initialized globals
_kg = None


def _check_team_session():
    """Gate: only available in team sessions."""
    if not os.environ.get("AGENT_SHELL_TEAM"):
        raise ValueError("Knowledge system only available in team sessions")


def _bootstrap_ontology(model):
    """Generate a seed ontology when none exists (first-time use)."""
    seed = (
        "Knowledge entries about software engineering: bug fixes, code patterns, "
        "architecture decisions, environment setup, testing conventions. "
        "Each entry has roles (dev, tester, researcher, lead), topics, "
        "and source attribution."
    )
    sources = [Source_FromRawText(seed)]
    return Ontology.from_sources(
        sources,
        model,
        boundaries="Team knowledge management system for software engineering",
    )


def _get_kg(bootstrap_if_missing=False):
    """Get or create the KnowledgeGraph instance.

    Args:
        bootstrap_if_missing: If True and no ontology exists, generate a seed
            ontology. If False and no ontology exists, return None.
    """
    global _kg
    if _kg is not None:
        return _kg

    model = get_model()
    ontology = load_ontology()

    if ontology is None:
        # Try without ontology — works if FalkorDB already has a schema graph
        try:
            _kg = create_kg()
            return _kg
        except Exception:
            # "The ontology is empty" — need to bootstrap
            if not bootstrap_if_missing:
                return None
            ontology = _bootstrap_ontology(model)
            save_ontology(ontology)

    _kg = create_kg(ontology=ontology)
    return _kg


@server.tool()
async def query_knowledge(query: str, role: str | None = None) -> list[TextContent]:
    """Query the team knowledge graph for relevant information.

    Args:
        query: The question or search query.
        role: Optional role filter ('dev', 'tester', 'researcher', 'lead').
    """
    try:
        _check_team_session()
        kg = _get_kg()
        if kg is None:
            return [TextContent(
                type="text",
                text="Knowledge base not initialized yet. Store some knowledge first.",
            )]

        # Build the query, incorporating role filter if provided
        full_query = query
        if role:
            full_query = f"[Filter: entries relevant to role '{role}'] {query}"

        chat = kg.chat_session()
        result = chat.send_message(full_query)

        response = result.get("response", "No results found.")
        context = result.get("context", [])

        parts = [f"**Answer:** {response}"]
        if context:
            parts.append(f"\n**Context:** {json.dumps(context, indent=2)}")

        return [TextContent(type="text", text="\n".join(parts))]

    except ValueError as e:
        return [TextContent(type="text", text=str(e))]
    except Exception as e:
        return [TextContent(type="text", text=f"Error querying knowledge graph: {e}")]


@server.tool()
async def store_knowledge(
    content: str, roles: list[str], source: str | None = None
) -> list[TextContent]:
    """Store knowledge in the team knowledge graph.

    Args:
        content: The knowledge text to store.
        roles: Which roles this applies to (e.g. ['dev', 'tester']).
        source: Optional attribution (e.g. 'report:request-id', 'user').
    """
    try:
        _check_team_session()
        kg = _get_kg(bootstrap_if_missing=True)

        # Deduplication: query for similar content
        try:
            chat = kg.chat_session()
            existing = chat.send_message(
                f"Find entries very similar to: {content[:200]}"
            )
            existing_response = existing.get("response", "")
            if existing_response and "no " not in existing_response.lower():
                # Found potential duplicate — note in the stored content
                content = (
                    f"[UPDATE - supersedes similar existing entry]\n{content}"
                )
        except Exception:
            pass  # Dedup is best-effort; proceed with storage

        # Build metadata-enriched text
        timestamp = datetime.now(timezone.utc).isoformat()
        roles_str = ", ".join(roles)
        source_str = source or "unknown"

        enriched = (
            f"Knowledge Entry\n"
            f"Roles: {roles_str}\n"
            f"Source: {source_str}\n"
            f"Timestamp: {timestamp}\n"
            f"---\n"
            f"{content}"
        )

        # Write to temp file and ingest
        tmp_path = write_temp_txt(enriched)
        try:
            src = Source(tmp_path)
            kg.process_sources(
                [src],
                instructions=(
                    "Extract knowledge entries with their metadata "
                    "(roles, source, timestamp). Preserve role tags as "
                    "attributes on entities."
                ),
                hide_progress=True,
            )
        finally:
            os.unlink(tmp_path)

        # Save ontology after ingestion (it may have been updated)
        if kg.ontology is not None:
            save_ontology(kg.ontology)

        return [TextContent(
            type="text",
            text=f"Knowledge stored successfully.\nRoles: {roles_str}\nSource: {source_str}",
        )]

    except ValueError as e:
        return [TextContent(type="text", text=str(e))]
    except Exception as e:
        return [TextContent(type="text", text=f"Error storing knowledge: {e}")]


async def main():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
