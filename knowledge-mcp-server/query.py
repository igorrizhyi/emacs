"""Interactive query script for the hybrid knowledge graph.

Usage:
    python query.py "what is posframe?"
    python query.py                      # interactive mode
"""

import sys

from common import get_graph, query_knowledge


def _print_result(result: dict):
    print(f"\nAnswer: {result['response']}")
    if result.get("sources"):
        print(f"Sources: {', '.join(result['sources'])}")
    print(f"({len(result.get('chunks', []))} chunks, {result.get('expanded_count', 0)} via graph)")
    print()


def main():
    graph = get_graph()

    if len(sys.argv) > 1:
        question = " ".join(sys.argv[1:])
        result = query_knowledge(graph, question)
        _print_result(result)
    else:
        print("Knowledge query (Ctrl+C to exit)\n")
        while True:
            try:
                question = input("> ")
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not question.strip():
                continue
            try:
                result = query_knowledge(graph, question)
                _print_result(result)
            except Exception as e:
                print(f"Error: {e}\n")


if __name__ == "__main__":
    main()
