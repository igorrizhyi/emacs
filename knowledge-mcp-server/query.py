"""Interactive query script for the knowledge graph."""

import json
import sys

from common import (
    GRAPH_NAME,
    MODEL_NAME,
    FALKORDB_HOST,
    FALKORDB_PORT,
    load_ontology,
    create_kg,
)


def main():
    ontology = load_ontology()
    kg = create_kg(ontology=ontology)

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
