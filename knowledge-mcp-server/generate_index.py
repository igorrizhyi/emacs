"""Auto-generate a knowledge browser index from the FalkorDB knowledge graph.

Introspects Topic nodes and their relationships to produce a structured
markdown file with query blocks for the knowledge browser minor mode.

Usage:
    python generate_index.py [--project-root PATH] [--output PATH]
"""

import argparse
import os
from collections import defaultdict

from common import get_graph, init_schema, set_graph_name


# ---------------------------------------------------------------------------
# Union-Find for topic clustering
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


def fetch_topics(graph):
    """Return list of (topic_name, chunk_count) sorted by chunk_count desc."""
    result = graph.query(
        """
        MATCH (t:Topic)<-[:HAS_TOPIC]-(c:Chunk)
        OPTIONAL MATCH (sup:Chunk)-[:SUPERSEDES]->(c)
        WITH t, c WHERE sup IS NULL
        RETURN t.name AS topic, count(c) AS chunk_count
        ORDER BY chunk_count DESC
        """
    )
    return [(row[0], row[1]) for row in result.result_set]


def fetch_topic_clusters(graph):
    """Return list of (topic_a, topic_b, link_strength) for related topics."""
    result = graph.query(
        """
        MATCH (t1:Topic)<-[:HAS_TOPIC]-(c1:Chunk)-[:RELATED_TO]-(c2:Chunk)-[:HAS_TOPIC]->(t2:Topic)
        WHERE t1.name < t2.name
        OPTIONAL MATCH (sup1:Chunk)-[:SUPERSEDES]->(c1)
        OPTIONAL MATCH (sup2:Chunk)-[:SUPERSEDES]->(c2)
        WITH t1, t2 WHERE sup1 IS NULL AND sup2 IS NULL
        RETURN t1.name AS topic_a, t2.name AS topic_b, count(*) AS link_strength
        ORDER BY link_strength DESC
        LIMIT 50
        """
    )
    return [(row[0], row[1], row[2]) for row in result.result_set]


# ---------------------------------------------------------------------------
# Grouping
# ---------------------------------------------------------------------------


def group_topics(topics, clusters, min_chunks=2):
    """Group topics into sections using connected components.

    Args:
        topics: list of (topic_name, chunk_count)
        clusters: list of (topic_a, topic_b, link_strength)
        min_chunks: minimum chunk count to include a topic

    Returns:
        list of (section_heading, [topic_names]) — each group sorted by chunk count
    """
    # Filter low-signal topics
    topic_chunks = {name: count for name, count in topics if count >= min_chunks}
    if not topic_chunks:
        return []

    # Build connected components from cluster edges
    uf = UnionFind()
    for t in topic_chunks:
        uf.find(t)  # ensure all topics are registered

    for ta, tb, _strength in clusters:
        if ta in topic_chunks and tb in topic_chunks:
            uf.union(ta, tb)

    # Collect groups by root
    groups = defaultdict(list)
    for topic in topic_chunks:
        root = uf.find(topic)
        groups[root].append(topic)

    # For each group, sort by chunk count desc and pick the top topic as heading
    result = []
    for _root, members in groups.items():
        members.sort(key=lambda t: topic_chunks[t], reverse=True)
        heading = members[0]
        result.append((heading, members))

    # Sort groups: largest groups first, then by heading chunk count
    result.sort(key=lambda g: (len(g[1]), topic_chunks[g[0]]), reverse=True)
    return result


# ---------------------------------------------------------------------------
# Markdown generation
# ---------------------------------------------------------------------------


def _build_query(topics):
    """Build a query string covering the given topics."""
    if len(topics) == 1:
        return topics[0]
    # Combine related topics into a natural query
    return ", ".join(topics)


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
        help="Minimum chunk count to include a topic (default: 2)",
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

    print(f"Graph: connected. Fetching topics...")
    topics = fetch_topics(graph)
    print(f"  Found {len(topics)} topics")

    clusters = fetch_topic_clusters(graph)
    print(f"  Found {len(clusters)} topic cluster edges")

    groups = group_topics(topics, clusters, min_chunks=args.min_chunks)
    print(f"  Grouped into {len(groups)} sections")

    if not groups:
        print("No topics with sufficient chunks found. Skipping index generation.")
        return

    content = generate_markdown(groups)

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w") as f:
        f.write(content)

    print(f"Index written to {output_path}")
    total_topics = sum(len(m) for _, m in groups)
    print(f"  {len(groups)} sections covering {total_topics} topics")


if __name__ == "__main__":
    main()
