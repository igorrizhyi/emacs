"""Shared constants and utilities for the knowledge-mcp-server package."""

import json
import os
import tempfile
from typing import Optional

from graphrag_sdk import KnowledgeGraph, KnowledgeGraphModelConfig, Ontology
from graphrag_sdk.models.litellm import LiteModel

GRAPH_NAME = "team_knowledge"
ONTOLOGY_PATH = os.path.join(os.path.dirname(__file__), "ontology.json")
MODEL_NAME = os.environ.get("GRAPHRAG_MODEL", "gpt-4o-mini")

FALKORDB_HOST = os.environ.get("FALKORDB_HOST", "127.0.0.1")
FALKORDB_PORT = int(os.environ.get("FALKORDB_PORT", "6380"))


def get_model() -> LiteModel:
    """Create a LiteModel instance with the configured model name."""
    return LiteModel(model_name=MODEL_NAME)


def get_model_config() -> KnowledgeGraphModelConfig:
    """Create a KnowledgeGraphModelConfig from the default model."""
    return KnowledgeGraphModelConfig.with_model(get_model())


def load_ontology() -> Optional[Ontology]:
    """Load ontology from saved JSON if it exists."""
    if os.path.exists(ONTOLOGY_PATH):
        with open(ONTOLOGY_PATH) as f:
            return Ontology.from_json(json.load(f))
    return None


def save_ontology(ontology: Ontology) -> None:
    """Save ontology to JSON for reuse."""
    with open(ONTOLOGY_PATH, "w") as f:
        json.dump(ontology.to_json(), f, indent=2)


def create_kg(ontology: Optional[Ontology] = None) -> KnowledgeGraph:
    """Create a KnowledgeGraph instance (simple constructor, no bootstrap)."""
    model_config = get_model_config()
    kwargs = dict(
        name=GRAPH_NAME,
        model_config=model_config,
        host=FALKORDB_HOST,
        port=FALKORDB_PORT,
    )
    if ontology is not None:
        kwargs["ontology"] = ontology
    return KnowledgeGraph(**kwargs)


def write_temp_txt(content: str) -> str:
    """Write content to a temporary .txt file for Source() ingestion."""
    fd, path = tempfile.mkstemp(suffix=".txt")
    with os.fdopen(fd, "w") as f:
        f.write(content)
    return path
