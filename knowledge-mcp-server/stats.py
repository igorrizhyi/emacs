#!/usr/bin/env python3
"""Report statistics on chunks and supersession in a knowledge graph."""

import argparse
import os
import sys

from falkordb import FalkorDB


def main():
    parser = argparse.ArgumentParser(description="Knowledge graph chunk statistics")
    parser.add_argument("graph", help="FalkorDB graph name (e.g. knowledge_doom)")
    args = parser.parse_args()

    host = os.environ.get("FALKORDB_HOST", "127.0.0.1")
    port = int(os.environ.get("FALKORDB_PORT", "6380"))

    try:
        db = FalkorDB(host=host, port=port)
        graph = db.select_graph(args.graph)
    except Exception as e:
        print(f"Error connecting to FalkorDB at {host}:{port}: {e}", file=sys.stderr)
        sys.exit(1)

    # Total chunks
    total = graph.query("MATCH (c:Chunk) RETURN count(c)").result_set[0][0]

    # Superseded chunks (have at least one incoming SUPERSEDES edge)
    superseded = graph.query(
        "MATCH ()-[:SUPERSEDES]->(old:Chunk) RETURN count(DISTINCT old)"
    ).result_set[0][0]

    active = total - superseded

    print(f"Graph: {args.graph}")
    print(f"{'Total chunks:':<30} {total}")
    print(f"{'Active chunks:':<30} {active}")
    print(f"{'Superseded chunks:':<30} {superseded}")
    print()

    # Edge type breakdown
    print("Supersession edge breakdown:")
    edge_types = graph.query(
        "MATCH ()-[s:SUPERSEDES]->() RETURN s.type AS type, count(s) AS cnt ORDER BY cnt DESC"
    )
    if edge_types.result_set:
        for row in edge_types.result_set:
            print(f"  {row[0] or 'UNKNOWN':<20} {row[1]}")
    else:
        print("  (none)")
    print()

    # Top 5 most-superseded sources
    print("Top 5 most-superseded sources:")
    top_sources = graph.query(
        """
        MATCH ()-[:SUPERSEDES]->(old:Chunk)
        RETURN old.source AS source, count(DISTINCT old) AS cnt
        ORDER BY cnt DESC
        LIMIT 5
        """
    )
    if top_sources.result_set:
        for row in top_sources.result_set:
            print(f"  {row[0]:<40} {row[1]} old chunks")
    else:
        print("  (none)")


if __name__ == "__main__":
    main()
