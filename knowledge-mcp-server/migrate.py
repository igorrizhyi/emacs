"""Migrate existing markdown knowledge files into FalkorDB hybrid vector+graph store."""

import argparse
import asyncio
import os
import sys

from falkordb import FalkorDB

from common import (
    FALKORDB_HOST,
    FALKORDB_PORT,
    GRAPH_NAME,
    get_graph,
    init_schema,
    set_graph_name,
    chunk_knowledge_file,
    chunk_report,
    ingest_chunks,
    create_topic_links,
    create_similarity_edges,
    create_cross_role_edges,
    detect_supersession,
    create_supersedes_edges,
)
from entities import extract_and_store_entities

ROLE_MAP = {
    "dev.md": "dev",
    "researcher.md": "researcher",
    "tester.md": "tester",
    "lead.md": "lead",
}


def _post_ingest(graph, all_chunks, *, with_entities=False, with_supersession=False):
    """Run post-ingest steps: cross-role edges, supersession, entity extraction.

    Returns (supersession_count, entity_count, rel_count) for stats.
    """
    new_ids = [c["id"] for c in all_chunks]

    print("Creating cross-role edges...")
    create_cross_role_edges(graph, new_ids)

    supersession_count = 0
    if with_supersession:
        print("Detecting supersessions (LLM)...")
        supersessions = detect_supersession(graph, all_chunks)
        supersession_count = len(supersessions)
        if supersessions:
            create_supersedes_edges(graph, supersessions)
            print(f"  Created {supersession_count} SUPERSEDES edge(s)")
        else:
            print("  No supersessions found")

    entity_count = 0
    rel_count = 0
    if with_entities:
        print("Extracting entities (LLM)...")
        entity_count, rel_count = asyncio.run(
            extract_and_store_entities(graph, all_chunks)
        )
        print(f"  Extracted {entity_count} entities, {rel_count} relationships")

    return supersession_count, entity_count, rel_count


def migrate(knowledge_dir: str, clean: bool = False, project: str = None,
            with_entities: bool = False, with_supersession: bool = False):
    graph = get_graph()

    if clean:
        print("Cleaning graph...")
        try:
            graph.delete()
        except Exception:
            pass  # graph may not exist yet
        # Re-select after delete
        graph = get_graph()
        # Remove legacy ontology artifact
        ontology_path = os.path.join(os.path.dirname(__file__), "ontology.json")
        if os.path.exists(ontology_path):
            os.unlink(ontology_path)
            print("Removed legacy ontology.json")

    print("Initializing schema...")
    init_schema(graph)

    all_chunks: list[dict] = []
    file_stats: dict[str, int] = {}

    for filename, role in ROLE_MAP.items():
        filepath = os.path.join(knowledge_dir, filename)
        if not os.path.exists(filepath):
            print(f"  Warning: {filepath} not found, skipping.")
            continue

        chunks = chunk_knowledge_file(filepath, role, project=project)
        file_stats[filename] = len(chunks)
        all_chunks.extend(chunks)
        print(f"  {filename}: {len(chunks)} chunks")

    if not all_chunks:
        print("No chunks to ingest.")
        return

    print(f"\nIngesting {len(all_chunks)} chunks...")
    ingest_chunks(graph, all_chunks, project=project)

    print("Creating topic links...")
    create_topic_links(graph, all_chunks)

    print("Creating similarity edges...")
    create_similarity_edges(graph)

    supersession_count, entity_count, rel_count = _post_ingest(
        graph, all_chunks,
        with_entities=with_entities,
        with_supersession=with_supersession,
    )

    # Print stats
    topic_count = graph.query("MATCH (t:Topic) RETURN count(t)").result_set[0][0]
    related_count = graph.query("MATCH ()-[r:RELATED_TO]->() RETURN count(r)").result_set[0][0]

    print(f"\n--- Migration Stats ---")
    for fname, count in file_stats.items():
        print(f"  {fname}: {count} chunks")
    print(f"  Total chunks: {len(all_chunks)}")
    print(f"  Topics: {topic_count}")
    print(f"  RELATED_TO edges: {related_count}")
    if with_supersession:
        print(f"  Supersessions: {supersession_count}")
    if with_entities:
        print(f"  Entities: {entity_count}, Relationships: {rel_count}")
    print("Done.")


def _infer_role(content: str) -> str:
    """Infer role from report content heuristics."""
    if "Research Report" in content:
        return "researcher"
    if "Branch:" in content or "Commit:" in content:
        return "dev"
    return "dev"


