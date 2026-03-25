#!/usr/bin/env python3
"""Link existing chunks to existing entities via embedding similarity.

No LLM calls — uses cosine similarity between chunk and entity embeddings
to create HAS_ENTITY edges.

Usage:
    python backfill_entities.py --dry-run                              # count unlinked chunks
    python backfill_entities.py --project-root /path/to/project        # target project graph
    python backfill_entities.py --namespace my_ns --threshold 0.6      # namespace graph, stricter
    python backfill_entities.py --max-entities 3                       # fewer links per chunk
"""

import argparse
import logging
import os
import sys
import time

import numpy as np
from falkordb import FalkorDB

from common import set_graph_name, FALKORDB_HOST, FALKORDB_PORT

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

ENTITIES_QUERY = "MATCH (e:Entity) WHERE e.embedding IS NOT NULL RETURN e.name, e.embedding"
UNLINKED_CHUNKS_QUERY = (
    "MATCH (c:Chunk) WHERE NOT (c)-[:HAS_ENTITY]->() "
    "AND c.embedding IS NOT NULL RETURN c.id, c.embedding"
)
MERGE_EDGE_QUERY = (
    "MATCH (c:Chunk {id: $cid}), (e:Entity {name: $name}) "
    "MERGE (c)-[:HAS_ENTITY]->(e)"
)


def get_db() -> FalkorDB:
    return FalkorDB(host=FALKORDB_HOST, port=FALKORDB_PORT)


def load_entities(graph) -> tuple[list[str], np.ndarray | None]:
    """Load entity names and embeddings. Returns (names, embedding_matrix)."""
    result = graph.query(ENTITIES_QUERY)
    names = []
    embeddings = []
    for row in result.result_set:
        name, embedding = row[0], row[1]
        if name and embedding:
            names.append(name)
            embeddings.append(embedding)
    if not embeddings:
        return names, None
    return names, np.array(embeddings, dtype=np.float32)


def load_unlinked_chunks(graph) -> tuple[list[str], list[np.ndarray]]:
    """Load chunk IDs and embeddings for chunks without HAS_ENTITY edges."""
    result = graph.query(UNLINKED_CHUNKS_QUERY)
    ids = []
    embeddings = []
    for row in result.result_set:
        chunk_id, embedding = row[0], row[1]
        if chunk_id and embedding:
            ids.append(chunk_id)
            embeddings.append(np.array(embedding, dtype=np.float32))
    return ids, embeddings


def compute_top_entities(
    chunk_vec: np.ndarray,
    entity_matrix: np.ndarray,
    entity_norms: np.ndarray,
    entity_names: list[str],
    threshold: float,
    max_entities: int,
) -> list[tuple[str, float]]:
    """Return top entity matches for a chunk vector above the threshold."""
    chunk_norm = np.linalg.norm(chunk_vec)
    if chunk_norm == 0:
        return []
    similarities = entity_matrix @ chunk_vec / (entity_norms * chunk_norm)
    # Get indices above threshold
    above = np.where(similarities >= threshold)[0]
    if len(above) == 0:
        return []
    # Sort by similarity descending, take top N
    top_idx = above[np.argsort(-similarities[above])[:max_entities]]
    return [(entity_names[i], float(similarities[i])) for i in top_idx]


