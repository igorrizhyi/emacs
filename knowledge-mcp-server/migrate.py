"""Migrate existing markdown knowledge files into FalkorDB hybrid vector+graph store."""

import argparse
import os
import sys

from common import (
    GRAPH_NAME,
    get_graph,
    init_schema,
    chunk_knowledge_file,
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
        graph.delete()
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


def main():
    default_knowledge_dir = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", ".agent-shell", "knowledge")
    )

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
    args = parser.parse_args()

    if not os.path.isdir(args.knowledge_dir):
        print(f"Error: Knowledge directory not found: {args.knowledge_dir}")
        sys.exit(1)

    migrate(args.knowledge_dir, clean=args.clean)


if __name__ == "__main__":
    main()
