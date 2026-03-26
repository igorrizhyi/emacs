"""Entity extraction pipeline for team knowledge graph.

Extracts entities and relationships from knowledge chunks using LLM,
merges duplicates, and upserts into FalkorDB.
"""

import asyncio
import logging
import os
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone
from difflib import SequenceMatcher

import litellm

from common import CLASSIFICATION_MODEL, embed_texts

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants & Config
# ---------------------------------------------------------------------------

ENTITY_TYPES = ["component", "concept", "tool", "identifier", "location", "theme"]


def normalize_entity_name(name: str) -> str:
    """Normalize an entity name for deduplication.

    - Uppercase
    - Strip trailing parentheses (e.g. ``DETECT_SUPERSESSION()`` → ``DETECT SUPERSESSION``)
    - Replace hyphens and underscores with spaces
    - Collapse whitespace
    """
    name = name.upper()
    name = re.sub(r"\(.*?\)\s*$", "", name)  # strip trailing parens
    name = name.replace("-", " ").replace("_", " ")
    name = re.sub(r"\s+", " ", name).strip()
    return name

def _normalize_path_name(raw_name: str) -> str:
    """Extract basename from file-path-like names before general normalization."""
    if '/' in raw_name or '\\' in raw_name:
        return os.path.basename(raw_name)
    return raw_name


FUZZY_MATCH_THRESHOLD = 0.85


def find_existing_match(
    name: str, entity_type: str, existing_entities: list[dict]
) -> str | None:
    """Find the best fuzzy match for *name* among existing entities of the same type.

    Returns the existing entity's name if the best match exceeds
    ``FUZZY_MATCH_THRESHOLD``, otherwise ``None``.
    """
    best_score = 0.0
    best_name: str | None = None
    for existing in existing_entities:
        if existing["type"] != entity_type:
            continue
        score = SequenceMatcher(None, name, existing["name"]).ratio()
        if score > best_score:
            best_score = score
            best_name = existing["name"]
    if best_score >= FUZZY_MATCH_THRESHOLD and best_name is not None:
        return best_name
    return None


def _fetch_existing_entities(graph) -> list[dict]:
    """Query FalkorDB for all existing Entity nodes (name + type)."""
    result = graph.query("MATCH (e:Entity) RETURN e.name, e.type")
    entities = []
    for row in result.result_set:
        entities.append({"name": row[0], "type": row[1]})
    return entities


def _apply_fuzzy_remapping(
    all_entities: list[dict],
    all_relationships: list[dict],
    chunk_map: dict[str, set[str]],
    existing_entities: list[dict],
) -> None:
    """Remap new entity names to existing ones when a fuzzy match is found.

    Mutates *all_entities*, *all_relationships*, and *chunk_map* in place.
    """
    remap: dict[str, str] = {}

    for ent in all_entities:
        name = ent["name"]
        if name in remap:
            continue
        match = find_existing_match(name, ent["type"], existing_entities)
        if match and match != name:
            remap[name] = match
            logger.debug("Fuzzy dedup: remapping %r -> %r", name, match)

    if not remap:
        return

    # Remap entity names
    for ent in all_entities:
        old = ent["name"]
        if old in remap:
            ent["name"] = remap[old]

    # Remap relationship source/target
    for rel in all_relationships:
        if rel["source"] in remap:
            rel["source"] = remap[rel["source"]]
        if rel["target"] in remap:
            rel["target"] = remap[rel["target"]]

    # Remap chunk_map keys
    for old_name, new_name in remap.items():
        if old_name in chunk_map:
            chunk_map[new_name] = chunk_map.get(new_name, set()) | chunk_map.pop(old_name)


TUPLE_DELIMITER = "<|>"
RECORD_DELIMITER = "##"
COMPLETION_DELIMITER = "<|COMPLETE|>"

# ---------------------------------------------------------------------------
# Prompt Templates
# ---------------------------------------------------------------------------

