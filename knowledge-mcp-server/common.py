"""Shared constants, schema helpers, and ingestion pipeline for hybrid vector+graph knowledge system."""

import hashlib
import json
import logging
import os
import re
from datetime import datetime, timezone

from falkordb import FalkorDB
from litellm import completion, embedding

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

PROJECT_ROOT = os.environ.get("PROJECT_ROOT", "")


def _resolve_namespace() -> str | None:
    """Resolve namespace: NAMESPACE env var > .agent-shell/namespace.json > None."""
    ns = os.environ.get("NAMESPACE")
    if ns:
        return ns
    if PROJECT_ROOT:
        ns_file = os.path.join(PROJECT_ROOT, ".agent-shell", "namespace.json")
        try:
            with open(ns_file) as f:
                data = json.load(f)
            return data.get("namespace") or None
        except (FileNotFoundError, json.JSONDecodeError, KeyError):
            pass
    return None


def _resolve_project() -> str:
    """Derive project name from PROJECT_ROOT (basename of the path)."""
    if not PROJECT_ROOT:
        return "default"
    return os.path.basename(PROJECT_ROOT.rstrip("/")) or "default"


def _derive_graph_name(project_root: str, namespace: str = None) -> str:
    """Derive a FalkorDB graph name.

    If *namespace* is set, all projects in the namespace share one graph:
    ``knowledge_{namespace}``.  Otherwise, fall back to per-project naming.
    """
    if namespace:
        safe_ns = re.sub(r'[^a-zA-Z0-9]', '_', namespace).strip('_').lower()
        return f"knowledge_{safe_ns}"
    if not project_root:
        return "team_knowledge"  # backward compat fallback
    basename = os.path.basename(project_root.rstrip("/")) or "default"
    safe_base = re.sub(r'[^a-zA-Z0-9]', '_', basename).strip('_').lower()
    short_hash = hashlib.sha256(project_root.encode()).hexdigest()[:6]
    return f"knowledge_{safe_base}_{short_hash}"


NAMESPACE = _resolve_namespace()
GRAPH_NAME = _derive_graph_name(PROJECT_ROOT, NAMESPACE)


def set_graph_name(project_root: str, namespace: str = None):
    """Recalculate and set the module-level GRAPH_NAME from a project root path."""
    global GRAPH_NAME, PROJECT_ROOT, NAMESPACE
    PROJECT_ROOT = project_root
    NAMESPACE = namespace or _resolve_namespace()
    GRAPH_NAME = _derive_graph_name(project_root, NAMESPACE)

FALKORDB_HOST = os.environ.get("FALKORDB_HOST", "127.0.0.1")
FALKORDB_PORT = int(os.environ.get("FALKORDB_PORT", "6380"))
EMBED_MODEL = "text-embedding-3-small"
EMBED_DIM = 1536
LLM_MODEL = os.environ.get("GRAPHRAG_MODEL", "gpt-4o")
BATCH_SIZE = 100

# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------


def get_graph():
    """Return a FalkorDB Graph handle for GRAPH_NAME."""
    db = FalkorDB(host=FALKORDB_HOST, port=FALKORDB_PORT)
    return db.select_graph(GRAPH_NAME)


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------


def init_schema(graph):
    """Create indexes, constraints, and seed Role nodes."""
    # Unique constraints (FalkorDB doesn't support IF NOT EXISTS for constraints)
    for stmt in (
        "CREATE CONSTRAINT FOR (c:Chunk) REQUIRE c.id IS UNIQUE",
        "CREATE CONSTRAINT FOR (t:Topic) REQUIRE t.name IS UNIQUE",
        "CREATE CONSTRAINT FOR (r:Role) REQUIRE r.name IS UNIQUE",
    ):
        try:
            graph.query(stmt)
        except Exception:
            pass  # already exists

    # Vector index on Chunk.embedding
    try:
        graph.create_node_vector_index("Chunk", "embedding", dim=EMBED_DIM, similarity_function="cosine")
    except Exception:
        pass  # already exists

    # Full-text index on Chunk.content
    try:
        graph.create_node_fulltext_index("Chunk", "content")
    except Exception:
        pass  # already exists

    # Range indexes
    for stmt in (
        "CREATE INDEX FOR (c:Chunk) ON (c.source)",
        "CREATE INDEX FOR (c:Chunk) ON (c.roles)",
        "CREATE INDEX FOR (c:Chunk) ON (c.type)",
        "CREATE INDEX FOR (c:Chunk) ON (c.project)",
    ):
        try:
            graph.query(stmt)
        except Exception:
            pass  # already exists

    # Seed roles
    for role in ("dev", "researcher", "tester", "lead"):
        graph.query("MERGE (:Role {name: $name})", params={"name": role})


