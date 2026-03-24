"""SQLite-backed cache for knowledge query results.

Stores formatted query results as markdown files and tracks them in a
SQLite database with query embeddings for similarity-based invalidation.
"""

import hashlib
import json
import logging
import os
import sqlite3
import threading
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

_local = threading.local()

CACHE_SIMILARITY_THRESHOLD = 0.6  # cosine similarity; above this = stale


def _cache_db_path(project_root: str) -> str:
    """Return the path to the cache SQLite database."""
    return os.path.join(project_root, ".agent-shell", "knowledge", "cache", "cache.db")


def _cache_dir(project_root: str) -> str:
    """Return the cache directory for markdown files."""
    return os.path.join(project_root, ".agent-shell", "knowledge", "cache")


def _get_conn(project_root: str) -> sqlite3.Connection:
    """Get or create a thread-local SQLite connection."""
    db_path = _cache_db_path(project_root)
    key = f"conn_{db_path}"
    conn = getattr(_local, key, None)
    if conn is None:
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        conn = sqlite3.connect(db_path, check_same_thread=False)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute(
            """CREATE TABLE IF NOT EXISTS cache_entries (
                id TEXT PRIMARY KEY,
                query TEXT NOT NULL,
                file_path TEXT NOT NULL,
                embedding TEXT NOT NULL,
                created_at TEXT NOT NULL
            )"""
        )
        conn.commit()
        setattr(_local, key, conn)
    return conn


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    """Compute cosine similarity between two vectors (1 = identical, 0 = orthogonal)."""
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = sum(x * x for x in a) ** 0.5
    norm_b = sum(x * x for x in b) ** 0.5
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot / (norm_a * norm_b)


def cache_query_result(
    project_root: str,
    query: str,
    query_embedding: list[float],
    context_text: str,
) -> str | None:
    """Write a query result to a cache file and record it in SQLite.

    Returns the cache file path, or None if caching fails.
    """
    if not project_root:
        return None

    try:
        cache_id = hashlib.sha256(query.encode()).hexdigest()[:12]
        cache_path = os.path.join(_cache_dir(project_root), f"{cache_id}.md")
        now = datetime.now(timezone.utc).isoformat()

        # Build markdown content
        truncated_query = query[:80] + ("..." if len(query) > 80 else "")
        md_content = (
            f"# Knowledge Cache: {truncated_query}\n\n"
            f"{context_text}\n\n"
            f"---\n"
            f"*Cached: {now}*\n"
        )

        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        with open(cache_path, "w") as f:
            f.write(md_content)

        conn = _get_conn(project_root)
        conn.execute(
            """INSERT OR REPLACE INTO cache_entries
               (id, query, file_path, embedding, created_at)
               VALUES (?, ?, ?, ?, ?)""",
            (cache_id, query, cache_path, json.dumps(query_embedding), now),
        )
        conn.commit()

        logger.info("Cached query result: %s -> %s", cache_id, cache_path)
        return cache_path

    except Exception:
        logger.exception("Failed to cache query result")
        return None


def invalidate_cache(
    project_root: str,
    content_embeddings: list[list[float]],
) -> int:
    """Invalidate cache entries similar to newly stored content.

    Loads all cache entries, computes cosine similarity against each
    content embedding, and deletes entries above the threshold.

    Returns the number of invalidated entries.
    """
    if not project_root or not content_embeddings:
        return 0

    try:
        conn = _get_conn(project_root)
        rows = conn.execute(
            "SELECT id, file_path, embedding FROM cache_entries"
        ).fetchall()

        if not rows:
            return 0

        stale_ids = []
        stale_paths = []

        for row_id, file_path, embedding_json in rows:
            try:
                cached_embedding = json.loads(embedding_json)
            except (json.JSONDecodeError, TypeError):
                # Corrupt entry — mark for removal
                stale_ids.append(row_id)
                stale_paths.append(file_path)
                continue

            for content_vec in content_embeddings:
                sim = _cosine_similarity(cached_embedding, content_vec)
                if sim > CACHE_SIMILARITY_THRESHOLD:
                    stale_ids.append(row_id)
                    stale_paths.append(file_path)
                    break  # no need to check other content vecs for this entry

        if not stale_ids:
            return 0

        # Delete cache files
        for path in stale_paths:
            try:
                if path and os.path.exists(path):
                    os.remove(path)
            except OSError:
                pass  # best-effort

        # Delete from SQLite
        placeholders = ",".join("?" for _ in stale_ids)
        conn.execute(
            f"DELETE FROM cache_entries WHERE id IN ({placeholders})",
            stale_ids,
        )
        conn.commit()

        logger.info("Invalidated %d cache entries", len(stale_ids))
        return len(stale_ids)

    except Exception:
        logger.exception("Failed to invalidate cache")
        return 0