def migrate_reports(reports_dir: str, project: str = None,
                    with_entities: bool = False, with_supersession: bool = False):
    """Import historical task reports from .agent-shell/reports/."""
    graph = get_graph()
    init_schema(graph)

    print(f"Scanning reports in: {reports_dir}")

    all_chunks: list[dict] = []
    report_count = 0
    sessions_scanned = 0

    # Sort session dirs by mtime (oldest first) for correct supersession ordering
    session_entries = os.listdir(reports_dir)
    session_entries.sort(key=lambda e: os.path.getmtime(os.path.join(reports_dir, e)))
    for session_id in session_entries:
        session_path = os.path.join(reports_dir, session_id)
        if not os.path.isdir(session_path):
            print(f"  Skipping non-directory: {session_id}")
            continue

        print(f"\n[session: {session_id}]")
        sessions_scanned += 1

        # Sort report files by mtime (oldest first) for correct supersession ordering
        report_files = [f for f in os.listdir(session_path) if f.endswith(".md")]
        report_files.sort(key=lambda f: os.path.getmtime(os.path.join(session_path, f)))
        for filename in report_files:
            filepath = os.path.join(session_path, filename)
            with open(filepath) as f:
                content = f.read()
            if not content.strip():
                print(f"  Skipping empty: {filename}")
                continue

            request_id = filename[:-3]  # strip .md
            role = _infer_role(content)
            chunks = chunk_report(content, request_id, role, project=project)
            if not chunks:
                print(f"  WARNING: {filename} produced 0 chunks (content too short?)")
                continue
            all_chunks.extend(chunks)
            report_count += 1
            print(f"  {session_id}/{filename}: {len(chunks)} chunks (role={role})")

    print(f"\nSessions scanned: {sessions_scanned}")

    if not all_chunks:
        print("No report chunks to ingest.")
        return

    print(f"\nIngesting {len(all_chunks)} chunks from {report_count} reports...")
    ingest_chunks(graph, all_chunks, project=project)

    print("Creating topic links...")
    create_topic_links(graph, all_chunks)

    print("Creating similarity edges (full rebuild)...")
    create_similarity_edges(graph)

    supersession_count, entity_count, rel_count = _post_ingest(
        graph, all_chunks,
        with_entities=with_entities,
        with_supersession=with_supersession,
    )

    print(f"\n--- Report Migration Stats ---")
    print(f"  Reports processed: {report_count}")
    print(f"  Chunks created: {len(all_chunks)}")
    if with_supersession:
        print(f"  Supersessions: {supersession_count}")
    if with_entities:
        print(f"  Entities: {entity_count}, Relationships: {rel_count}")
    print("Done.")


