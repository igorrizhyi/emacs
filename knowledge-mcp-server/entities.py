"""Entity extraction pipeline for team knowledge graph.

Extracts entities and relationships from knowledge chunks using LLM,
merges duplicates, and upserts into FalkorDB.
"""

import asyncio
import logging
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone

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
   - entity_name: Name of the entity, capitalized
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
            entities.append({
                "name": normalize_entity_name(attributes[1]),
                "type": attributes[2].lower(),
                "description": attributes[3],
            })
        elif len(attributes) >= 5 and attributes[0].lower() == "relationship":
            try:
                weight = float(attributes[4])
            except (ValueError, IndexError):
                weight = 5.0
            relationships.append({
                "source": normalize_entity_name(attributes[1]),
                "target": normalize_entity_name(attributes[2]),
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

    entity_count = await merge_and_upsert_entities(graph, all_entities, chunk_map)
    rel_count = await merge_and_upsert_relationships(graph, all_relationships)

    logger.info("Extracted %d entities and %d relationships from %d chunks",
                entity_count, rel_count, len(chunks))

    return (entity_count, rel_count)