ENTITY_EXTRACTION_PROMPT = """\
-Goal-
Given a piece of team knowledge, identify all notable named entities and relationships.

-Steps-
1. Identify all entities. For each entity, extract:
   - entity_name: Name of the entity, CAPITALIZED
   - entity_type: One of [{entity_types}]
   - entity_description: Comprehensive description of the entity's attributes and role

Format each entity as:
("entity"{tuple_delim}<entity_name>{tuple_delim}<entity_type>{tuple_delim}<entity_description>)

2. From the entities identified in step 1, identify all meaningful relationships.
For each relationship, extract:
   - source_entity: name of the source entity
   - target_entity: name of the target entity
   - relationship_description: explanation of why these entities are related
   - relationship_strength: an integer score 1-10 indicating strength of the relationship

Format each relationship as:
("relationship"{tuple_delim}<source_entity>{tuple_delim}<target_entity>{tuple_delim}<relationship_description>{tuple_delim}<relationship_strength>)

3. Return output as a single list of all entities and relationships identified in steps 1 and 2.
Use **{record_delim}** as the list delimiter.

4. When finished, output {completion_delim}

Entity type descriptions:
- component: A software module, package, library, or service
- concept: An abstract idea, pattern, or methodology
- tool: A specific tool, database, or external dependency
- identifier: A function name, variable, configuration key, or code symbol
- location: A file path, directory, URL, or endpoint
- theme: A broad topic or area that this knowledge relates to (e.g., "task persistence", "agent lifecycle", "graph search", "MCP protocol")

Important: Extract ANY notable named thing regardless of type. The types above are hints, \
not constraints. The value is in entity names and descriptions.
- Do NOT extract git commit hashes (e.g., c5d4603, bacea92) as entities. They are ephemeral references, not meaningful concepts.
- Do NOT extract programming language constructs or primitives (e.g., let*, defvar, nil, t, lambda, async/await)
- Do NOT extract generic variable names that are common across codebases (e.g., face, status, buffer, config, data, result)
- Do NOT extract property values or flags (e.g., invisible t, :extend t, force true)
- Do NOT extract formatting details (e.g., bold markers, heading levels, indentation patterns)
- Do NOT extract specific line number references (e.g., 'line 790', 'lines 2283-2329')

- Prefer ONE entity per feature/concept rather than splitting into sub-entities. For example, extract 'RESERVED AGENT STATUS' as one entity, not separate entities for 'reserved status detection', 'reserved dismiss guard', 'reserved sidebar UI', etc.
- For relationships, use the relationship description to capture sub-aspects rather than creating separate entities.

- Use the FULL 1-10 range for relationship_strength. Reserve 9-10 for direct dependencies (A uses B, A contains B). Use 5-7 for related concepts. Use 1-4 for loose associations.

-Examples-
Example 1:
Text: The agent-shell package uses FalkorDB as its graph database. The knowledge MCP server \
stores chunks with vector embeddings for semantic search.
Output:
("entity"{tuple_delim}"AGENT-SHELL"{tuple_delim}"component"{tuple_delim}"A package that provides the agent shell framework"){record_delim}
("entity"{tuple_delim}"FALKORDB"{tuple_delim}"tool"{tuple_delim}"A graph database used by agent-shell for knowledge storage"){record_delim}
("entity"{tuple_delim}"KNOWLEDGE MCP SERVER"{tuple_delim}"component"{tuple_delim}"An MCP server that stores knowledge chunks with vector embeddings"){record_delim}
("entity"{tuple_delim}"VECTOR EMBEDDINGS"{tuple_delim}"concept"{tuple_delim}"Numeric representations used for semantic search of knowledge chunks"){record_delim}
("relationship"{tuple_delim}"AGENT-SHELL"{tuple_delim}"FALKORDB"{tuple_delim}"Agent-shell uses FalkorDB as its graph database"{tuple_delim}9){record_delim}
("relationship"{tuple_delim}"KNOWLEDGE MCP SERVER"{tuple_delim}"VECTOR EMBEDDINGS"{tuple_delim}"The server stores chunks with vector embeddings for search"{tuple_delim}8)
{completion_delim}

-Real Data-
Entity types: [{entity_types}]
Text: {input_text}
Output:
"""

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------