# ---------------------------------------------------------------------------
# Embedding helpers
# ---------------------------------------------------------------------------


def embed_texts(texts: list[str]) -> list[list[float]]:
    """Embed a list of texts via litellm (OpenAI-compatible)."""
    if not texts:
        return []
    vectors = []
    for i in range(0, len(texts), BATCH_SIZE):
        batch = texts[i : i + BATCH_SIZE]
        resp = embedding(model=EMBED_MODEL, input=batch)
        vectors.extend([item["embedding"] for item in resp.data])
    return vectors


def chunk_id(source: str, content: str) -> str:
    """Deterministic SHA-256 chunk ID (first 16 hex chars)."""
    return hashlib.sha256(f"{source}:{content}".encode()).hexdigest()[:16]


# ---------------------------------------------------------------------------
# Chunking
# ---------------------------------------------------------------------------


def chunk_report(report_text: str, request_id: str, role: str, project: str = None) -> list[dict]:
    """Split a task report into per-section chunks."""
    source = f"report:{request_id}"
    chunks = []
    current_section = "Summary"
    current_lines = []

    for line in report_text.split("\n"):
        if line.startswith("## "):
            # Flush previous section
            if current_lines:
                content = "\n".join(current_lines).strip()
                if content and len(content) > 20:  # Skip trivially short sections
                    chunks.append({
                        "id": chunk_id(source, content),
                        "content": content,
                        "source": source,
                        "section": current_section,
                        "roles": role,
                        "type": "report",
                        "project": project,
                    })
            current_section = line[3:].strip()
            current_lines = []
        elif line.startswith("# "):
            current_section = line[2:].strip()
        else:
            current_lines.append(line)

    # Flush last section
    if current_lines:
        content = "\n".join(current_lines).strip()
        if content and len(content) > 20:
            chunks.append({
                "id": chunk_id(source, content),
                "content": content,
                "source": source,
                "section": current_section,
                "roles": role,
                "type": "report",
                "project": project,
            })
    return chunks


def chunk_knowledge_file(filepath: str, role: str, project: str = None) -> list[dict]:
    """Parse a markdown knowledge file into per-bullet chunks.

    Tracks ``## `` headers as current_section. Each top-level ``- `` bullet
    starts a new chunk; continuation lines (indented, not starting with ``- ``)
    are joined with a space.
    """
    with open(filepath) as f:
        lines = f.readlines()

    source = os.path.basename(filepath)
    current_section = ""
    chunks: list[dict] = []
    current_bullet: list[str] = []

    def _flush():
        if current_bullet:
            content = " ".join(current_bullet)
            chunks.append(
                {
                    "id": chunk_id(source, content),
                    "content": content,
                    "source": source,
                    "section": current_section,
                    "roles": role,
                    "type": "knowledge",
                    "project": project,
                }
            )
            current_bullet.clear()

    for raw_line in lines:
        line = raw_line.rstrip("\n")

        # Section header
        if line.startswith("## "):
            _flush()
            current_section = line[3:].strip()
            continue

        # Top-level bullet
        if line.startswith("- "):
            _flush()
            current_bullet.append(line[2:].strip())
            continue

        # Continuation line (indented or non-bullet non-empty)
        stripped = line.strip()
        if stripped and current_bullet:
            current_bullet.append(stripped)
            continue

        # Blank line — flush current bullet
        if not stripped:
            _flush()

    _flush()
    return chunks


