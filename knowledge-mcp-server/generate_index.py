"""Auto-generate a knowledge browser index from the FalkorDB knowledge graph.

Introspects Chunk sections and their relationships to produce a structured
markdown file with query blocks for the knowledge browser minor mode.

Usage:
    python generate_index.py [--project-root PATH] [--output PATH]
"""

import argparse
import os
from collections import defaultdict

from common import get_graph, init_schema, set_graph_name


# ---------------------------------------------------------------------------
# Union-Find for section clustering
# ---------------------------------------------------------------------------


class UnionFind:
    """Simple union-find / disjoint-set data structure."""

    def __init__(self):
        self.parent = {}
        self.rank = {}

    def find(self, x):
        if x not in self.parent:
            self.parent[x] = x
            self.rank[x] = 0
        if self.parent[x] != x:
            self.parent[x] = self.find(self.parent[x])
        return self.parent[x]

    def union(self, x, y):
        rx, ry = self.find(x), self.find(y)
        if rx == ry:
            return
        if self.rank[rx] < self.rank[ry]:
            rx, ry = ry, rx
        self.parent[ry] = rx
        if self.rank[rx] == self.rank[ry]:
            self.rank[rx] += 1


# ---------------------------------------------------------------------------
# Graph introspection
# ---------------------------------------------------------------------------


def fetch_sections(graph):
    """Return list of (section_name, chunk_count) sorted by chunk_count desc."""
    result = graph.query(
        """
        MATCH (c:Chunk)
        WHERE c.section IS NOT NULL AND c.section <> ''
        OPTIONAL MATCH (sup:Chunk)-[:SUPERSEDES]->(c)
        WITH c WHERE sup IS NULL
        RETURN c.section AS section, count(c) AS chunk_count
        ORDER BY chunk_count DESC
        """
    )
    return [(row[0], row[1]) for row in result.result_set]


def fetch_section_clusters(graph):
    """Return list of (section_a, section_b, link_strength) for related sections."""
    result = graph.query(
        """
        MATCH (c1:Chunk)-[:RELATED_TO]-(c2:Chunk)
        WHERE c1.section IS NOT NULL AND c1.section <> ''
          AND c2.section IS NOT NULL AND c2.section <> ''
          AND c1.section < c2.section
        OPTIONAL MATCH (sup1:Chunk)-[:SUPERSEDES]->(c1)
        OPTIONAL MATCH (sup2:Chunk)-[:SUPERSEDES]->(c2)
        WITH c1, c2 WHERE sup1 IS NULL AND sup2 IS NULL
        RETURN c1.section AS section_a, c2.section AS section_b, count(*) AS link_strength
        ORDER BY link_strength DESC
        LIMIT 50
        """
    )
    return [(row[0], row[1], row[2]) for row in result.result_set]


# ---------------------------------------------------------------------------
# Grouping
# ---------------------------------------------------------------------------


def group_sections(sections, clusters, min_chunks=2):
    """Group sections into browsable groups using connected components.

    Args:
        sections: list of (section_name, chunk_count)
        clusters: list of (section_a, section_b, link_strength)
        min_chunks: minimum chunk count to include a section

    Returns:
        list of (section_heading, [section_names]) — each group sorted by chunk count
    """
    # Filter low-signal sections
    section_chunks = {name: count for name, count in sections if count >= min_chunks}
    if not section_chunks:
        return []

    # Build connected components from cluster edges
    uf = UnionFind()
    for s in section_chunks:
        uf.find(s)  # ensure all sections are registered

    for sa, sb, _strength in clusters:
        if sa in section_chunks and sb in section_chunks:
            uf.union(sa, sb)

    # Collect groups by root
    groups = defaultdict(list)
    for section in section_chunks:
        root = uf.find(section)
        groups[root].append(section)

    # For each group, sort by chunk count desc and pick the top section as heading
    result = []
    for _root, members in groups.items():
        members.sort(key=lambda s: section_chunks[s], reverse=True)
        heading = members[0]
        result.append((heading, members))

    # Sort groups: largest groups first, then by heading chunk count
    result.sort(key=lambda g: (len(g[1]), section_chunks[g[0]]), reverse=True)
    return result


# ---------------------------------------------------------------------------
# Markdown generation
# ---------------------------------------------------------------------------


def _build_query(sections):
    """Build a query string covering the given sections."""
    if len(sections) == 1:
        return sections[0]
    # Combine related sections into a natural query
    return ", ".join(sections)


def generate_markdown(groups):
    """Generate the markdown index content."""
    lines = [
        "# Knowledge Browser",
        "",
        "Navigate to a section and press `RET` to fetch knowledge from the database.",
        "`C-c C-r` to refresh all sections. `C-c C-k` to clear a section.",
        "",
    ]

    for heading, members in groups:
        lines.append(f"## {heading}")
        lines.append(f"<!-- query: {_build_query(members)} -->")
        lines.append("<!-- mode: technical -->")
        lines.append("<!-- BEGIN GENERATED -->")
        lines.append("<!-- END GENERATED -->")
        lines.append("")

    # File-local variable for auto-enabling the minor mode
    lines.append(";; -*- eval: (my/knowledge-browser-mode 1) -*-")
    lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Generate knowledge browser index from FalkorDB graph"
    )
    parser.add_argument(
        "--project-root",
        default=os.environ.get("PROJECT_ROOT", ""),
        help="Project root for graph name derivation (default: PROJECT_ROOT env var)",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Output file path (default: {project-root}/.agent-shell/knowledge/index.md)",
    )
    parser.add_argument(
        "--min-chunks",
        type=int,
        default=2,
        help="Minimum chunk count to include a section (default: 2)",
    )
    args = parser.parse_args()

    project_root = args.project_root
    if project_root:
        set_graph_name(project_root)

    output_path = args.output
    if not output_path:
        if not project_root:
            parser.error("--output is required when PROJECT_ROOT is not set")
        output_path = os.path.join(
            project_root, ".agent-shell", "knowledge", "index.md"
        )

    graph = get_graph()
    init_schema(graph)

    print(f"Graph: connected. Fetching sections...")
    sections = fetch_sections(graph)
    print(f"  Found {len(sections)} sections")

    clusters = fetch_section_clusters(graph)
    print(f"  Found {len(clusters)} section cluster edges")

    groups = group_sections(sections, clusters, min_chunks=args.min_chunks)
    print(f"  Grouped into {len(groups)} groups")

    if not groups:
        print("No sections with sufficient chunks found. Skipping index generation.")
        return

    content = generate_markdown(groups)

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w") as f:
        f.write(content)

    print(f"Index written to {output_path}")
    total_sections = sum(len(m) for _, m in groups)
    print(f"  {len(groups)} groups covering {total_sections} sections")


if __name__ == "__main__":
    main()
