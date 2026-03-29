#!/usr/bin/env python3
"""Backfill Feature/Scenario nodes for existing knowledge graphs.

Scans all theme entities, gathers chunk context per theme, calls LLM to
extract Features with Gherkin Scenarios, deduplicates, and upserts.

Usage:
    python backfill_features.py --dry-run                    # list themes without LLM calls
    python backfill_features.py --graph knowledge_my_ns      # specific graph
    python backfill_features.py --batch-size 3               # smaller batches
"""

import argparse
import asyncio
import logging
import time

import litellm
from falkordb import FalkorDB

from common import (
    CLASSIFICATION_MODEL,
    FALKORDB_HOST,
    FALKORDB_PORT,
    init_schema,
)
from features import (
    FEATURE_EXTRACTION_PROMPT,
    find_existing_feature,
    find_feature_by_entity_overlap,
    gather_feature_context,
    parse_feature_extraction_output,
    upsert_feature,
    _fetch_existing_features,
    _fetch_feature_entities,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

THEMES_QUERY = "MATCH (e:Entity {type: 'theme'}) RETURN e.name, e.description"


def get_db() -> FalkorDB:
    return FalkorDB(host=FALKORDB_HOST, port=FALKORDB_PORT)


async def process_graph(
    db: FalkorDB,
    graph_name: str,
    batch_size: int,
    dry_run: bool,
) -> dict:
    """Extract Features for all themes in one graph. Returns stats dict."""
    stats = {
        "graph": graph_name,
        "themes_total": 0,
        "themes_skipped": 0,
        "features_created": 0,
        "features_updated": 0,
        "errors": 0,
    }

    graph = db.select_graph(graph_name)
    init_schema(graph)

    # Find all theme entities
    result = graph.query(THEMES_QUERY)
    themes = [{"name": r[0], "description": r[1] or ""} for r in result.result_set]
    stats["themes_total"] = len(themes)

    if not themes:
        logger.info("[%s] No theme entities found", graph_name)
        return stats

    if dry_run:
        logger.info("[%s] DRY RUN: %d themes found:", graph_name, len(themes))
        for i, t in enumerate(themes, 1):
            chunks = gather_feature_context(graph, t["name"])
            status = f"{len(chunks)} chunks" if len(chunks) >= 2 else "SKIP (<2 chunks)"
            logger.info("  %d. %s — %s", i, t["name"], status)
        return stats

    # Load existing features for dedup (refreshed after each batch)
    existing_features = _fetch_existing_features(graph)
    existing_feature_entities = _fetch_feature_entities(graph)

    # Entity list for IMPLEMENTS references
    all_entities_result = graph.query(
        "MATCH (e:Entity) WHERE e.type <> 'theme' RETURN e.name, e.type LIMIT 200"
    )
    entity_list = [f"{r[0]} ({r[1]})" for r in all_entities_result.result_set]

    for i, theme in enumerate(themes, 1):
        logger.info(
            "[%s] Processing theme %d/%d: %s",
            graph_name, i, len(themes), theme["name"],
        )

        # Gather context chunks
        context_chunks = gather_feature_context(graph, theme["name"])
        if len(context_chunks) < 2:
            logger.info("  Skipping — only %d chunk(s)", len(context_chunks))
            stats["themes_skipped"] += 1
            continue

        # Assemble prompt
        chunk_contents = "\n---\n".join(
            f"[{c['source']} / {c['section']}]\n{c['content']}"
            for c in context_chunks
        )
        prompt = FEATURE_EXTRACTION_PROMPT.format(
            theme_name=theme["name"],
            theme_description=theme["description"],
            existing_features="\n".join(f"- {f}" for f in existing_features) or "None yet",
            entity_list="\n".join(f"- {e}" for e in entity_list[:50]) or "None",
            chunk_contents=chunk_contents,
        )

        # LLM call
        try:
            resp = await litellm.acompletion(
                model=CLASSIFICATION_MODEL,
                messages=[{"role": "user", "content": prompt}],
            )
            output = resp.choices[0].message.content or ""
        except Exception:
            logger.warning("  LLM error for theme '%s', skipping", theme["name"], exc_info=True)
            stats["errors"] += 1
            continue

        # Parse
        feature_data = parse_feature_extraction_output(output)
        if not feature_data:
            logger.warning("  Failed to parse LLM output for theme '%s'", theme["name"])
            stats["errors"] += 1
            continue

        # Dedup — fuzzy name match
        matched = find_existing_feature(feature_data["name"], existing_features)
        if matched:
            feature_data["name"] = matched
            stats["features_updated"] += 1
        else:
            # Entity overlap check
            proposed_entities = set(feature_data.get("implements", []))
            overlap_match = find_feature_by_entity_overlap(
                proposed_entities, existing_feature_entities
            )
            if overlap_match:
                feature_data["name"] = overlap_match
                stats["features_updated"] += 1
            else:
                stats["features_created"] += 1

        # Validate DEPENDS_ON
        feature_data["depends_on"] = [
            d for d in feature_data["depends_on"]
            if d in existing_features or find_existing_feature(d, existing_features)
        ]

        # Upsert
        await upsert_feature(graph, feature_data)

        # Track for subsequent themes
        if feature_data["name"] not in existing_features:
            existing_features.append(feature_data["name"])

        # Rate limit: pause between batches
        if i % batch_size == 0 and i < len(themes):
            logger.info("  Batch pause (processed %d themes)...", i)
            await asyncio.sleep(2)

    return stats


async def async_main(args):
    db = get_db()

    # Determine which graphs to process
    if args.graph:
        graph_names = [args.graph]
    else:
        all_graphs = db.list_graphs()
        graph_names = [g for g in all_graphs if g.startswith("knowledge_")]

    if not graph_names:
        logger.warning("No knowledge_* graphs found")
        return

    logger.info("Graphs to process: %s", ", ".join(graph_names))

    all_stats = []
    start = time.time()

    for gname in graph_names:
        stats = await process_graph(db, gname, args.batch_size, args.dry_run)
        all_stats.append(stats)

    elapsed = time.time() - start

    # Summary
    print("\n=== Feature Backfill Summary ===")
    for s in all_stats:
        print(
            f"  {s['graph']}: {s['themes_total']} themes, "
            f"{s['themes_skipped']} skipped, "
            f"{s['features_created']} created, "
            f"{s['features_updated']} updated, "
            f"{s['errors']} errors"
        )
    print(f"Time: {elapsed:.1f}s")


def main():
    parser = argparse.ArgumentParser(
        description="Backfill Feature/Scenario nodes from existing theme entities."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List themes and chunk counts without calling LLM.",
    )
    parser.add_argument(
        "--graph",
        help="Process a specific graph instead of all knowledge_* graphs.",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=5,
        help="Themes per batch before rate-limit pause (default: 5).",
    )
    args = parser.parse_args()
    asyncio.run(async_main(args))


if __name__ == "__main__":
    main()
