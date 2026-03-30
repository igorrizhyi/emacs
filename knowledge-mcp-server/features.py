"""Feature/Scenario extraction pipeline for team knowledge graph.

Extracts behavioral Features with Gherkin Scenarios from knowledge chunks,
using theme entities as aggregation anchors. Runs as a post-entity-extraction
step, clustering chunks by theme before LLM extraction.
"""

import logging
from datetime import datetime, timezone
from difflib import SequenceMatcher

import litellm

from common import CLASSIFICATION_MODEL, KNOWLEDGE_LLM_BACKEND, PROJECT_ROOT, chunk_id
from entities import normalize_entity_name
from llm_queue import queue_llm_task

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants & Config
# ---------------------------------------------------------------------------

FEATURE_FUZZY_THRESHOLD = 0.85

# ---------------------------------------------------------------------------
# Prompt Template
# ---------------------------------------------------------------------------

FEATURE_EXTRACTION_PROMPT = """\
-Goal-
Given technical knowledge chunks about a specific theme, generate a Gherkin Feature \
with behavioral Scenarios that capture the system's expected behavior.

-Context-
Theme: {theme_name}
Theme description: {theme_description}

Existing Features in the system (for @depends_on references):
{existing_features}

Key entities mentioned in the chunks:
{entity_list}

Technical knowledge chunks:
{chunk_contents}

-Instructions-
1. Generate ONE Feature that captures the behavioral contract for this theme.
2. The Feature name should be a clear, human-readable title (e.g., "Task Interrupt Delivery").
   Use Title Case. Do NOT prefix with "Feature:".
3. Write a 1-2 sentence Feature description explaining the behavioral context.
4. Generate 2-5 Scenarios using Given/When/Then format:
   - Each Scenario should test a distinct behavior described in the chunks
   - Use concrete but generic examples (not implementation details)
   - Focus on OBSERVABLE behavior, not internal mechanics
5. For @implements: list entity names that this Feature's behavior depends on (max 5).
   Only reference entities from the provided entity list.
6. For @depends_on: list existing Feature names that must work correctly for this Feature.
   Only reference Features from the provided existing Features list. Leave empty if none.

-Output Format-
Use this exact delimited format:

FEATURE<|>{feature_name}<|>{feature_description}
##
SCENARIO<|>{scenario_name}<|>{given}<|>{when}<|>{then}
##
SCENARIO<|>{scenario_name}<|>{given}<|>{when}<|>{then}
##
IMPLEMENTS<|>{entity_name_1}<|>{entity_name_2}
##
DEPENDS_ON<|>{feature_name_1}<|>{feature_name_2}
##
<|COMPLETE|>

-Example Output-
FEATURE<|>Task Interrupt Delivery<|>When a high-priority task arrives for a busy agent, \
the system cancels the current task and resubmits it after the interrupt is processed.
##
SCENARIO<|>Interrupt replaces current task<|>Given an agent is processing a \
normal-priority task<|>When an interrupt-priority task is submitted<|>Then the current \
task is cancelled and the interrupt task begins processing
##
SCENARIO<|>Original task resumes after interrupt<|>Given an agent had its task \
interrupted<|>When the interrupt task completes<|>Then the original task is resubmitted \
to the agent's queue
##
IMPLEMENTS<|>TASK INTERRUPT QUEUE<|>ACP SESSION CANCEL<|>SHELL MAKER FINISH OUTPUT
##
DEPENDS_ON<|>Agent Task Queue Management
##
<|COMPLETE|>
"""

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------