# ---------------------------------------------------------------------------
# Ingestion
# ---------------------------------------------------------------------------


def ingest_chunks(graph, chunks: list[dict], project: str = None):
    """Embed chunks and MERGE them into the graph with FOR_ROLE edges."""
    if not chunks:
        return

    texts = [c["content"] for c in chunks]
    vectors = embed_texts(texts)
    now = datetime.now(timezone.utc).isoformat()

    for chunk, vec in zip(chunks, vectors):
        # Use per-chunk project if set, otherwise fall back to function param
        proj = chunk.get("project") or project
        params = {
            "id": chunk["id"],
            "content": chunk["content"],
            "vec": vec,
            "source": chunk["source"],
            "section": chunk["section"],
            "roles": chunk["roles"],
            "type": chunk.get("type", "knowledge"),
            "ts": now,
        }
        if proj is not None:
            graph.query(
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
                params={**params, "project": proj},
            )
        else:
            graph.query(
                """
                MERGE (c:Chunk {id: $id})
                SET c.content    = $content,
                    c.embedding  = vecf32($vec),
                    c.source     = $source,
                    c.section    = $section,
                    c.roles      = $roles,
                    c.type       = $type,
                    c.created_at = $ts
                """,
                params=params,
            )

        # FOR_ROLE edges (one per role token)
        for role in chunk["roles"].split(","):
            role = role.strip()
            if role:
                graph.query(
                    """
                    MATCH (c:Chunk {id: $id})
                    MERGE (r:Role {name: $role})
                    MERGE (c)-[:FOR_ROLE]->(r)
                    """,
                    params={"id": chunk["id"], "role": role},
                )


# ---------------------------------------------------------------------------
# Topic linking
# ---------------------------------------------------------------------------


def create_topic_links(graph, chunks: list[dict]):
    """Create Topic nodes from section names and link chunks via HAS_TOPIC."""
    for chunk in chunks:
        section = chunk.get("section", "").strip()
        if not section:
            continue
        graph.query(
            """
            MATCH (c:Chunk {id: $id})
            MERGE (t:Topic {name: $topic})
            MERGE (c)-[:HAS_TOPIC]->(t)
            """,
            params={"id": chunk["id"], "topic": section},
        )


# ---------------------------------------------------------------------------
# Similarity edges
# ---------------------------------------------------------------------------


def create_similarity_edges(graph, threshold: float = 0.25, cross_role_threshold: float = 0.40):
    """Create RELATED_TO edges in two passes:

    1. **Threshold pass** — link chunk pairs whose cosine distance <= *threshold*.
    2. **Cross-role pass** — link dev↔researcher chunks with a relaxed threshold
       (*cross_role_threshold*). No forced links — if nothing is close enough, skip.

    FalkorDB vector search returns *distance* (lower = more similar for cosine).
    """
    result = graph.query("MATCH (c:Chunk) RETURN c.id AS id, c.roles AS roles")
    all_chunks = [(row[0], row[1]) for row in result.result_set]

    # --- Pass 1: threshold-based similarity edges ---
    for cid, _ in all_chunks:
        res = graph.query(
            "MATCH (c:Chunk {id: $id}) RETURN c.embedding AS vec",
            params={"id": cid},
        )
        if not res.result_set or res.result_set[0][0] is None:
            continue
        vec = res.result_set[0][0]

        neighbours = graph.query(
            """
            CALL db.idx.vector.queryNodes('Chunk', 'embedding', $k, vecf32($vec))
            YIELD node, score
            RETURN node.id AS nid, score
            """,
            params={"k": 10, "vec": list(vec)},
        )

        for row in neighbours.result_set:
            nid, score = row[0], row[1]
            if nid == cid or score > threshold:
                continue
            graph.query(
                """
                MATCH (a:Chunk {id: $a}), (b:Chunk {id: $b})
                MERGE (a)-[r:RELATED_TO]->(b)
                SET r.score = $score
                """,
                params={"a": cid, "b": nid, "score": score},
            )

    # --- Pass 2: cross-role edges (dev ↔ researcher) with relaxed threshold ---
    cross_role_pairs = [("dev", "researcher"), ("researcher", "dev")]
    for src_role, dst_role in cross_role_pairs:
        src_ids = [cid for cid, roles in all_chunks if roles == src_role]
        for cid in src_ids:
            # Skip if already linked to dst_role from pass 1
            has = graph.query(
                'MATCH (c:Chunk {id: $id})-[:RELATED_TO]-(r:Chunk) WHERE r.roles = $role RETURN count(r)',
                params={"id": cid, "role": dst_role},
            ).result_set[0][0]
            if has > 0:
                continue

            # Find nearest dst_role chunk within relaxed threshold
            res = graph.query(
                """
                MATCH (c:Chunk {id: $id})
                CALL db.idx.vector.queryNodes('Chunk', 'embedding', 20, c.embedding)
                YIELD node, score
                WHERE node.roles = $role AND score <= $max_dist
                RETURN node.id, score
                ORDER BY score ASC
                LIMIT 1
                """,
                params={"id": cid, "role": dst_role, "max_dist": cross_role_threshold},
            )
            if res.result_set:
                nid, score = res.result_set[0]
                graph.query(
                    """
                    MATCH (a:Chunk {id: $a}), (b:Chunk {id: $b})
                    MERGE (a)-[r:RELATED_TO]->(b)
                    SET r.score = $score
                    """,
                    params={"a": cid, "b": nid, "score": score},
                )