def parse_extraction_output(output: str) -> tuple[list[dict], list[dict]]:
    """Parse LLM extraction output into entities and relationships.

    Returns (entities, relationships) where each is a list of dicts.
    """
    entities = []
    relationships = []

    records = output.split(RECORD_DELIMITER)
    for record in records:
        record = record.strip()
        if not record or COMPLETION_DELIMITER in record:
            continue

        match = re.search(r"\((.+)\)", record, re.DOTALL)
        if not match:
            continue

        attributes = [a.strip().strip('"') for a in match.group(1).split(TUPLE_DELIMITER)]

        if len(attributes) >= 4 and attributes[0].lower() == "entity":
            raw_name = attributes[1]
            entity_type = attributes[2].lower()
            if entity_type == "location":
                raw_name = _normalize_path_name(raw_name)
            entities.append({
                "name": normalize_entity_name(raw_name),
                "type": entity_type,
                "description": attributes[3],
            })
        elif len(attributes) >= 5 and attributes[0].lower() == "relationship":
            try:
                weight = float(attributes[4])
            except (ValueError, IndexError):
                weight = 5.0
            relationships.append({
                "source": normalize_entity_name(_normalize_path_name(attributes[1])),
                "target": normalize_entity_name(_normalize_path_name(attributes[2])),
                "description": attributes[3],
                "weight": weight,
            })

    return entities, relationships


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------


async def extract_entities_from_chunk(chunk_content: str) -> tuple[list[dict], list[dict]]:
    """Extract entities and relationships from a single chunk via LLM."""
    entity_types_str = ", ".join(ENTITY_TYPES)
    prompt = ENTITY_EXTRACTION_PROMPT.format(
        entity_types=entity_types_str,
        tuple_delim=TUPLE_DELIMITER,
        record_delim=RECORD_DELIMITER,
        completion_delim=COMPLETION_DELIMITER,
        input_text=chunk_content,
    )

    messages = [{"role": "user", "content": prompt}]
    resp = await litellm.acompletion(model=CLASSIFICATION_MODEL, messages=messages)
    output = resp.choices[0].message.content or ""

    return parse_extraction_output(output)


# ---------------------------------------------------------------------------
# Merging & Upserting
# ---------------------------------------------------------------------------


def _fuzzy_merge_groups(grouped: dict[str, list[dict]]) -> dict[str, list[dict]]:
    """Merge entity groups whose names have a containment relationship.

    If one name is a substring of another, their groups are merged under the
    longer (more specific) name.  E.g. "MCP SERVER" merges into
    "KNOWLEDGE MCP SERVER".
    """
    names = list(grouped.keys())
    merged: dict[str, list[dict]] = {}
    used: set[str] = set()

    for i, name_a in enumerate(names):
        if name_a in used:
            continue
        group = list(grouped[name_a])
        canonical = name_a
        for j in range(i + 1, len(names)):
            name_b = names[j]
            if name_b in used:
                continue
            if name_a in name_b or name_b in name_a:
                group.extend(grouped[name_b])
                used.add(name_b)
                # Keep the longer (more specific) name as canonical
                if len(name_b) > len(canonical):
                    canonical = name_b
        merged[canonical] = group
        used.add(name_a)

    return merged