def parse_feature_extraction_output(output: str) -> dict | None:
    """Parse LLM Feature extraction output.

    Returns dict with keys: name, description, scenarios, implements, depends_on.
    Returns None if parsing fails.
    """
    records = output.split("##")
    feature = None
    scenarios = []
    implements = []
    depends_on = []

    for record in records:
        record = record.strip()
        if not record or "<|COMPLETE|>" in record:
            continue

        parts = [p.strip() for p in record.split("<|>")]

        if parts[0] == "FEATURE" and len(parts) >= 3:
            feature = {"name": parts[1], "description": parts[2]}
        elif parts[0] == "SCENARIO" and len(parts) >= 4:
            scenarios.append({
                "name": parts[1],
                "given": parts[2] if len(parts) > 2 else "",
                "when": parts[3] if len(parts) > 3 else "",
                "then": parts[4] if len(parts) > 4 else "",
            })
        elif parts[0] == "IMPLEMENTS":
            implements = [normalize_entity_name(p) for p in parts[1:] if p]
        elif parts[0] == "DEPENDS_ON":
            depends_on = [p for p in parts[1:] if p]

    if not feature:
        return None

    # Assemble full Gherkin text for each scenario
    for s in scenarios:
        s["text"] = f"Scenario: {s['name']}\n  {s['given']}\n  {s['when']}\n  {s['then']}"

    feature["scenarios"] = scenarios
    feature["implements"] = implements[:5]
    feature["depends_on"] = depends_on
    return feature


# ---------------------------------------------------------------------------
# Context Assembly
# ---------------------------------------------------------------------------


def gather_feature_context(graph, theme_name: str) -> list[dict]:
    """Gather chunks for Feature extraction, centered on a theme entity.

    Traverses the graph from the theme entity via HAS_ENTITY edges.
    Direct chunks first, then 1-hop expansion if fewer than 3 chunks.
    Max 10 chunks, sorted by created_at DESC.
    Excludes superseded chunks.
    """
    # Step 1: Direct chunks linked to this theme
    result = graph.query(
        """
        MATCH (c:Chunk)-[:HAS_ENTITY]->(e:Entity {name: $theme})
        WHERE NOT EXISTS { MATCH (c2:Chunk)-[:SUPERSEDES]->(c) }
        RETURN c.id, c.content, c.source, c.section, c.created_at
        ORDER BY c.created_at DESC
        LIMIT 15
        """,
        params={"theme": theme_name},
    )

    chunks = [
        {"id": r[0], "content": r[1], "source": r[2],
         "section": r[3], "created_at": r[4]}
        for r in result.result_set
    ]

    if len(chunks) < 3:
        # Step 2: Expand via co-occurring entities (1 hop)
        existing_ids = [c["id"] for c in chunks]
        result = graph.query(
            """
            MATCH (e:Entity {name: $theme})<-[:HAS_ENTITY]-(c1:Chunk)
                  -[:HAS_ENTITY]->(e2:Entity)<-[:HAS_ENTITY]-(c2:Chunk)
            WHERE c2.id NOT IN $existing
              AND NOT EXISTS { MATCH (c3:Chunk)-[:SUPERSEDES]->(c2) }
            RETURN DISTINCT c2.id, c2.content, c2.source, c2.section, c2.created_at
            ORDER BY c2.created_at DESC
            LIMIT 5
            """,
            params={"theme": theme_name, "existing": existing_ids},
        )
        chunks.extend([
            {"id": r[0], "content": r[1], "source": r[2],
             "section": r[3], "created_at": r[4]}
            for r in result.result_set
        ])

    return chunks[:10]


# ---------------------------------------------------------------------------
# Deduplication
# ---------------------------------------------------------------------------


def find_existing_feature(name: str, existing_features: list[str]) -> str | None:
    """Find fuzzy-matching existing Feature name.

    Uses SequenceMatcher with FEATURE_FUZZY_THRESHOLD (0.85).
    Returns the existing name if matched, None otherwise.
    """
    best_score = 0.0
    best_name = None
    for existing in existing_features:
        score = SequenceMatcher(None, name.upper(), existing.upper()).ratio()
        if score > best_score:
            best_score = score
            best_name = existing
    if best_score >= FEATURE_FUZZY_THRESHOLD and best_name is not None:
        return best_name
    return None


