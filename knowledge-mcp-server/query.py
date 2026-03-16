"""Interactive query script for the hybrid knowledge graph.

Usage:
    python query.py "what is posframe?"
    python query.py --mode technical "what is posframe?"
    python query.py                      # interactive mode
"""

import argparse

from common import get_graph, query_knowledge


def _print_result(result: dict):
    print(f"\nAnswer: {result['response']}")
    if result.get("sources"):
        print(f"Sources: {', '.join(result['sources'])}")
    print(f"({len(result.get('chunks', []))} chunks, {result.get('expanded_count', 0)} via graph)")
    print()


def main():
    parser = argparse.ArgumentParser(description="Query the hybrid knowledge graph")
    parser.add_argument("question", nargs="*", help="Natural language question")
    parser.add_argument("--mode", choices=["summary", "technical"], default="summary",
                        help="Response mode: summary (default) or technical")
    args = parser.parse_args()

    graph = get_graph()

    if args.question:
        question = " ".join(args.question)
        result = query_knowledge(graph, question, mode=args.mode)
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
                result = query_knowledge(graph, question, mode=args.mode)
                _print_result(result)
            except Exception as e:
                print(f"Error: {e}\n")


if __name__ == "__main__":
    main()
