"""Migrate existing markdown knowledge files into FalkorDB GraphRAG."""

import argparse
import os
import re
import sys

from graphrag_sdk import Ontology, Source

from common import (
    get_model,
    load_ontology,
    save_ontology,
    create_kg,
    write_temp_txt,
)

ROLE_MAP = {
    "dev.md": ["dev"],
    "researcher.md": ["researcher"],
    "tester.md": ["tester"],
    "lead.md": ["lead"],
}


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
        tmp_path = write_temp_txt(text)
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


def migrate(knowledge_dir: str):
    model = get_model()
    ontology = load_ontology()
    if ontology is None:
        ontology = _generate_ontology(knowledge_dir, model)

    kg = create_kg(ontology=ontology)

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
            tmp_path = write_temp_txt(entry)
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
        save_ontology(kg.ontology)
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