def create_cross_role_edges(graph, chunk_ids: list[str], threshold: float = 0.40):
    """Create RELATED_TO edges between dev↔researcher chunks (incremental).

    For each new chunk, if it has role 'dev', search for similar 'researcher'
    chunks (and vice versa) within *threshold* cosine distance. This surfaces
    cross-role connections that the tighter same-role similarity pass may miss.
    """
    cross_role_map = {"dev": "researcher", "researcher": "dev"}

    for cid in chunk_ids:
        res = graph.query(
            "MATCH (c:Chunk {id: $id}) RETURN c.embedding, c.roles",
            params={"id": cid},
        )
        if not res.result_set or not res.result_set[0][0]:
            continue
        vec, roles_str = res.result_set[0]
        roles = {r.strip() for r in (roles_str or "").split(",") if r.strip()}

        # Determine which opposite roles to search for
        target_roles = {cross_role_map[r] for r in roles if r in cross_role_map}
        if not target_roles:
            continue

        for target_role in target_roles:
            neighbours = graph.query(
                """
                CALL db.idx.vector.queryNodes('Chunk', 'embedding', 20, vecf32($vec))
                YIELD node, score
                OPTIONAL MATCH (sup)-[:SUPERSEDES]->(node)
                WITH node, score
                WHERE sup IS NULL
                  AND node.id <> $id
                  AND score <= $threshold
                RETURN node.id, node.roles, score
                """,
                params={"vec": list(vec), "id": cid, "threshold": threshold},
            )
            for row in neighbours.result_set:
                nid, n_roles_str, score = row
                n_roles = {r.strip() for r in (n_roles_str or "").split(",") if r.strip()}
                if target_role not in n_roles:
                    continue
                graph.query(
                    "MATCH (a:Chunk {id: $a}), (b:Chunk {id: $b}) "
                    "MERGE (a)-[r:RELATED_TO]->(b) SET r.score = $score",
                    params={"a": cid, "b": nid, "score": score},
                )