def migrate_from_graph(source_graph_name: str, project: str):
    """Copy all Chunk nodes from a source graph into the current namespace graph.

    Preserves embeddings, Topic nodes, and all relationships (HAS_TOPIC,
    FOR_ROLE, RELATED_TO).  Uses MERGE on chunk/topic IDs for idempotency.
    """
    db = FalkorDB(host=FALKORDB_HOST, port=FALKORDB_PORT)
    src = db.select_graph(source_graph_name)
    dst = get_graph()

    print(f"Source graph: {source_graph_name}")
    print(f"Target graph: {GRAPH_NAME}")
    print(f"Project tag:  {project}")

    init_schema(dst)

    # --- 1. Copy Chunk nodes ---
    print("\nReading chunks from source graph...")
    res = src.query(
        "MATCH (c:Chunk) "
        "RETURN c.id, c.content, c.embedding, c.source, c.section, "
        "       c.roles, c.type, c.created_at, c.project"
    )
    chunks = res.result_set
    print(f"  Found {len(chunks)} chunks")

    for i, row in enumerate(chunks):
        cid, content, emb, source, section, roles, ctype, created_at, _proj = row
        params = {
            "id": cid,
            "content": content,
            "source": source or "",
            "section": section or "",
            "roles": roles or "",
            "type": ctype or "knowledge",
            "ts": created_at or "",
            "project": project,
        }
        if emb is not None:
            dst.query(
                """
                MERGE (c:Chunk {id: $id})
                SET c.content    = $content,
                    c.embedding  = vecf32($vec),
                    c.source     = $source,
                    c.section    = $section,
                    c.roles      = $roles,
                    c.type       = $type,
                    c.created_at = $ts,
                    c.project    = $project
                """,
                params={**params, "vec": list(emb)},
            )
        else:
            dst.query(
                """
                MERGE (c:Chunk {id: $id})
                SET c.content    = $content,
                    c.source     = $source,
                    c.section    = $section,
                    c.roles      = $roles,
                    c.type       = $type,
                    c.created_at = $ts,
                    c.project    = $project
                """,
                params=params,
            )
        if (i + 1) % 50 == 0:
            print(f"  Copied {i + 1}/{len(chunks)} chunks...")

    print(f"  Copied {len(chunks)} chunks")

    # --- 2. Copy Topic nodes and HAS_TOPIC relationships ---
    print("Copying topics and HAS_TOPIC edges...")
    topic_res = src.query(
        "MATCH (c:Chunk)-[:HAS_TOPIC]->(t:Topic) "
        "RETURN c.id, t.name"
    )
    topic_edges = topic_res.result_set
    for cid, tname in topic_edges:
        dst.query(
            """
            MATCH (c:Chunk {id: $id})
            MERGE (t:Topic {name: $topic})
            MERGE (c)-[:HAS_TOPIC]->(t)
            """,
            params={"id": cid, "topic": tname},
        )
    print(f"  Copied {len(topic_edges)} HAS_TOPIC edges")

    # --- 3. Copy FOR_ROLE relationships ---
    print("Copying FOR_ROLE edges...")
    role_res = src.query(
        "MATCH (c:Chunk)-[:FOR_ROLE]->(r:Role) "
        "RETURN c.id, r.name"
    )
    role_edges = role_res.result_set
    for cid, rname in role_edges:
        dst.query(
            """
            MATCH (c:Chunk {id: $id})
            MERGE (r:Role {name: $role})
            MERGE (c)-[:FOR_ROLE]->(r)
            """,
            params={"id": cid, "role": rname},
        )
    print(f"  Copied {len(role_edges)} FOR_ROLE edges")

    # --- 4. Copy RELATED_TO relationships ---
    print("Copying RELATED_TO edges...")
    rel_res = src.query(
        "MATCH (a:Chunk)-[r:RELATED_TO]->(b:Chunk) "
        "RETURN a.id, b.id, r.score"
    )
    rel_edges = rel_res.result_set
    for aid, bid, score in rel_edges:
        dst.query(
            """
            MATCH (a:Chunk {id: $a}), (b:Chunk {id: $b})
            MERGE (a)-[r:RELATED_TO]->(b)
            SET r.score = $score
            """,
            params={"a": aid, "b": bid, "score": score},
        )
    print(f"  Copied {len(rel_edges)} RELATED_TO edges")

    # --- Stats ---
    dst_chunks = dst.query("MATCH (c:Chunk) RETURN count(c)").result_set[0][0]
    dst_topics = dst.query("MATCH (t:Topic) RETURN count(t)").result_set[0][0]
    dst_related = dst.query("MATCH ()-[r:RELATED_TO]->() RETURN count(r)").result_set[0][0]

    print(f"\n--- Graph-to-Graph Migration Stats ---")
    print(f"  Source chunks copied: {len(chunks)}")
    print(f"  HAS_TOPIC edges:     {len(topic_edges)}")
    print(f"  FOR_ROLE edges:      {len(role_edges)}")
    print(f"  RELATED_TO edges:    {len(rel_edges)}")
    print(f"  Target graph totals: {dst_chunks} chunks, {dst_topics} topics, {dst_related} RELATED_TO")
    print("Done.")


def supersession_only():
    """Load all chunks from graph and run supersession detection only."""
    graph = get_graph()

    print("Loading all chunks from graph...")
    res = graph.query(
        "MATCH (c:Chunk) "
        "RETURN c.id, c.content, c.embedding, c.source, c.roles, "
        "       c.type, c.project, c.created_at"
    )
    rows = res.result_set
    print(f"  Loaded {len(rows)} chunks")

    if not rows:
        print("No chunks found in graph.")
        return

    # Build chunk dicts and sort by created_at (oldest first)
    chunks = []
    for row in rows:
        cid, content, emb, source, roles, ctype, project, created_at = row
        chunks.append({
            "id": cid,
            "content": content or "",
            "embedding": list(emb) if emb is not None else None,
            "source": source or "",
            "roles": roles or "",
            "type": ctype or "knowledge",
            "project": project or "",
            "created_at": created_at or "",
        })

    chunks.sort(key=lambda c: c["created_at"])
    print(f"  Sorted by created_at (oldest: {chunks[0]['created_at']}, "
          f"newest: {chunks[-1]['created_at']})")

    print("Detecting supersessions (LLM)...")
    supersessions = detect_supersession(graph, chunks)
    print(f"  Found {len(supersessions)} supersession(s)")

    if supersessions:
        create_supersedes_edges(graph, supersessions)
        print(f"  Created {len(supersessions)} SUPERSEDES edge(s)")

    # Stats
    sup_count = graph.query(
        "MATCH ()-[s:SUPERSEDES]->() RETURN count(s)"
    ).result_set[0][0]
    print(f"\n--- Supersession-Only Stats ---")
    print(f"  Total chunks in graph: {len(chunks)}")
    print(f"  New SUPERSEDES edges: {len(supersessions)}")
    print(f"  Total SUPERSEDES edges: {sup_count}")
    print("Done.")


