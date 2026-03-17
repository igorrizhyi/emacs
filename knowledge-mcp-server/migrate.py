"""Migrate existing markdown knowledge files into FalkorDB hybrid vector+graph store."""

import argparse
import os
import sys

from common import (
    GRAPH_NAME,
    get_graph,
    init_schema,
    set_graph_name,
    chunk_knowledge_file,
    chunk_report,
    ingest_chunks,
    create_topic_links,
    create_similarity_edges,
)

ROLE_MAP = {
    "dev.md": "dev",
    "researcher.md": "researcher",
    "tester.md": "tester",
    "lead.md": "lead",
}


def migrate(knowledge_dir: str, clean: bool = False):
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

        chunks = chunk_knowledge_file(filepath, role)
        file_stats[filename] = len(chunks)
        all_chunks.extend(chunks)
        print(f"  {filename}: {len(chunks)} chunks")

    if not all_chunks:
        print("No chunks to ingest.")
        return

    print(f"\nIngesting {len(all_chunks)} chunks...")
    ingest_chunks(graph, all_chunks)

    print("Creating topic links...")
    create_topic_links(graph, all_chunks)

    print("Creating similarity edges...")
    create_similarity_edges(graph)

    # Print stats
    topic_count = graph.query("MATCH (t:Topic) RETURN count(t)").result_set[0][0]
    related_count = graph.query("MATCH ()-[r:RELATED_TO]->() RETURN count(r)").result_set[0][0]

    print(f"\n--- Migration Stats ---")
    for fname, count in file_stats.items():
        print(f"  {fname}: {count} chunks")
    print(f"  Total chunks: {len(all_chunks)}")
    print(f"  Topics: {topic_count}")
    print(f"  RELATED_TO edges: {related_count}")
    print("Done.")


def _infer_role(content: str) -> str:
    """Infer role from report content heuristics."""
    if "Research Report" in content:
        return "researcher"
    if "Branch:" in content or "Commit:" in content:
        return "dev"
    return "dev"


def migrate_reports(reports_dir: str):
    """Import historical task reports from .agent-shell/reports/."""
    graph = get_graph()
    init_schema(graph)

    print(f"Scanning reports in: {reports_dir}")

    all_chunks: list[dict] = []
    report_count = 0
    sessions_scanned = 0

    for session_id in sorted(os.listdir(reports_dir)):
        session_path = os.path.join(reports_dir, session_id)
        if not os.path.isdir(session_path):
            print(f"  Skipping non-directory: {session_id}")
            continue

        print(f"\n[session: {session_id}]")
        sessions_scanned += 1

        for filename in sorted(os.listdir(session_path)):
            if not filename.endswith(".md"):
                print(f"  Skipping non-md: {filename}")
                continue
            filepath = os.path.join(session_path, filename)
            with open(filepath) as f:
                content = f.read()
            if not content.strip():
                print(f"  Skipping empty: {filename}")
                continue

            request_id = filename[:-3]  # strip .md
            role = _infer_role(content)
            chunks = chunk_report(content, request_id, role)
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
    ingest_chunks(graph, all_chunks)

    print("Creating topic links...")
    create_topic_links(graph, all_chunks)

    print("Creating similarity edges (full rebuild)...")
    create_similarity_edges(graph)

    print(f"\n--- Report Migration Stats ---")
    print(f"  Reports processed: {report_count}")
    print(f"  Chunks created: {len(all_chunks)}")
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
    args = parser.parse_args()

    graph_root = args.project_root or project_root
    if graph_root:
        set_graph_name(graph_root)

    if args.reports:
        if not os.path.isdir(args.reports_dir):
            print(f"Error: Reports directory not found: {args.reports_dir}")
            sys.exit(1)
        migrate_reports(args.reports_dir)
        return

    if not os.path.isdir(args.knowledge_dir):
        print(f"Error: Knowledge directory not found: {args.knowledge_dir}")
        sys.exit(1)

    migrate(args.knowledge_dir, clean=args.clean)


if __name__ == "__main__":
    main()