def find_feature_by_entity_overlap(
    proposed_entities: set[str],
    existing_features_entities: dict[str, set[str]],
    threshold: float = 0.60,
) -> str | None:
    """Find existing Feature with significant entity overlap.

    Uses Jaccard-like metric: overlap / min(both sets).
    Returns the existing Feature name if overlap >= threshold, None otherwise.
    """
    if not proposed_entities:
        return None
    for fname, fentities in existing_features_entities.items():
        if not fentities:
            continue
        overlap = len(proposed_entities & fentities)
        score = overlap / min(len(proposed_entities), len(fentities))
        if score >= threshold:
            return fname
    return None


def _fetch_existing_features(graph) -> list[str]:
    """Get all existing Feature names."""
    result = graph.query("MATCH (f:Feature) RETURN f.name")
    return [row[0] for row in result.result_set]


def _fetch_feature_entities(graph) -> dict[str, set[str]]:
    """Get IMPLEMENTS entity names for each existing Feature."""
    result = graph.query(
        """
        MATCH (f:Feature)-[:IMPLEMENTS]->(e:Entity)
        RETURN f.name, e.name
        """
    )
    mapping: dict[str, set[str]] = {}
    for row in result.result_set:
        mapping.setdefault(row[0], set()).add(row[1])
    return mapping


# ---------------------------------------------------------------------------
# Upsert
# ---------------------------------------------------------------------------


async def upsert_feature(graph, feature_data: dict):
    """Create or update a Feature node and its Scenarios.

    - MERGEs the Feature node with name, description, updated_at.
    - Deletes old HAS_SCENARIO edges.
    - Creates new Scenario chunks (type='scenario', source='flow:{name}').
    - Creates IMPLEMENTS edges to Entity nodes.
    - Creates DEPENDS_ON edges to other Feature nodes.
    """
    name = feature_data["name"]
    now = datetime.now(timezone.utc).isoformat()

    # Upsert Feature node
    graph.query(
        """
        MERGE (f:Feature {name: $name})
        SET f.description = $desc,
            f.updated_at = $ts
        """,
        params={"name": name, "desc": feature_data["description"], "ts": now},
    )

    # Delete old Scenario chunks for this Feature
    graph.query(
        """
        MATCH (f:Feature {name: $name})-[r:HAS_SCENARIO]->(c:Chunk)
        DELETE r
        """,
        params={"name": name},
    )

    # Create new Scenario chunks
    for i, scenario in enumerate(feature_data["scenarios"]):
        scenario_id = chunk_id(f"flow:{name}", scenario["name"])
        graph.query(
            """
            MERGE (c:Chunk {id: $id})
            SET c.content = $content,
                c.source = $source,
                c.section = $section,
                c.type = 'scenario',
                c.created_at = $ts
            """,
            params={
                "id": scenario_id,
                "content": scenario["text"],
                "source": f"flow:{name}",
                "section": name,
                "ts": now,
            },
        )
        # Link to Feature
        graph.query(
            """
            MATCH (f:Feature {name: $fname}), (c:Chunk {id: $cid})
            MERGE (f)-[:HAS_SCENARIO {order: $order}]->(c)
            """,
            params={"fname": name, "cid": scenario_id, "order": i},
        )

    # Create IMPLEMENTS edges
    for entity_name in feature_data.get("implements", []):
        graph.query(
            """
            MATCH (f:Feature {name: $fname}), (e:Entity {name: $ename})
            MERGE (f)-[:IMPLEMENTS]->(e)
            """,
            params={"fname": name, "ename": entity_name},
        )

    # Create DEPENDS_ON edges
    for dep in feature_data.get("depends_on", []):
        graph.query(
            """
            MATCH (f1:Feature {name: $fname}), (f2:Feature {name: $dep})
            MERGE (f1)-[:DEPENDS_ON]->(f2)
            """,
            params={"fname": name, "dep": dep},
        )


# ---------------------------------------------------------------------------
# Top-level orchestrator
# ---------------------------------------------------------------------------