async def merge_and_upsert_entities(
    graph, all_entities: list[dict], chunk_map: dict
) -> int:
    """Merge duplicate entities and upsert Entity nodes + HAS_ENTITY edges.

    Args:
        graph: FalkorDB graph handle.
        all_entities: List of entity dicts with keys: name, type, description.
        chunk_map: Mapping from entity name to set of chunk IDs that mention it.

    Returns:
        Number of unique entities upserted.
    """
    grouped: dict[str, list[dict]] = defaultdict(list)
    for ent in all_entities:
        grouped[ent["name"]].append(ent)

    grouped = _fuzzy_merge_groups(grouped)

    now = datetime.now(timezone.utc).isoformat()
    texts_to_embed = []
    entity_data = []

    for name, mentions in grouped.items():
        type_counts = Counter(m["type"] for m in mentions)
        entity_type = type_counts.most_common(1)[0][0]

        seen_descs = set()
        unique_descs = []
        for m in mentions:
            desc = m["description"].strip()
            if desc and desc not in seen_descs:
                seen_descs.add(desc)
                unique_descs.append(desc)

        description = ". ".join(unique_descs)

        texts_to_embed.append(f"{name}: {description}")
        entity_data.append({
            "name": name,
            "type": entity_type,
            "description": description,
            "chunk_ids": chunk_map.get(name, set()),
        })

    if not entity_data:
        return 0

    vectors = embed_texts(texts_to_embed)

    for data, vec in zip(entity_data, vectors):
        graph.query(
            """
            MERGE (e:Entity {name: $name})
            SET e.type = $type,
                e.description = $desc,
                e.embedding = vecf32($emb),
                e.updated_at = $ts
            """,
            params={
                "name": data["name"],
                "type": data["type"],
                "desc": data["description"],
                "emb": vec,
                "ts": now,
            },
        )

        for cid in data["chunk_ids"]:
            graph.query(
                """
                MATCH (c:Chunk {id: $cid}), (e:Entity {name: $name})
                MERGE (c)-[:HAS_ENTITY]->(e)
                """,
                params={"cid": cid, "name": data["name"]},
            )

    return len(entity_data)


async def merge_and_upsert_relationships(
    graph, all_relationships: list[dict]
) -> int:
    """Merge duplicate relationships and upsert RELATES_TO edges.

    Relationships are undirected — deduplicated by sorting (source, target).

    Returns:
        Number of unique relationships upserted.
    """
    grouped: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for rel in all_relationships:
        key = tuple(sorted((rel["source"], rel["target"])))
        grouped[key].append(rel)

    for (src, tgt), mentions in grouped.items():
        total_weight = sum(m["weight"] for m in mentions)
        seen_descs = set()
        unique_descs = []
        for m in mentions:
            desc = m["description"].strip()
            if desc and desc not in seen_descs:
                seen_descs.add(desc)
                unique_descs.append(desc)
        description = ". ".join(unique_descs)

        graph.query(
            """
            MATCH (a:Entity {name: $src}), (b:Entity {name: $tgt})
            MERGE (a)-[r:RELATES_TO]->(b)
            SET r.description = $desc,
                r.weight = $weight
            """,
            params={
                "src": src,
                "tgt": tgt,
                "desc": description,
                "weight": total_weight,
            },
        )

    return len(grouped)


# ---------------------------------------------------------------------------
# Top-level orchestrator
# ---------------------------------------------------------------------------


async def extract_and_store_entities(
    graph, chunks: list[dict]
) -> tuple[int, int]:
    """Extract entities from chunks, merge, and store in graph.

    Args:
        graph: FalkorDB graph handle.
        chunks: List of chunk dicts (must have 'id' and 'content' keys).

    Returns:
        (entity_count, relationship_count) tuple.
    """
    tasks = [extract_entities_from_chunk(c["content"]) for c in chunks]
    results = await asyncio.gather(*tasks, return_exceptions=True)

    all_entities = []
    all_relationships = []
    chunk_map: dict[str, set[str]] = defaultdict(set)

    for chunk, result in zip(chunks, results):
        if isinstance(result, Exception):
            logger.warning("Entity extraction failed for chunk %s: %s", chunk["id"], result)
            continue
        entities, relationships = result
        for ent in entities:
            chunk_map[ent["name"]].add(chunk["id"])
        all_entities.extend(entities)
        all_relationships.extend(relationships)

    # Fuzzy-match new entities against existing graph nodes to consolidate
    # near-duplicates (e.g. "KNOWLEDGE SERVER" vs "KNOWLEDGE MCP SERVER").
    existing_entities = _fetch_existing_entities(graph)
    if existing_entities:
        _apply_fuzzy_remapping(all_entities, all_relationships, chunk_map, existing_entities)

    entity_count = await merge_and_upsert_entities(graph, all_entities, chunk_map)
    rel_count = await merge_and_upsert_relationships(graph, all_relationships)

    logger.info("Extracted %d entities and %d relationships from %d chunks",
                entity_count, rel_count, len(chunks))

    return (entity_count, rel_count)
