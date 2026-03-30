"""Tests for _build_chunks smart chunking and metadata prefix.

Self-contained: copies the _build_chunks logic and its dependencies
to avoid importing server.py (which requires MCP and other packages).
"""

import sys
import os
import hashlib

sys.path.insert(0, os.path.dirname(__file__))

# --- Inline dependencies (from common.py) ---
MAX_CHUNK_CHARS = 1500


def chunk_id(source: str, content: str) -> str:
    return hashlib.sha256(f"{source}:{content}".encode()).hexdigest()[:16]


def _stub_chunk_report(report_text, request_id, role, project=None):
    """Minimal stub of chunk_report for testing metadata prefix on reports."""
    source = f"report:{request_id}"
    chunks = []
    current_lines = []
    section = "Summary"

    def _flush():
        if not current_lines:
            return
        content = "\n".join(current_lines).strip()
        if content and len(content) > 20:
            chunks.append({
                "id": chunk_id(source, content),
                "content": content,
                "source": source,
                "section": section,
                "roles": role,
                "type": "report",
                "project": project,
            })

    for line in report_text.split("\n"):
        if line.startswith("## "):
            _flush()
            section = line[3:].strip()
            current_lines = []
        elif line.startswith("# "):
            _flush()
            section = line[2:].strip()
            current_lines = []
        else:
            current_lines.append(line)
    _flush()
    return chunks


# --- Copy of _build_chunks from server.py (the version we're testing) ---
def _build_chunks(content: str, source: str, roles_str: str, project: str = None):
    if source.startswith("report:"):
        request_id = source.split(":", 1)[1]
        chunks = _stub_chunk_report(content, request_id, roles_str, project=project)
        for c in chunks:
            c["content"] = f"[Source: {c['source']}, Section: {c['section']}]\n{c['content']}"
        return chunks

    lines = content.split("\n")
    section = "General"
    groups = []
    buf = []
    buf_len = 0

    def _flush_buf():
        nonlocal buf, buf_len
        if not buf:
            return
        text = "\n".join(buf).strip()
        if text:
            groups.append((section, text))
        buf = []
        buf_len = 0

    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.rstrip()

        if stripped.startswith("## "):
            _flush_buf()
            section = stripped[3:].strip()
            i += 1
            continue
        if stripped.startswith("# "):
            _flush_buf()
            section = stripped[2:].strip()
            i += 1
            continue

        if not stripped:
            _flush_buf()
            i += 1
            continue

        if stripped.startswith("- "):
            if buf and buf_len + len(stripped) > MAX_CHUNK_CHARS:
                _flush_buf()
            buf.append(stripped)
            buf_len += len(stripped)
            i += 1
            while i < len(lines):
                next_line = lines[i].rstrip()
                if next_line and not next_line.startswith("- ") and (next_line.startswith("  ") or next_line.startswith("\t")):
                    buf.append(next_line)
                    buf_len += len(next_line)
                    i += 1
                else:
                    break
            continue

        if buf and buf_len + len(stripped) > MAX_CHUNK_CHARS:
            _flush_buf()
        buf.append(stripped)
        buf_len += len(stripped)
        i += 1

    _flush_buf()

    chunks = []
    for grp_section, text in groups:
        cid = chunk_id(source, text)
        prefixed = f"[Source: {source}, Section: {grp_section}]\n{text}"
        chunks.append({
            "id": cid,
            "content": prefixed,
            "section": grp_section,
            "source": source,
            "roles": roles_str,
            "type": "knowledge",
            "project": project,
        })
    return chunks


# ========================== TESTS ==========================

def test_multi_bullet_grouped():
    """Consecutive bullets under same section are grouped into one chunk."""
    content = (
        "- First bullet point about auth\n"
        "- Second bullet point about tokens\n"
        "- Third bullet about sessions"
    )
    chunks = _build_chunks(content, "dev.md", "dev")
    assert len(chunks) == 1, f"Expected 1 chunk, got {len(chunks)}: {[c['content'][:60] for c in chunks]}"
    assert "First bullet" in chunks[0]["content"]
    assert "Third bullet" in chunks[0]["content"]


def test_bullets_split_by_blank_line():
    """Blank line between bullet groups produces separate chunks."""
    content = (
        "- Auth bullet 1\n"
        "- Auth bullet 2\n"
        "\n"
        "- Database bullet 1\n"
        "- Database bullet 2"
    )
    chunks = _build_chunks(content, "dev.md", "dev")
    assert len(chunks) == 2, f"Expected 2 chunks, got {len(chunks)}"


def test_bullets_split_by_heading():
    """Heading between bullets produces separate chunks with correct sections."""
    content = (
        "## Authentication\n"
        "- Auth mechanism uses JWT\n"
        "- Tokens expire after 1h\n"
        "## Database\n"
        "- Uses PostgreSQL\n"
        "- Connection pooling enabled"
    )
    chunks = _build_chunks(content, "dev.md", "dev")
    assert len(chunks) == 2, f"Expected 2 chunks, got {len(chunks)}"
    assert chunks[0]["section"] == "Authentication"
    assert chunks[1]["section"] == "Database"


