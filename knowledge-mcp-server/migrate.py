"""Migrate existing markdown knowledge files into FalkorDB GraphRAG."""

import argparse
import json
import os
import sys
import tempfile

import falkordb
from graphrag_sdk import KnowledgeGraph, KnowledgeGraphModelConfig, Ontology, Source
from graphrag_sdk.models.litellm import LiteModel

GRAPH_NAME = "team_knowledge"
MODEL_NAME = os.environ.get("GRAPHRAG_MODEL", "gpt-4o")
FALKORDB_HOST = os.environ.get("FALKORDB_HOST", "127.0.0.1")
FALKORDB_PORT = int(os.environ.get("FALKORDB_PORT", "6380"))

ROLE_MAP = {
    "dev.md": ["dev"],
    "researcher.md": ["researcher"],
    "tester.md": ["tester"],
    "lead.md": ["lead"],
}

ONTOLOGY_PATH = os.path.join(os.path.dirname(__file__), "ontology.json")


def _save_ontology(ontology):
    with open(ONTOLOGY_PATH, "w") as f:
        json.dump(ontology.to_json(), f, indent=2)


def _load_ontology():
    if os.path.exists(ONTOLOGY_PATH):
        with open(ONTOLOGY_PATH) as f:
            return Ontology.from_json(json.load(f))
    return None


def _write_temp_txt(content: str) -> str:
    fd, path = tempfile.mkstemp(suffix=".txt")
    with os.fdopen(fd, "w") as f:
        f.write(content)
    return path


def _generate_ontology(knowledge_dir: str, model):
    """Auto-generate ontology from all knowledge source files."""
    print("Generating ontology from knowledge files...")
    sources = []
    tmp_paths = []

    for filename in ROLE_MAP:
        filepath = os.path.join(knowledge_dir, filename)
        if not os.path.exists(filepath):
            continue
        with open(filepath) as f:
            text = f.read()
        tmp_path = _write_temp_txt(text)
        tmp_paths.append(tmp_path)
        sources.append(Source(tmp_path))

    if not sources:
        raise RuntimeError("No knowledge files found to generate ontology from.")

    try:
        ontology = Ontology.from_sources(
            sources,
            model,
            boundaries=(
                "Focus on software engineering team knowledge: patterns, "
                "conventions, bugs, architecture decisions, roles, and topics"
            ),
        )
    finally:
        for p in tmp_paths:
            os.unlink(p)

    print(f"Ontology generated: {len(ontology.entities)} entities, "
          f"{len(ontology.relations)} relations.")
    return ontology


def _clean_graph():
    """Delete the existing FalkorDB graph and ontology file."""
    print(f"Cleaning existing graph '{GRAPH_NAME}'...")
    try:
        db = falkordb.FalkorDB(host=FALKORDB_HOST, port=FALKORDB_PORT)
        graph = db.select_graph(GRAPH_NAME)
        graph.delete()
        print("  Graph deleted.")
    except Exception as e:
        print(f"  Could not delete graph (may not exist): {e}")

    if os.path.exists(ONTOLOGY_PATH):
        os.unlink(ONTOLOGY_PATH)
        print("  Ontology file removed.")


def migrate(knowledge_dir: str, clean: bool = False):
    if clean:
        _clean_graph()

    model = LiteModel(model_name=MODEL_NAME)
    model_config = KnowledgeGraphModelConfig.with_model(model)

    ontology = _load_ontology()
    if ontology is None:
        ontology = _generate_ontology(knowledge_dir, model)

    kg = KnowledgeGraph(
        name=GRAPH_NAME,
        model_config=model_config,
        ontology=ontology,
        host=FALKORDB_HOST,
        port=FALKORDB_PORT,
    )

    total_files = 0

    for filename, roles in ROLE_MAP.items():
        filepath = os.path.join(knowledge_dir, filename)
        if not os.path.exists(filepath):
            print(f"Skipping {filename} (not found)")
            continue

        with open(filepath) as f:
            content = f.read()
        if not content.strip():
            print(f"Skipping {filename} (empty)")
            continue

        role_str = ", ".join(roles)
        enriched = f"Role: {role_str}\nSource: {filename}\n---\n{content}"

        tmp_path = _write_temp_txt(enriched)
        try:
            src = Source(tmp_path)
            print(f"Processing {filename}...")
            kg.process_sources([src], hide_progress=False)
            print(f"  Done.")
            total_files += 1
        except Exception as e:
            print(f"  Error processing {filename}: {e}")
        finally:
            os.unlink(tmp_path)

    if kg.ontology is not None:
        _save_ontology(kg.ontology)
        print("Ontology saved.")

    print(f"\nMigration complete. Processed {total_files} files.")


def main():
    default_knowledge_dir = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", ".agent-shell", "knowledge")
    )

    parser = argparse.ArgumentParser(
        description="Migrate markdown knowledge files into FalkorDB GraphRAG"
    )
    parser.add_argument(
        "--knowledge-dir",
        default=default_knowledge_dir,
        help=f"Path to knowledge directory (default: {default_knowledge_dir})",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Delete existing graph and ontology before migrating",
    )
    args = parser.parse_args()

    if not os.path.isdir(args.knowledge_dir):
        print(f"Error: Knowledge directory not found: {args.knowledge_dir}")
        sys.exit(1)

    migrate(args.knowledge_dir, clean=args.clean)


if __name__ == "__main__":
    main()
