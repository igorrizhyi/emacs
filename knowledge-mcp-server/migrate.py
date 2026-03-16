"""Migrate existing markdown knowledge files into FalkorDB GraphRAG."""

import argparse
import os
import re
import sys
import tempfile

from graphrag_sdk import KnowledgeGraph, KnowledgeGraphModelConfig, Source
from graphrag_sdk.models.litellm import LiteModel

GRAPH_NAME = "team_knowledge"
MODEL_NAME = os.environ.get("GRAPHRAG_MODEL", "gpt-4o-mini")
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
    import json

    with open(ONTOLOGY_PATH, "w") as f:
        json.dump(ontology.to_json(), f, indent=2)


def _write_temp_txt(content: str) -> str:
    fd, path = tempfile.mkstemp(suffix=".txt")
    with os.fdopen(fd, "w") as f:
        f.write(content)
    return path


def parse_sections(text: str) -> list[tuple[str, str]]:
    """Split markdown into (section_title, section_content) pairs by ## headings."""
    parts = re.split(r"^## ", text, flags=re.MULTILINE)
    sections = []
    for part in parts[1:]:  # skip everything before first ##
        lines = part.split("\n", 1)
        title = lines[0].strip()
        content = lines[1].strip() if len(lines) > 1 else ""
        if title and content:
            sections.append((title, content))
    return sections


def build_entry(role: str, section_title: str, section_content: str) -> str:
    return (
        f"Knowledge Entry\n"
        f"Roles: {role}\n"
        f"Source: migration\n"
        f"Section: {section_title}\n"
        f"---\n"
        f"{section_content}"
    )


def migrate(knowledge_dir: str):
    model = LiteModel(model_name=MODEL_NAME)
    model_config = KnowledgeGraphModelConfig.with_model(model)
    kg = KnowledgeGraph(
        name=GRAPH_NAME,
        model_config=model_config,
        host=FALKORDB_HOST,
        port=FALKORDB_PORT,
    )

    total_sections = 0
    total_files = 0

    for filename, roles in ROLE_MAP.items():
        filepath = os.path.join(knowledge_dir, filename)
        if not os.path.exists(filepath):
            print(f"Warning: {filepath} not found, skipping.")
            continue

        with open(filepath) as f:
            text = f.read()

        sections = parse_sections(text)
        if not sections:
            print(f"Warning: {filename} has no sections, skipping.")
            continue

        total_files += 1
        role_str = ", ".join(roles)
        print(f"Migrating {filename}...")

        for i, (title, content) in enumerate(sections, 1):
            entry = build_entry(role_str, title, content)
            tmp_path = _write_temp_txt(entry)
            try:
                src = Source(tmp_path)
                kg.process_sources(
                    [src],
                    instructions=(
                        "Extract knowledge entries with their metadata "
                        "(roles, source, timestamp). Preserve role tags as "
                        "attributes on entities."
                    ),
                    hide_progress=True,
                )
                print(f"  [{i}/{len(sections)}] {title} \u2713")
                total_sections += 1
            except Exception as e:
                print(f"  [{i}/{len(sections)}] {title} \u2717 Error: {e}")
            finally:
                os.unlink(tmp_path)

    # Save ontology after all ingestion
    if kg.ontology is not None:
        _save_ontology(kg.ontology)
        print("Ontology saved.")

    print(f"\nDone. Migrated {total_sections} sections from {total_files} files.")


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
    args = parser.parse_args()

    if not os.path.isdir(args.knowledge_dir):
        print(f"Error: Knowledge directory not found: {args.knowledge_dir}")
        sys.exit(1)

    migrate(args.knowledge_dir)


if __name__ == "__main__":
    main()