def create_similarity_edges_for_chunks(graph, chunk_ids: list[str], threshold: float = 0.25):
    """Create RELATED_TO edges only for the given chunks (incremental)."""
    for cid in chunk_ids:
        res = graph.query(
            "MATCH (c:Chunk {id: $id}) RETURN c.embedding",
            params={"id": cid},
        )
        if not res.result_set or not res.result_set[0][0]:
            continue
        vec = res.result_set[0][0]

        neighbours = graph.query(
            """
            CALL db.idx.vector.queryNodes('Chunk', 'embedding', 10, vecf32($vec))
            YIELD node, score
            WHERE node.id <> $id AND score <= $threshold
            RETURN node.id, score
            """,
            params={"vec": list(vec), "id": cid, "threshold": threshold},
        )
        for row in neighbours.result_set:
            graph.query(
                "MATCH (a:Chunk {id: $a}), (b:Chunk {id: $b}) MERGE (a)-[r:RELATED_TO]->(b) SET r.score = $score",
                params={"a": cid, "b": row[0], "score": row[1]},
            )


# ---------------------------------------------------------------------------
# Supersession detection
# ---------------------------------------------------------------------------

SUPERSESSION_CANDIDATE_THRESHOLD = 0.25  # cosine distance — tuned for text-embedding-3-small

CLASSIFICATION_MODEL = os.environ.get("GRAPHRAG_CLASSIFY_MODEL", "gpt-4o-mini")

_CLASSIFY_PROMPT = """\
You are comparing two knowledge chunks. Classify the relationship.

EXISTING chunk:
{existing}

NEW chunk:
{new}

Classify as exactly one of:
- SUPERSEDES — the new chunk updates/replaces the existing one (same topic, newer info)
- CONTRADICTS — they make conflicting claims on the same topic
- DUPLICATE — they say essentially the same thing
- DIFFERENT — they cover different topics despite textual similarity

Respond with JSON only: {{"type": "<TYPE>", "reason": "<brief reason>"}}"""


def _roles_overlap(roles_a: str, roles_b: str) -> bool:
    """Check if two comma-separated role strings have any overlap."""
    set_a = {r.strip() for r in roles_a.split(",") if r.strip()}
    set_b = {r.strip() for r in roles_b.split(",") if r.strip()}
    return bool(set_a & set_b)


def detect_supersession(graph, new_chunks: list[dict]) -> list[tuple[str, str, dict]]:
    """Find existing chunks that new chunks might supersede.

    For each new chunk:
    1. Find very similar existing chunks (cosine distance < threshold)
    2. Skip chunks with non-overlapping roles (different audience = both valid)
    3. Same-source fast path: auto-classify as SUPERSEDES without LLM
    4. Cross-source: ask LLM to classify

    Returns list of (new_id, old_id, classification_dict) tuples.
    """
    results = []
    logger.debug("detect_supersession: checking %d new chunks (threshold=%.2f)", len(new_chunks), SUPERSESSION_CANDIDATE_THRESHOLD)

    for chunk in new_chunks:
        cid = chunk["id"]
        # Fetch the embedding we just stored
        res = graph.query(
            "MATCH (c:Chunk {id: $id}) RETURN c.embedding",
            params={"id": cid},
        )
        if not res.result_set or not res.result_set[0][0]:
            continue
        vec = res.result_set[0][0]

        # Find very close neighbors
        neighbours = graph.query(
            """
            CALL db.idx.vector.queryNodes('Chunk', 'embedding', 5, vecf32($vec))
            YIELD node, score
            WHERE node.id <> $id AND score <= $threshold
            RETURN node.id, node.content, node.source, node.roles, score
            """,
            params={
                "vec": list(vec),
                "id": cid,
                "threshold": SUPERSESSION_CANDIDATE_THRESHOLD,
            },
        )

        logger.debug("  chunk %s: %d neighbors within threshold", cid, len(neighbours.result_set))

        for row in neighbours.result_set:
            old_id, old_content, old_source, old_roles, score = row

            # Skip if roles don't overlap — different audience means both valid
            if old_roles and chunk.get("roles") and not _roles_overlap(chunk["roles"], old_roles):
                continue

            # Same-source fast path: auto-classify as SUPERSEDES
            if chunk.get("source") == old_source:
                results.append((cid, old_id, {
                    "type": "SUPERSEDES",
                    "reason": f"Same source ({old_source}), distance={score:.3f}",
                }))
                continue

            # Cross-source: ask LLM to classify
            try:
                prompt = _CLASSIFY_PROMPT.format(
                    existing=old_content[:500],
                    new=chunk["content"][:500],
                )
                llm_resp = completion(
                    model=CLASSIFICATION_MODEL,
                    messages=[{"role": "user", "content": prompt}],
                    response_format={"type": "json_object"},
                )
                raw = llm_resp.choices[0].message.content.strip()
                classification = json.loads(raw)
                # Only keep actionable classifications
                if classification.get("type") in ("SUPERSEDES", "CONTRADICTS", "DUPLICATE"):
                    results.append((cid, old_id, classification))
            except Exception:
                # LLM failure is non-fatal — skip this candidate
                continue

    logger.info("detect_supersession: checked %d chunks, found %d candidates (threshold=%.2f)", len(new_chunks), len(results), SUPERSESSION_CANDIDATE_THRESHOLD)
    return results