def test_continuation_lines_joined():
    """Indented continuation lines stay with their parent bullet."""
    content = (
        "- Main bullet point\n"
        "  continuation line 1\n"
        "  continuation line 2\n"
        "- Second bullet"
    )
    chunks = _build_chunks(content, "dev.md", "dev")
    assert len(chunks) == 1, f"Expected 1 chunk, got {len(chunks)}"
    assert "continuation line 1" in chunks[0]["content"]
    assert "continuation line 2" in chunks[0]["content"]


def test_paragraph_grouping():
    """Non-bullet consecutive lines are grouped as a paragraph."""
    content = (
        "This is a paragraph line 1.\n"
        "This is paragraph line 2.\n"
        "\n"
        "This is a second paragraph."
    )
    chunks = _build_chunks(content, "mcp", "dev")
    assert len(chunks) == 2, f"Expected 2 chunks, got {len(chunks)}"


def test_metadata_prefix_present():
    """Each chunk has [Source: ..., Section: ...] metadata prefix."""
    content = "- A knowledge bullet"
    chunks = _build_chunks(content, "dev.md", "dev")
    assert chunks[0]["content"].startswith("[Source: dev.md, Section: General]")


def test_chunk_id_excludes_metadata():
    """Chunk ID is based on original content, not the metadata-prefixed content."""
    content = "- A knowledge bullet"
    chunks = _build_chunks(content, "dev.md", "dev")
    # The grouped text is "- A knowledge bullet"
    expected_id = chunk_id("dev.md", "- A knowledge bullet")
    assert chunks[0]["id"] == expected_id, (
        f"Expected ID based on original content, got {chunks[0]['id']} vs expected {expected_id}"
    )


def test_report_chunks_get_metadata():
    """Report chunks also get metadata prefix."""
    content = (
        "## Summary\n"
        "This is a report summary with enough text to pass the 20 char minimum threshold."
    )
    chunks = _build_chunks(content, "report:test-123", "dev")
    assert len(chunks) >= 1
    assert chunks[0]["content"].startswith("[Source: report:test-123, Section:")


def test_report_chunk_id_stable():
    """Report chunk IDs are based on original content (pre-prefix)."""
    content = (
        "## Summary\n"
        "This is a report summary with enough text to pass the 20 char minimum threshold."
    )
    chunks = _build_chunks(content, "report:test-123", "dev")
    # The ID should match what _stub_chunk_report produces before prefix
    original_chunks = _stub_chunk_report(content, "test-123", "dev")
    assert chunks[0]["id"] == original_chunks[0]["id"]


def test_max_chunk_size_respected():
    """Very large bullet groups are split when exceeding MAX_CHUNK_CHARS."""
    bullets = [f"- Bullet number {i} with some extra text to make it longer padding words" for i in range(100)]
    content = "\n".join(bullets)
    chunks = _build_chunks(content, "dev.md", "dev")
    assert len(chunks) > 1, f"Expected multiple chunks for large input, got {len(chunks)}"
    for c in chunks:
        # Strip metadata prefix line for size check
        lines = c["content"].split("\n", 1)
        raw_content = lines[1] if len(lines) > 1 else lines[0]
        assert len(raw_content) <= MAX_CHUNK_CHARS + 200, (
            f"Chunk too large: {len(raw_content)} chars"
        )


def test_single_line_non_bullet():
    """Single non-bullet line produces one chunk."""
    content = "Just a single line of knowledge"
    chunks = _build_chunks(content, "mcp", "dev")
    assert len(chunks) == 1
    assert "Just a single line" in chunks[0]["content"]


def test_headers_stripped_from_chunks():
    """Header lines themselves don't appear in chunk content."""
    content = (
        "## MySection\n"
        "- Some bullet"
    )
    chunks = _build_chunks(content, "dev.md", "dev")
    assert "## MySection" not in chunks[0]["content"]
    assert chunks[0]["section"] == "MySection"


def test_example_output():
    """Print example output for a multi-bullet knowledge string."""
    content = (
        "## Authentication\n"
        "- JWT tokens with RS256 signing\n"
        "  Tokens include user_id and role claims\n"
        "- Session cookies as fallback for browser clients\n"
        "- Rate limiting: 100 req/min per user\n"
        "\n"
        "## Database\n"
        "- PostgreSQL 15 with connection pooling\n"
        "- Read replicas for analytics queries"
    )
    chunks = _build_chunks(content, "dev.md", "dev")
    print("\n--- Example chunking output ---")
    for i, c in enumerate(chunks):
        print(f"\nChunk {i+1} (section={c['section']}, id={c['id'][:8]}...):")
        print(c["content"])
    print("--- End example ---\n")
    assert len(chunks) == 2


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    passed = 0
    failed = 0
    for test_fn in tests:
        try:
            test_fn()
            print(f"  PASS: {test_fn.__name__}")
            passed += 1
        except Exception as e:
            print(f"  FAIL: {test_fn.__name__}: {e}")
            failed += 1
    print(f"\n{passed} passed, {failed} failed out of {passed + failed} tests")
    sys.exit(1 if failed else 0)