def main():
    project_root = os.environ.get("PROJECT_ROOT")
    if project_root:
        base_dir = project_root
    else:
        base_dir = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))

    default_knowledge_dir = os.path.join(base_dir, ".agent-shell", "knowledge")
    default_reports_dir = os.path.join(base_dir, ".agent-shell", "reports")

    parser = argparse.ArgumentParser(
        description="Migrate markdown knowledge files into FalkorDB hybrid vector+graph store"
    )
    parser.add_argument(
        "--knowledge-dir",
        default=default_knowledge_dir,
        help=f"Path to knowledge directory (default: {default_knowledge_dir})",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Delete existing graph and re-create from scratch",
    )
    parser.add_argument(
        "--reports",
        action="store_true",
        help="Import historical task reports from .agent-shell/reports/",
    )
    parser.add_argument(
        "--reports-dir",
        default=default_reports_dir,
        help=f"Path to reports directory (default: {default_reports_dir})",
    )
    parser.add_argument(
        "--project-root",
        help="Project root for graph name derivation (overrides PROJECT_ROOT env var)",
    )
    parser.add_argument(
        "--namespace",
        help="Namespace for shared graph. When set, targets the namespace graph "
             "(knowledge_<namespace>) and tags all chunks with a project derived "
             "from --project-root.",
    )
    parser.add_argument(
        "--from-graph",
        help="Source graph name for graph-to-graph migration (e.g. knowledge_doom_abc123). "
             "Copies all Chunk nodes into the namespace graph. Requires --namespace.",
    )
    parser.add_argument(
        "--with-entities",
        action="store_true",
        help="Run entity extraction (requires LLM calls, slow)",
    )
    parser.add_argument(
        "--with-supersession",
        action="store_true",
        help="Run supersession detection (requires LLM calls, slow)",
    )
    parser.add_argument(
        "--full",
        action="store_true",
        help="Shorthand for --with-entities --with-supersession",
    )
    parser.add_argument(
        "--supersession-only",
        action="store_true",
        help="Load all existing chunks from graph and run supersession detection only "
             "(no re-ingest, no topics, no similarity edges)",
    )
    args = parser.parse_args()

    if args.full:
        args.with_entities = True
        args.with_supersession = True

    graph_root = args.project_root or project_root
    if graph_root:
        set_graph_name(graph_root, namespace=args.namespace)
    elif args.namespace:
        set_graph_name("", namespace=args.namespace)

    # Derive project tag when migrating into a namespace graph
    project = None
    if args.namespace:
        if graph_root:
            project = os.path.basename(graph_root.rstrip("/")) or "default"
        else:
            project = "default"
        print(f"Namespace mode: graph={GRAPH_NAME}, project={project}")

    if args.supersession_only:
        supersession_only()
        return

    if args.from_graph:
        if not args.namespace:
            print("Error: --from-graph requires --namespace")
            sys.exit(1)
        migrate_from_graph(args.from_graph, project=project)
        return

    if args.reports:
        if not os.path.isdir(args.reports_dir):
            print(f"Error: Reports directory not found: {args.reports_dir}")
            sys.exit(1)
        migrate_reports(args.reports_dir, project=project,
                        with_entities=args.with_entities,
                        with_supersession=args.with_supersession)
        return

    if not os.path.isdir(args.knowledge_dir):
        print(f"Error: Knowledge directory not found: {args.knowledge_dir}")
        sys.exit(1)

    migrate(args.knowledge_dir, clean=args.clean, project=project,
            with_entities=args.with_entities,
            with_supersession=args.with_supersession)


if __name__ == "__main__":
    main()