def create_supersedes_edges(graph, supersessions: list[tuple[str, str, dict]]):
    """Create SUPERSEDES edges from detection results."""
    now = datetime.now(timezone.utc).isoformat()
    for new_id, old_id, classification in supersessions:
        graph.query(
            "MATCH (new:Chunk {id: $new_id}), (old:Chunk {id: $old_id}) "
            "MERGE (new)-[s:SUPERSEDES]->(old) "
            "SET s.reason = $reason, s.type = $type, s.detected_at = $ts",
            params={
                "new_id": new_id,
                "old_id": old_id,
                "reason": classification.get("reason", ""),
                "type": classification.get("type", "SUPERSEDES"),
                "ts": now,
            },
        )


# ---------------------------------------------------------------------------
# Query pipeline
# ---------------------------------------------------------------------------


MAX_CONTEXT_CHARS = 12000
MAX_REPORT_CHUNK_CHARS = 2000
MAX_EXPANDED_CHUNKS = 5
SCORE_THRESHOLD = 0.5  # cosine distance; lower = better


def _truncate_report_content(content: str) -> str:
    """Truncate report chunk content to MAX_REPORT_CHUNK_CHARS."""
    if len(content) <= MAX_REPORT_CHUNK_CHARS:
        return content
    return content[:MAX_REPORT_CHUNK_CHARS] + "... [truncated]"


def _is_report_chunk(hit: dict) -> bool:
    """Check if a chunk originates from a task report."""
    return (hit.get("source") or "").startswith("report:")


SYSTEM_PROMPTS = {
    "summary": (
        "You are a team knowledge assistant. Answer ONLY based on the provided context chunks. "
        "Do NOT use general knowledge or make inferences beyond what the context explicitly states. "
        "If the context does not contain enough information to answer, say so clearly. "
        "Be concise and cite sources in [source] format. "
        "When chunks come from different projects, prefix your information with the project name "
        "so the reader knows which project each fact applies to.\n"
        "Context chunks may be annotated:\n"
        "- [confirmed]: This knowledge has been implemented and verified in the codebase.\n"
        "- [recommendation]: This is research/investigation that may not be implemented yet — "
        "present it as a suggestion, not a fact."
    ),
    "technical": (
        "You are a technical knowledge extractor. Given context chunks from the knowledge graph, "
        "produce a structured technical brief using ONLY information from the provided context. "
        "Do NOT infer, guess, or supplement with general knowledge. Include:\n"
        "- Relevant file paths and line numbers\n"
        "- Code patterns, constraints, and gotchas\n"
        "- Architectural decisions and their rationale\n"
        "Format as bullet points grouped by topic. Do NOT write prose — only structured facts. "
        "If the context lacks information for a category, omit it rather than guessing. "
        "Cite sources in [source] format. "
        "When chunks come from different projects, prefix each fact with the project name "
        "so the reader knows which project it applies to.\n"
        "Context chunks may be annotated:\n"
        "- [confirmed]: This knowledge has been implemented and verified in the codebase.\n"
        "- [recommendation]: This is research/investigation that may not be implemented yet — "
        "present it as a suggestion, not a fact."
    ),
}


