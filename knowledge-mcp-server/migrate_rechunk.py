"""Re-chunk oversized report chunks using the updated chunk_report logic.

Finds all report chunks exceeding MAX_CHUNK_CHARS, re-chunks them into smaller
pieces, ingests the new chunks, and creates SUPERSEDES edges from new to old.
"""

import argparse
import logging
import os
import sys

from common import (
    MAX_CHUNK_CHARS,
    get_graph,
    init_schema,
    set_graph_name,
    chunk_report,
    chunk_id,
    ingest_chunks,
    create_topic_links,
    create_supersedes_edges,
    create_similarity_edges_for_chunks,
)

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)


def migrate_rechunk(dry_run: bool = False):
    """Find oversized report chunks and re-chunk them."""
    graph = get_graph()
    init_schema(graph)

    # Find all report chunks exceeding the size threshold
    res = graph.query(
        """
        MATCH (c:Chunk)
        WHERE c.type = 'report'
        RETURN c.id, c.content, c.source, c.section, c.roles, c.project
        """,
    )

    oversized = []
    for row in res.result_set:
        cid, content, source, section, roles, project = row
        if content and len(content) > MAX_CHUNK_CHARS:
            oversized.append({
                "id": cid,
                "content": content,
                "source": source or "",
                "section": section or "",
                "roles": roles or "dev",
                "project": project,
            })

    if not oversized:
        logger.info("No oversized report chunks found (threshold: %d chars). Nothing to do.", MAX_CHUNK_CHARS)
        return

    logger.info("Found %d oversized report chunks (threshold: %d chars)", len(oversized), MAX_CHUNK_CHARS)

    all_new_chunks: list[dict] = []
    supersessions: list[tuple[str, str, dict]] = []
    rechunk_log: list[dict] = []

    for old_chunk in oversized:
        source = old_chunk["source"]
        # Extract request_id from source (format: "report:<request_id>")
        if source.startswith("report:"):
            request_id = source[len("report:"):]
        else:
            request_id = source

        # Re-chunk the content using the updated chunk_report logic
        # We wrap the content with its section header so chunk_report can parse it
        section = old_chunk["section"]
        # Reconstruct a minimal markdown document for chunk_report
        # If section contains " / " it has H2/H3 structure
        if " / " in section:
            h2, h3 = section.split(" / ", 1)
            wrapped = f"## {h2}\n### {h3}\n{old_chunk['content']}"
        else:
            wrapped = f"## {section}\n{old_chunk['content']}"

        new_chunks = chunk_report(
            wrapped,
            request_id,
            old_chunk["roles"],
            project=old_chunk["project"],
        )

        # Filter out any chunk that's identical to the old one (same ID)
        new_chunks = [c for c in new_chunks if c["id"] != old_chunk["id"]]

        if not new_chunks:
            logger.info("  Chunk %s (%d chars): no smaller chunks produced, skipping",
                       old_chunk["id"], len(old_chunk["content"]))
            continue

        log_entry = {
            "old_id": old_chunk["id"],
            "old_chars": len(old_chunk["content"]),
            "new_ids": [c["id"] for c in new_chunks],
            "new_count": len(new_chunks),
        }
        rechunk_log.append(log_entry)

        logger.info("  Chunk %s (%d chars) -> %d new chunks: %s",
                    old_chunk["id"], len(old_chunk["content"]),
                    len(new_chunks), [c["id"] for c in new_chunks])

        all_new_chunks.extend(new_chunks)

        # Create SUPERSEDES edges: each new chunk supersedes the old one
        for nc in new_chunks:
            supersessions.append((nc["id"], old_chunk["id"], {
                "type": "SUPERSEDES",
                "reason": f"Re-chunked oversized report chunk ({len(old_chunk['content'])} chars)",
            }))

    if dry_run:
        logger.info("\n--- DRY RUN ---")
        logger.info("Would create %d new chunks from %d oversized chunks",
                    len(all_new_chunks), len(rechunk_log))
        for entry in rechunk_log:
            logger.info("  %s (%d chars) -> %d chunks: %s",
                        entry["old_id"], entry["old_chars"],
                        entry["new_count"], entry["new_ids"])
        return

    if not all_new_chunks:
        logger.info("No new chunks to ingest.")
        return

    # Ingest new chunks
    logger.info("\nIngesting %d new chunks...", len(all_new_chunks))
    ingest_chunks(graph, all_new_chunks)

    # Create topic links for new chunks
    logger.info("Creating topic links...")
    create_topic_links(graph, all_new_chunks)

    # Create SUPERSEDES edges
    logger.info("Creating %d SUPERSEDES edges...", len(supersessions))
    create_supersedes_edges(graph, supersessions)

    # Create similarity edges for new chunks
    new_ids = [c["id"] for c in all_new_chunks]
    logger.info("Creating similarity edges for new chunks...")
    create_similarity_edges_for_chunks(graph, new_ids)

    # Summary
    logger.info("\n--- Re-chunking Migration Stats ---")
    logger.info("  Oversized chunks found: %d", len(oversized))
    logger.info("  Chunks re-chunked:      %d", len(rechunk_log))
    logger.info("  New chunks created:      %d", len(all_new_chunks))
    logger.info("  SUPERSEDES edges:        %d", len(supersessions))
    for entry in rechunk_log:
        logger.info("  %s (%d chars) -> %s",
                    entry["old_id"], entry["old_chars"], entry["new_ids"])
    logger.info("Done.")


def main():
    parser = argparse.ArgumentParser(
        description="Re-chunk oversized report chunks in the knowledge graph"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without making changes",
    )
    parser.add_argument(
        "--project-root",
        help="Project root for graph name derivation (overrides PROJECT_ROOT env var)",
    )
    parser.add_argument(
        "--namespace",
        help="Namespace for shared graph",
    )
    args = parser.parse_args()

    project_root = args.project_root or os.environ.get("PROJECT_ROOT", "")
    if project_root or args.namespace:
        set_graph_name(project_root, namespace=args.namespace)

    migrate_rechunk(dry_run=args.dry_run)


if __name__ == "__main__":
    main()