def backfill_graph(
    db: FalkorDB,
    graph_name: str,
    threshold: float,
    max_entities: int,
    batch_size: int,
    dry_run: bool,
) -> dict:
    """Link chunks to entities for one graph. Returns stats dict."""
    stats = {
        "graph": graph_name,
        "total_entities": 0,
        "total_unlinked": 0,
        "processed": 0,
        "edges_created": 0,
        "skipped_no_match": 0,
    }

    graph = db.select_graph(graph_name)

    entity_names, entity_matrix = load_entities(graph)
    stats["total_entities"] = len(entity_names)

    if entity_matrix is None or len(entity_names) == 0:
        logger.warning("[%s] No entities with embeddings found", graph_name)
        return stats

    # Precompute entity norms for efficiency
    entity_norms = np.linalg.norm(entity_matrix, axis=1)
    # Avoid division by zero
    entity_norms = np.where(entity_norms == 0, 1e-10, entity_norms)

    logger.info("[%s] Loaded %d entities with embeddings", graph_name, len(entity_names))

    chunk_ids, chunk_embeddings = load_unlinked_chunks(graph)
    stats["total_unlinked"] = len(chunk_ids)

    if not chunk_ids:
        logger.info("[%s] All chunks already linked to entities", graph_name)
        return stats

    if dry_run:
        logger.info(
            "[%s] DRY RUN: %d unlinked chunks, %d entities available",
            graph_name, len(chunk_ids), len(entity_names),
        )
        return stats

    logger.info(
        "[%s] Processing %d unlinked chunks (threshold=%.2f, max_entities=%d)",
        graph_name, len(chunk_ids), threshold, max_entities,
    )

    for i in range(0, len(chunk_ids), batch_size):
        batch_ids = chunk_ids[i : i + batch_size]
        batch_vecs = chunk_embeddings[i : i + batch_size]
        batch_num = i // batch_size + 1
        total_batches = (len(chunk_ids) + batch_size - 1) // batch_size
        batch_edges = 0

        for cid, cvec in zip(batch_ids, batch_vecs):
            matches = compute_top_entities(
                cvec, entity_matrix, entity_norms, entity_names, threshold, max_entities
            )
            if not matches:
                stats["skipped_no_match"] += 1
                continue

            for ename, _score in matches:
                graph.query(MERGE_EDGE_QUERY, {"cid": cid, "name": ename})
                stats["edges_created"] += 1
                batch_edges += 1

            stats["processed"] += 1

        logger.info(
            "[%s] Batch %d/%d: %d edges created",
            graph_name, batch_num, total_batches, batch_edges,
        )

    return stats


def main():
    parser = argparse.ArgumentParser(
        description="Link chunks to entities via embedding similarity (no LLM calls)."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Count unlinked chunks without creating edges.",
    )
    parser.add_argument(
        "--project-root",
        help="Project root for graph name derivation (overrides PROJECT_ROOT env var).",
    )
    parser.add_argument(
        "--namespace",
        help="Namespace for shared graph.",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.5,
        help="Cosine similarity threshold for linking (default: 0.5).",
    )
    parser.add_argument(
        "--max-entities",
        type=int,
        default=5,
        help="Maximum entities to link per chunk (default: 5).",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=50,
        help="Chunks to process per batch for progress logging (default: 50).",
    )
    args = parser.parse_args()

    project_root = args.project_root or os.environ.get("PROJECT_ROOT", "")
    if project_root or args.namespace:
        set_graph_name(project_root, namespace=args.namespace)

    # Re-import GRAPH_NAME after set_graph_name may have updated it
    from common import GRAPH_NAME

    db = get_db()

    logger.info("Processing graph: %s", GRAPH_NAME)

    start = time.time()
    stats = backfill_graph(
        db, GRAPH_NAME, args.threshold, args.max_entities, args.batch_size, args.dry_run
    )
    elapsed = time.time() - start

    # Summary
    print("\n=== Backfill Summary ===")
    print(
        f"  {stats['graph']}: {stats['total_entities']} entities, "
        f"{stats['total_unlinked']} unlinked chunks, "
        f"{stats['processed']} linked, {stats['edges_created']} edges, "
        f"{stats['skipped_no_match']} no-match"
    )

    if not args.dry_run:
        print(f"Linked: {stats['processed']} chunks, {stats['edges_created']} edges created")
        if stats["skipped_no_match"]:
            print(f"Skipped: {stats['skipped_no_match']} chunks had no entities above threshold")
    print(f"Time: {elapsed:.1f}s")


if __name__ == "__main__":
    main()
