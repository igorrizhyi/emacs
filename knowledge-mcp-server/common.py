"""Shared constants, schema helpers, and ingestion pipeline for hybrid vector+graph knowledge system."""

import hashlib
import os
import re
from datetime import datetime, timezone

from falkordb import FalkorDB
from litellm import completion, embedding

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GRAPH_NAME = "team_knowledge"
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
    # Unique constraints
    graph.query("CREATE CONSTRAINT IF NOT EXISTS FOR (c:Chunk) REQUIRE c.id IS UNIQUE")
    graph.query("CREATE CONSTRAINT IF NOT EXISTS FOR (t:Topic) REQUIRE t.name IS UNIQUE")
    graph.query("CREATE CONSTRAINT IF NOT EXISTS FOR (r:Role) REQUIRE r.name IS UNIQUE")

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
    try:
        graph.query("CREATE INDEX IF NOT EXISTS FOR (c:Chunk) ON (c.source)")
    except Exception:
        pass
    try:
        graph.query("CREATE INDEX IF NOT EXISTS FOR (c:Chunk) ON (c.roles)")
    except Exception:
        pass

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


def chunk_knowledge_file(filepath: str, role: str) -> list[dict]:
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


def ingest_chunks(graph, chunks: list[dict]):
    """Embed chunks and MERGE them into the graph with FOR_ROLE edges."""
    if not chunks:
        return

    texts = [c["content"] for c in chunks]
    vectors = embed_texts(texts)
    now = datetime.now(timezone.utc).isoformat()

    for chunk, vec in zip(chunks, vectors):
        graph.query(
            """
            MERGE (c:Chunk {id: $id})
            SET c.content   = $content,
                c.embedding = vecf32($vec),
                c.source    = $source,
                c.section   = $section,
                c.roles     = $roles,
                c.created_at = $ts
            """,
            params={
                "id": chunk["id"],
                "content": chunk["content"],
                "vec": vec,
                "source": chunk["source"],
                "section": chunk["section"],
                "roles": chunk["roles"],
                "ts": now,
            },
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


def create_similarity_edges(graph, threshold: float = 0.15):
    """Create RELATED_TO edges between chunk pairs whose vector distance <= threshold.

    FalkorDB vector search returns *distance* (lower = more similar for cosine).
    We query each chunk's nearest neighbours and create edges where distance is
    below the threshold.
    """
    result = graph.query("MATCH (c:Chunk) RETURN c.id AS id")
    chunk_ids = [row[0] for row in result.result_set]

    for cid in chunk_ids:
        # Get this chunk's embedding
        res = graph.query(
            "MATCH (c:Chunk {id: $id}) RETURN c.embedding AS vec",
            params={"id": cid},
        )
        if not res.result_set or res.result_set[0][0] is None:
            continue
        vec = res.result_set[0][0]

        # KNN search
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
            if nid == cid:
                continue
            if score > threshold:
                continue
            # Create edge (avoid duplicates with MERGE)
            graph.query(
                """
                MATCH (a:Chunk {id: $a}), (b:Chunk {id: $b})
                MERGE (a)-[r:RELATED_TO]->(b)
                SET r.score = $score
                """,
                params={"a": cid, "b": nid, "score": score},
            )


# ---------------------------------------------------------------------------
# Query pipeline
# ---------------------------------------------------------------------------


def query_knowledge(graph, question: str, role: str = None, top_k: int = 8) -> dict:
    """Vector search + graph expansion + LLM answer.

    Returns dict with keys: response, chunks, sources, expanded_count.
    """
    # 1. Embed question
    q_vec = embed_texts([question])[0]

    # 2. Vector KNN search
    knn = graph.query(
        """
        CALL db.idx.vector.queryNodes('Chunk', 'embedding', $k, vecf32($vec))
        YIELD node, score
        RETURN node.id AS id, node.content AS content,
               node.source AS source, node.section AS section,
               node.roles AS roles, score
        """,
        params={"k": top_k, "vec": q_vec},
    )

    hits = []
    for row in knn.result_set:
        hit = {
            "id": row[0],
            "content": row[1],
            "source": row[2],
            "section": row[3],
            "roles": row[4],
            "score": row[5],
        }
        hits.append(hit)

    # 3. Optional role filter (post-retrieval)
    if role:
        hits = [h for h in hits if role in (h.get("roles") or "").split(",")]

    hit_ids = [h["id"] for h in hits]

    # 4. Graph expansion 1-2 hops
    expanded_chunks = []
    for hid in hit_ids:
        exp = graph.query(
            """
            MATCH (c1:Chunk {id: $id})-[:RELATED_TO|HAS_TOPIC*1..2]-(c2:Chunk)
            WHERE c2.id <> $id
            RETURN DISTINCT c2.id AS id, c2.content AS content,
                   c2.source AS source, c2.section AS section
            """,
            params={"id": hid},
        )
        for row in exp.result_set:
            if row[0] not in hit_ids:
                expanded_chunks.append(
                    {"id": row[0], "content": row[1], "source": row[2], "section": row[3]}
                )

    # Deduplicate expanded
    seen = set(hit_ids)
    unique_expanded = []
    for ec in expanded_chunks:
        if ec["id"] not in seen:
            seen.add(ec["id"])
            unique_expanded.append(ec)

    # 5. Build context for LLM
    context_parts = []
    for h in hits:
        context_parts.append(f"[{h['source']} / {h['section']}] {h['content']}")
    for ec in unique_expanded:
        context_parts.append(f"[expanded: {ec['source']} / {ec['section']}] {ec['content']}")

    context_text = "\n\n".join(context_parts)

    messages = [
        {
            "role": "system",
            "content": (
                "You are a team knowledge assistant. Answer the question based on "
                "the provided context chunks from the knowledge graph. Be concise "
                "and cite sources when possible."
            ),
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
