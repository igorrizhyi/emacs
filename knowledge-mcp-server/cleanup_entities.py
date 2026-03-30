#!/usr/bin/env python3
"""Remove low-value/junk entities from the FalkorDB knowledge graph.

Runs in dry-run mode by default.  Pass --execute to actually delete.
"""

import argparse
import os
import re
import sys

from falkordb import FalkorDB

# ---------------------------------------------------------------------------
# Junk entity definitions
# ---------------------------------------------------------------------------

# Exact names (normalized: uppercase, hyphens/underscores → spaces)
JUNK_EXACT = {
    # Language constructs / primitives the extraction prompt says to skip
    "FACE",
    "MAP!",
    "MEMQ",
    "LET* BINDINGS",
    "INVISIBLE T",
    "CL MAPCAR",
    "CL FIND IF",
    "SEQ GROUP BY",
    "WRITE REGION",
    "MAKE OVERLAY",
    "MAKE PROCESS",
    "JSON SERIALIZE",
    "STRING MATCH P",
    "GLOBAL SET KEY",
    "REPLACE MATCH",
    "FRONT ADVANCE",
    # Property values / flags
    "INVISIBLE T",
    # Generic variable names
    "RUNARGS",
}

# Very short generic fragments (exact match, ≤5 chars or known patterns)
JUNK_SHORT_FRAGMENTS = {
    "OV ME",
    "OV PAD",
    "M START",
}

JUNK_EXACT.update(JUNK_SHORT_FRAGMENTS)


def _is_elisp_primitive(name: str) -> bool:
    """Heuristic: names that look like bare Elisp primitives / builtins.

    Matches patterns like single common Elisp functions that slipped through,
    e.g. SETQ, DEFVAR, PROGN, etc.  Only flags very short all-alpha names
    that are well-known language keywords.
    """
    elisp_keywords = {
        "SETQ", "DEFVAR", "DEFUN", "DEFMACRO", "PROGN", "LAMBDA",
        "LET", "LET*", "IF", "WHEN", "UNLESS", "COND", "WHILE",
        "NIL", "T", "CONS", "CAR", "CDR", "APPEND", "MAPCAR",
        "FUNCALL", "APPLY", "EVAL", "QUOTE", "SETF",
    }
    return name in elisp_keywords


def classify_junk(name: str, entity_type: str) -> str | None:
    """Return a reason string if the entity is junk, else None."""
    if name in JUNK_EXACT:
        return "exact-match junk list"
    if _is_elisp_primitive(name):
        return "elisp primitive/keyword"
    # Very short identifiers (1-2 chars) that aren't meaningful
    if len(name) <= 2 and entity_type == "identifier":
        return f"very short identifier ({len(name)} chars)"
    return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Remove low-value/junk entities from the knowledge graph."
    )
    parser.add_argument(
        "graph",
        help="FalkorDB graph name (e.g. knowledge_doom_5f4331)",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Actually delete entities (default is dry-run)",
    )
    args = parser.parse_args()

    host = os.environ.get("FALKORDB_HOST", "127.0.0.1")
    port = int(os.environ.get("FALKORDB_PORT", "6380"))

    try:
        db = FalkorDB(host=host, port=port)
        graph = db.select_graph(args.graph)
    except Exception as e:
        print(f"Error connecting to FalkorDB at {host}:{port}: {e}", file=sys.stderr)
        sys.exit(1)

    # Fetch all entities
    result = graph.query("MATCH (e:Entity) RETURN e.name, e.type")
    all_entities = [(row[0], row[1]) for row in result.result_set]
    total_before = len(all_entities)

    print(f"Graph: {args.graph}")
    print(f"Total entities: {total_before}")
    print(f"Mode: {'EXECUTE' if args.execute else 'DRY-RUN'}")
    print()

    # Classify
    junk_list = []
    for name, etype in all_entities:
        reason = classify_junk(name, etype or "")
        if reason:
            junk_list.append((name, etype, reason))

    if not junk_list:
        print("No junk entities found.")
        return

    print(f"Junk entities found: {len(junk_list)}")
    print("-" * 70)
    for name, etype, reason in sorted(junk_list):
        print(f"  {name:<40} type={etype or '?':<12} reason={reason}")
    print("-" * 70)

    if args.execute:
        print()
        print("Deleting...")
        deleted = 0
        for name, etype, reason in junk_list:
            try:
                graph.query(
                    "MATCH (e:Entity {name: $name}) DETACH DELETE e",
                    params={"name": name},
                )
                deleted += 1
            except Exception as e:
                print(f"  ERROR deleting {name!r}: {e}", file=sys.stderr)

        # Count remaining
        remaining = graph.query("MATCH (e:Entity) RETURN count(e)").result_set[0][0]
        print()
        print(f"Deleted: {deleted}")
        print(f"Entities remaining: {remaining}")
    else:
        print()
        print(f"Would delete {len(junk_list)} entities. Re-run with --execute to apply.")


if __name__ == "__main__":
    main()
