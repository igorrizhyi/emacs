"""Interactive query script for the knowledge graph."""

import os
import sys
import json

from graphrag_sdk import KnowledgeGraph, KnowledgeGraphModelConfig, Ontology
from graphrag_sdk.models.litellm import LiteModel

GRAPH_NAME = "team_knowledge"
ONTOLOGY_PATH = os.path.join(os.path.dirname(__file__), "ontology.json")
MODEL_NAME = os.environ.get("GRAPHRAG_MODEL", "gpt-4o-mini")
FALKORDB_HOST = os.environ.get("FALKORDB_HOST", "127.0.0.1")
FALKORDB_PORT = int(os.environ.get("FALKORDB_PORT", "6380"))


def main():
    model = LiteModel(model_name=MODEL_NAME)
    model_config = KnowledgeGraphModelConfig.with_model(model)

    # Load ontology
    ontology = None
    if os.path.exists(ONTOLOGY_PATH):
        with open(ONTOLOGY_PATH) as f:
            ontology = Ontology.from_json(json.load(f))

    kg = KnowledgeGraph(
        name=GRAPH_NAME,
        model_config=model_config,
        ontology=ontology,
        host=FALKORDB_HOST,
        port=FALKORDB_PORT,
    )

    # Single query from args, or interactive mode
    if len(sys.argv) > 1:
        query = " ".join(sys.argv[1:])
        chat = kg.chat_session()
        result = chat.send_message(query)
        print(f"\nAnswer: {result.get('response', 'No results')}")
        if result.get("context"):
            print(f"\nContext: {json.dumps(result['context'], indent=2)}")
        if result.get("cypher"):
            print(f"\nCypher: {result['cypher']}")
    else:
        print(f"Knowledge Graph: {GRAPH_NAME} @ {FALKORDB_HOST}:{FALKORDB_PORT}")
        print(f"Model: {MODEL_NAME}")
        print("Type a query (or 'quit' to exit):\n")
        chat = kg.chat_session()
        while True:
            try:
                query = input("> ")
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if query.strip().lower() in ("quit", "exit", "q"):
                break
            if not query.strip():
                continue
            try:
                result = chat.send_message(query)
                print(f"\nAnswer: {result.get('response', 'No results')}")
                if result.get("context"):
                    print(f"Context: {json.dumps(result['context'], indent=2)}")
                if result.get("cypher"):
                    print(f"Cypher: {result['cypher']}")
                print()
            except Exception as e:
                print(f"Error: {e}\n")


if __name__ == "__main__":
    main()
