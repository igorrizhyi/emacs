#!/usr/bin/env python3
"""Backfill entity extraction on chunks that have no HAS_ENTITY edges.

Usage:
    python backfill_entities.py --dry-run           # count unlinked chunks
    python backfill_entities.py --graph my_graph     # backfill one graph
    python backfill_entities.py                      # backfill all graphs
    python backfill_entities.py --batch-size 10      # custom batch size
"""

import argparse
import asyncio
import logging
import os
import sys
import time

from falkordb import FalkorDB

from entities import extract_and_store_entities

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

FALKORDB_HOST = os.environ.get("FALKORDB_HOST", "127.0.0.1")
FALKORDB_PORT = int(os.environ.get("FALKORDB_PORT", "6380"))

UNLINKED_CHUNKS_QUERY = (
    "MATCH (c:Chunk) WHERE NOT (c)-[:HAS_ENTITY]->() RETURN c.id, c.content"
)


def get_db() -> FalkorDB:
    return FalkorDB(host=FALKORDB_HOST, port=FALKORDB_PORT)


def discover_graphs(db: FalkorDB, target_graph: str | None) -> list[str]:
    """Return list of graph names to process."""
    if target_graph:
        return [target_graph]
    all_graphs = db.list_graphs()
    # Filter to knowledge_ prefixed graphs (our convention)
    return [g for g in all_graphs if g.startswith("knowledge_")]


def get_unlinked_chunks(db: FalkorDB, graph_name: str) -> list[dict]:
    """Query for chunks without HAS_ENTITY edges."""
    graph = db.select_graph(graph_name)
    result = graph.query(UNLINKED_CHUNKS_QUERY)
    chunks = []
    for row in result.result_set:
        chunk_id, content = row[0], row[1]
        if chunk_id and content:
            chunks.append({"id": chunk_id, "content": content})
    return chunks


async def backfill_graph(
    db: FalkorDB, graph_name: str, batch_size: int, dry_run: bool
) -> dict:
    """Backfill entities for one graph. Returns stats dict."""
    stats = {
        "graph": graph_name,
        "total_unlinked": 0,
        "processed": 0,
        "entities": 0,
        "relationships": 0,
        "errors": 0,
    }

    chunks = get_unlinked_chunks(db, graph_name)
    stats["total_unlinked"] = len(chunks)

    if dry_run:
        logger.info("[%s] DRY RUN: %d chunks without entities", graph_name, len(chunks))
        return stats

    if not chunks:
        logger.info("[%s] All chunks already have entities", graph_name)
        return stats

    logger.info("[%s] Processing %d unlinked chunks in batches of %d",
                graph_name, len(chunks), batch_size)

    graph = db.select_graph(graph_name)

    for i in range(0, len(chunks), batch_size):
        batch = chunks[i : i + batch_size]
        batch_num = i // batch_size + 1
        total_batches = (len(chunks) + batch_size - 1) // batch_size

        logger.info("[%s] Batch %d/%d (%d chunks)",
                    graph_name, batch_num, total_batches, len(batch))

        try:
            ent_count, rel_count = await extract_and_store_entities(graph, batch)
            stats["processed"] += len(batch)
            stats["entities"] += ent_count
            stats["relationships"] += rel_count
            logger.info("[%s] Batch %d: %d entities, %d relationships",
                        graph_name, batch_num, ent_count, rel_count)
        except Exception:
            stats["errors"] += 1
            logger.exception("[%s] Batch %d failed", graph_name, batch_num)

    return stats


async def main():
    parser = argparse.ArgumentParser(
        description="Backfill entity extraction on chunks without HAS_ENTITY edges."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Count unlinked chunks without extracting entities.",
    )
    parser.add_argument(
        "--graph",
        type=str,
        default=None,
        help="Target a specific graph name (default: all knowledge_* graphs).",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=20,
        help="Number of chunks to process per batch (default: 20).",
    )
    args = parser.parse_args()

    db = get_db()
    graphs = discover_graphs(db, args.graph)

    if not graphs:
        logger.warning("No graphs found to process.")
        sys.exit(0)

    logger.info("Graphs to process: %s", graphs)

    all_stats = []
    start = time.time()

    for graph_name in graphs:
        stats = await backfill_graph(db, graph_name, args.batch_size, args.dry_run)
        all_stats.append(stats)

    elapsed = time.time() - start

    # Summary
    print("\n=== Backfill Summary ===")
    total_unlinked = sum(s["total_unlinked"] for s in all_stats)
    total_processed = sum(s["processed"] for s in all_stats)
    total_entities = sum(s["entities"] for s in all_stats)
    total_rels = sum(s["relationships"] for s in all_stats)
    total_errors = sum(s["errors"] for s in all_stats)

    for s in all_stats:
        print(f"  {s['graph']}: {s['total_unlinked']} unlinked, "
              f"{s['processed']} processed, {s['entities']} entities, "
              f"{s['relationships']} relationships, {s['errors']} errors")

    print(f"\nTotal: {total_unlinked} unlinked chunks across {len(graphs)} graph(s)")
    if not args.dry_run:
        print(f"Processed: {total_processed} chunks -> "
              f"{total_entities} entities, {total_rels} relationships")
        if total_errors:
            print(f"Errors: {total_errors} batch(es) failed")
    print(f"Time: {elapsed:.1f}s")


if __name__ == "__main__":
    asyncio.run(main())
