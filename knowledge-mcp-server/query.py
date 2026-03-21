"""Interactive query script for the hybrid knowledge graph.

Usage:
    python query.py "what is posframe?"
    python query.py --mode technical "what is posframe?"
    python query.py                      # interactive mode
"""

import argparse
import sys
import traceback

import common
from common import get_graph, init_schema, query_knowledge, set_graph_name


def _log(msg: str):
    """Print debug message to stderr (won't contaminate stdout parsed by browser)."""
    print(f"[KB-DEBUG] {msg}", file=sys.stderr, flush=True)


def _print_result(result: dict):
    print(f"\n{result['response']}")
    if result.get("sources"):
        print(f"Sources: {', '.join(result['sources'])}")
    print(f"({len(result.get('chunks', []))} chunks, {result.get('expanded_count', 0)} via graph)")
    print()


def main():
    parser = argparse.ArgumentParser(description="Query the hybrid knowledge graph")
    parser.add_argument("question", nargs="*", help="Natural language question")
    parser.add_argument("--mode", choices=["summary", "technical"], default="summary",
                        help="Response mode: summary (default) or technical")
    parser.add_argument("--project-root",
                        help="Project root for graph name derivation (overrides PROJECT_ROOT env var)")
    args = parser.parse_args()

    _log(f"project-root arg: {args.project_root!r}")
    _log(f"mode: {args.mode!r}")
    _log(f"question args: {args.question!r}")

    if args.project_root:
        set_graph_name(args.project_root)

    _log(f"resolved graph name: {common.GRAPH_NAME!r}")

    try:
        graph = get_graph()
        init_schema(graph)
    except Exception:
        _log(f"failed to connect/init graph:\n{traceback.format_exc()}")
        raise

    if args.question:
        question = " ".join(args.question)
        _log(f"query text: {question!r}")
        try:
            result = query_knowledge(graph, question, mode=args.mode)
            _log(f"embedding results: {len(result.get('chunks', []))} chunks")
            _log(f"graph expansion results: {result.get('expanded_count', 0)} expanded")
            _print_result(result)
        except Exception:
            _log(f"query_knowledge failed:\n{traceback.format_exc()}")
            raise
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
