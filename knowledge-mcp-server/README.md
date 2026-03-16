# Knowledge MCP Server

FalkorDB GraphRAG-based knowledge system for agent-shell team sessions.

## Prerequisites

- Docker (for FalkorDB)
- Python 3.11+
- `ANTHROPIC_API_KEY` environment variable

## Setup

1. Start FalkorDB:

```bash
cd knowledge-mcp-server
docker compose up -d
```

2. Install dependencies:

```bash
cd knowledge-mcp-server
poetry install
```

3. Add to Claude Code MCP config (`.mcp.json`):

```json
{
  "mcpServers": {
    "knowledge": {
      "command": "poetry",
      "args": [
        "-C", "/path/to/knowledge-mcp-server",
        "run", "python3", "/path/to/knowledge-mcp-server/server.py"
      ],
      "env": {
        "AGENT_SHELL_TEAM": "1"
      }
    }
  }
}
```

## Tools

### `query_knowledge`

Query the knowledge graph.

- `query` (string, required) — search question
- `role` (string, optional) — filter by role: `dev`, `tester`, `researcher`, `lead`

### `store_knowledge`

Store knowledge in the graph.

- `content` (string, required) — the knowledge text
- `roles` (array of strings, required) — applicable roles
- `source` (string, optional) — attribution (e.g. `report:request-id`)

Includes deduplication: checks for similar entries before storing.

## Architecture

- Uses `graphrag-sdk` with LiteLLM backend (`anthropic/claude-sonnet-4-20250514`)
- Single graph `team_knowledge` with role tags as metadata
- Ontology auto-detected on first ingestion, saved to `ontology.json`
- Gated by `AGENT_SHELL_TEAM=1` environment variable

## FalkorDB UI

Browser UI available at http://localhost:3000