_STOPWORDS = {
    'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been',
    'being', 'have', 'has', 'had', 'do', 'does', 'did', 'will',
    'would', 'could', 'should', 'may', 'might', 'can', 'shall',
    'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by', 'from',
    'it', 'this', 'that', 'these', 'those', 'i', 'we', 'you',
    'he', 'she', 'they', 'me', 'him', 'her', 'us', 'them',
    'my', 'your', 'his', 'its', 'our', 'their', 'what', 'which',
    'who', 'whom', 'when', 'where', 'why', 'how', 'not', 'no',
    'if', 'or', 'and', 'but', 'so', 'as', 'than', 'too', 'very',
}


def _build_fulltext_query(question: str) -> str:
    """Transform a natural language question into a RediSearch fuzzy+AND query.

    Single word:  'sidebar'                  → '%sidebar%'
    Multi word:   'sidebar autostart require' → '%sidebar% %autostart% %require%'
    """
    words = re.findall(r'\w+', question.lower())
    words = [w for w in words if w not in _STOPWORDS and len(w) > 1]
    if not words:
        return question
    return ' '.join(f'%{w}%' for w in words)


def query_knowledge(graph, question: str, role: str = None, top_k: int = 8, mode: str = "summary", project: str = None) -> dict:
    """Vector search + graph expansion + LLM answer.

    Returns dict with keys: response, chunks, sources, expanded_count.
    """
    # 1. Embed question
    q_vec = embed_texts([question])[0]

    # 2. Vector KNN search — fetch extra candidates to account for
    #    project filtering and superseded-chunk filtering
    fetch_k = top_k * 3 if project else top_k * 2
    knn = graph.query(
        """
        CALL db.idx.vector.queryNodes('Chunk', 'embedding', $k, vecf32($vec))
        YIELD node, score
        OPTIONAL MATCH (superseder:Chunk)-[:SUPERSEDES]->(node)
        WITH node, score WHERE superseder IS NULL
        RETURN node.id AS id, node.content AS content,
               node.source AS source, node.section AS section,
               node.roles AS roles, score, node.project AS project
        """,
        params={"k": fetch_k, "vec": q_vec},
    )

    hits = []
    for row in knn.result_set:
        score = row[5]
        node_project = row[6]
        # Filter out low-relevance hits (cosine distance > threshold)
        if score > SCORE_THRESHOLD:
            continue
        # Filter by project if requested
        if project and node_project != project:
            continue
        hit = {
            "id": row[0],
            "content": row[1],
            "source": row[2],
            "section": row[3],
            "roles": row[4],
            "score": score,
            "project": node_project,
        }
        hits.append(hit)
        if len(hits) >= top_k:
            break

    # 2b. Fulltext fallback when vector search finds nothing
    if not hits:
        try:
            proj_filter = "AND node.project = $project" if project else ""
            ft = graph.query(
                f"""
                CALL db.idx.fulltext.queryNodes('Chunk', $q)
                YIELD node
                OPTIONAL MATCH (superseder:Chunk)-[:SUPERSEDES]->(node)
                WITH node WHERE superseder IS NULL {proj_filter}
                RETURN node.id AS id, node.content AS content,
                       node.source AS source, node.section AS section,
                       node.roles AS roles, node.project AS project
                LIMIT $k
                """,
                params={"q": _build_fulltext_query(question), "k": top_k, **({"project": project} if project else {})},
            )
            for row in ft.result_set:
                hits.append({
                    "id": row[0],
                    "content": row[1],
                    "source": row[2],
                    "section": row[3],
                    "roles": row[4],
                    "score": 0.99,  # synthetic score — fulltext hits have no vector score
                    "project": row[5],
                })
        except Exception:
            pass  # fulltext index may not exist or query may fail

    hit_ids = [h["id"] for h in hits]

    # 4. Graph expansion — 1 hop only to limit context size (batched)
    expanded_chunks = []
    if hit_ids:
        proj_filter = "AND c2.project = $project" if project else ""
        exp = graph.query(
            f"""
            UNWIND $ids AS hid
            MATCH (c1:Chunk {{id: hid}})-[:RELATED_TO|HAS_TOPIC*1..1]-(c2:Chunk)
            WHERE NOT c2.id IN $ids {proj_filter}
            OPTIONAL MATCH (superseder:Chunk)-[:SUPERSEDES]->(c2)
            WITH c2 WHERE superseder IS NULL
            RETURN DISTINCT c2.id AS id, c2.content AS content,
                   c2.source AS source, c2.section AS section,
                   c2.project AS project
            """,
            params={"ids": hit_ids, **({"project": project} if project else {})},
        )
        for row in exp.result_set:
            expanded_chunks.append(
                {"id": row[0], "content": row[1], "source": row[2], "section": row[3], "project": row[4]}
            )

    # Deduplicate expanded and cap at MAX_EXPANDED_CHUNKS
    seen = set(hit_ids)
    unique_expanded = []
    for ec in expanded_chunks:
        if ec["id"] not in seen:
            seen.add(ec["id"])
            unique_expanded.append(ec)
        if len(unique_expanded) >= MAX_EXPANDED_CHUNKS:
            break

    # 5. Short-circuit if no chunks found — don't hallucinate generic answers
    if not hits and not unique_expanded:
        return {
            "response": "No relevant knowledge found.",
            "chunks": [],
            "sources": [],
            "expanded_count": 0,
        }

    # 5b. Confidence annotation for researcher chunks — check for dev-role links
    confidence = {}  # chunk_id -> "confirmed" | "recommendation"
    researcher_ids = [h["id"] for h in hits if "researcher" in (h.get("roles") or "")]
    if researcher_ids:
        try:
            res = graph.query(
                """
                UNWIND $ids AS cid
                MATCH (c:Chunk {id: cid})
                OPTIONAL MATCH (c)-[:RELATED_TO]-(d:Chunk)
                WHERE d.roles CONTAINS 'dev'
                RETURN cid, count(d) > 0 AS has_dev_link
                """,
                params={"ids": researcher_ids},
            )
            for row in res.result_set:
                confidence[row[0]] = "confirmed" if row[1] else "recommendation"
        except Exception:
            # If graph query fails, default researcher chunks to recommendation
            for rid in researcher_ids:
                confidence[rid] = "recommendation"

    # 6. Build context for LLM
    context_parts = []
    for h in hits:
        content = _truncate_report_content(h["content"]) if _is_report_chunk(h) else h["content"]
        conf = confidence.get(h["id"])
        if conf:
            proj_label = f"{h['project']}: " if h.get("project") else ""
            context_parts.append(f"[{conf}: {proj_label}{h['source']} / {h['section']}] {content}")
        else:
            proj_label = f"from {h['project']}: " if h.get("project") else ""
            context_parts.append(f"[{proj_label}{h['source']} / {h['section']}] {content}")
    for ec in unique_expanded:
        content = _truncate_report_content(ec["content"]) if _is_report_chunk(ec) else ec["content"]
        proj_label = f"from {ec['project']}: " if ec.get("project") else ""
        context_parts.append(f"[expanded: {proj_label}{ec['source']} / {ec['section']}] {content}")

    context_text = "\n\n".join(context_parts)

    # Safety net: hard-truncate context to stay within TPM budget
    if len(context_text) > MAX_CONTEXT_CHARS:
        context_text = context_text[:MAX_CONTEXT_CHARS] + "\n... [context truncated]"

    system_prompt = SYSTEM_PROMPTS.get(mode, SYSTEM_PROMPTS["summary"])

    messages = [
        {
            "role": "system",
            "content": system_prompt,
        },
        {
            "role": "user",
            "content": f"Context:\n{context_text}\n\nQuestion: {question}",
        },
    ]

    llm_resp = completion(model=LLM_MODEL, messages=messages)
    answer = llm_resp.choices[0].message.content

    sources = list({h["source"] for h in hits})

    return {
        "response": answer,
        "chunks": hits,
        "sources": sources,
        "expanded_count": len(unique_expanded),
    }