async def extract_features_for_batch(graph, chunks: list[dict]) -> list[str]:
    """Feature extraction pipeline -- called after entity extraction.

    Identifies touched theme entities from the given chunks, gathers context
    per theme, calls LLM for Feature extraction, deduplicates, and upserts.

    Returns list of queued task UUIDs (agent backend) or empty list.
    """
    # 1. Identify touched theme entities
    chunk_ids = [c["id"] for c in chunks]
    result = graph.query(
        """
        MATCH (c:Chunk)-[:HAS_ENTITY]->(e:Entity {type: 'theme'})
        WHERE c.id IN $cids
        RETURN DISTINCT e.name, e.description
        """,
        params={"cids": chunk_ids},
    )

    themes = [{"name": r[0], "description": r[1] or ""} for r in result.result_set]

    if not themes:
        return []

    # 2. Get existing Feature names (for dedup + cross-reference)
    existing_features = _fetch_existing_features(graph)
    existing_feature_entities = _fetch_feature_entities(graph)

    # 3. Get entity list for IMPLEMENTS references
    all_entities = graph.query(
        """
        MATCH (e:Entity) WHERE e.type <> 'theme'
        RETURN e.name, e.type LIMIT 200
        """
    )
    entity_list = [f"{r[0]} ({r[1]})" for r in all_entities.result_set]

    # 4. For each theme, gather context and extract Feature
    queued_task_ids: list[str] = []
    for theme in themes:
        context_chunks = gather_feature_context(graph, theme["name"])
        if len(context_chunks) < 2:
            continue  # Not enough context for meaningful Feature

        # Assemble prompt
        chunk_contents = "\n---\n".join(
            f"[{c['source']} / {c['section']}]\n{c['content']}"
            for c in context_chunks
        )

        prompt = FEATURE_EXTRACTION_PROMPT.format(
            theme_name=theme["name"],
            theme_description=theme["description"],
            existing_features="\n".join(f"- {f}" for f in existing_features) or "None yet",
            entity_list="\n".join(f"- {e}" for e in entity_list[:50]) or "None",
            chunk_contents=chunk_contents,
        )

        # 5. LLM call (or queue for agent backend)
        if KNOWLEDGE_LLM_BACKEND == "agent":
            tid = queue_llm_task(
                PROJECT_ROOT,
                "feature_extraction",
                prompt,
                context={"theme": theme["name"]},
            )
            queued_task_ids.append(tid)
            continue

        resp = await litellm.acompletion(
            model=CLASSIFICATION_MODEL, messages=[{"role": "user", "content": prompt}]
        )
        output = resp.choices[0].message.content or ""

        # 6. Parse
        feature_data = parse_feature_extraction_output(output)
        if not feature_data:
            logger.warning("Feature extraction failed to parse for theme: %s", theme["name"])
            continue

        # 7. Dedup -- check if this matches an existing Feature
        matched = find_existing_feature(feature_data["name"], existing_features)
        if matched:
            feature_data["name"] = matched
        else:
            # Check entity overlap
            proposed_entities = set(feature_data.get("implements", []))
            overlap_match = find_feature_by_entity_overlap(
                proposed_entities, existing_feature_entities
            )
            if overlap_match:
                feature_data["name"] = overlap_match

        # 8. Validate DEPENDS_ON references (only allow existing Features)
        feature_data["depends_on"] = [
            d for d in feature_data["depends_on"]
            if d in existing_features or find_existing_feature(d, existing_features)
        ]

        # 9. Upsert
        await upsert_feature(graph, feature_data)

        # Track for subsequent themes in same batch
        if feature_data["name"] not in existing_features:
            existing_features.append(feature_data["name"])

    if queued_task_ids:
        logger.info("Feature extraction: processed %d themes (%d queued for agent)", len(themes), len(queued_task_ids))
    else:
        logger.info("Feature extraction: processed %d themes", len(themes))

    return queued_task_ids
