# Orchestrator Protocol

The agent-orchestrator communication protocol uses NDJSON (newline-delimited JSON) over stdin/stdout. This design enables simple, reliable communication between the agent process and the sandboxed orchestrator.

## Protocol Design

### Why NDJSON over stdin/stdout?

- **Simplicity**: No sockets, no HTTP, no complex framing
- **Sandbox-friendly**: Stdio is universally available in containers
- **Streaming**: Each message is a complete JSON object on a single line
- **Debuggable**: Human-readable, easy to log and inspect

### Message Flow

```
Agent                          Orchestrator
  │                                  │
  │──── Command (NDJSON) ───────────>│
  │                                  │
  │<─── Response+Screen (NDJSON) ────│
  │                                  │
```

Each turn consists of:
1. Agent sends a command
2. Orchestrator executes and returns a single combined response+screen message

## Command Format

Commands are sent as single-line JSON objects:

```json
{"env": "bash", "command": "ls -la"}
```

Fields:
- `env` (required): Target environment name
- `command` (required): Command text to execute

## Response Format

Each response is a single JSON object combining command output and updated screen state:

```json
{
  "response": {
    "output": "total 8\ndrwxr-xr-x 2 user user 4096...",
    "processed": true
  },
  "screen": {
    "bash": {"content": "Working directory: /workspace\n..."},
    "python": {"content": ""},
    "editor": {"content": "Views: none"}
  }
}
```

`response` fields:
- `output`: Text output from the command
- `processed`: Whether the command was successfully processed
- `exit_code` (bash only): Process exit code (0-255)

`screen` fields: A dict keyed by environment name, each value having a `content` string with the current display state of that environment.

## Error Handling

### Unknown Environment

```json
{
  "response": {"output": "Unknown environment: 'docker'. Available environments: bash, python, editor", "processed": false},
  "screen": { ... }
}
```

### Parse Error

```json
{"type": "error", "message": "Parse error: ..."}
```

### Execution Error

```json
{
  "response": {"output": "Environment error: [traceback]", "processed": false},
  "screen": { ... }
}
```

## Design Decisions

1. **Synchronous request-response**: Each command waits for response before next. Simpler than async, matches REPL usage pattern.

2. **Combined stdout/stderr**: Bash environment returns combined output, matching terminal behavior.

3. **Structured exit codes**: Bash includes `exit_code` field for programmatic checking, not just "success/failure".

4. **Combined response+screen**: Response and screen state are sent as a single message per turn. This simplifies the agent's receive logic and ensures the screen is always up-to-date with the response.

5. **No message IDs**: Single-threaded execution means responses always match the preceding command.

## Related Files

- `orchestrator/communication.py` - Message parsing and serialization
- `orchestrator/main.py` - Main loop implementation
- `agent/src/container.rs` - Agent-side protocol handling
