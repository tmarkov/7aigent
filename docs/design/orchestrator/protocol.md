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
  │<─── Response (NDJSON) ───────────│
  │                                  │
  │<─── Screen Update (NDJSON) ──────│
  │                                  │
```

Each turn consists of:
1. Agent sends a command
2. Orchestrator executes and returns response
3. Orchestrator sends screen update

## Command Format

Commands are sent as single-line JSON objects:

```json
{"environment": "bash", "command": "ls -la"}
```

Fields:
- `environment` (required): Target environment name
- `command` (required): Command text to execute

## Response Format

Responses include execution results:

```json
{"output": "total 8\ndrwxr-xr-x 2 user user 4096...", "processed": true}
```

Fields:
- `output`: Text output from the command
- `processed`: Whether the command was successfully processed
- `exit_code` (bash only): Process exit code (0-255)

## Screen Format

Screen updates show current state of all environments:

```json
{
  "sections": [
    {"name": "bash", "content": "Working directory: /workspace\n..."},
    {"name": "python", "content": "Python REPL (ready)"},
    {"name": "editor", "content": "Views: none"}
  ]
}
```

## Error Handling

### Unknown Environment

```json
{"output": "Unknown environment: 'docker'\nAvailable: bash, python, editor", "processed": false}
```

### Parse Error

```json
{"output": "Invalid command format: expected 'environment: command'", "processed": false}
```

### Execution Error

```json
{"output": "Environment error: [traceback]", "processed": false}
```

## Design Decisions

1. **Synchronous request-response**: Each command waits for response before next. Simpler than async, matches REPL usage pattern.

2. **Combined stdout/stderr**: Bash environment returns combined output, matching terminal behavior.

3. **Structured exit codes**: Bash includes `exit_code` field for programmatic checking, not just "success/failure".

4. **Screen is separate message**: Allows screen to be generated after command execution, showing updated state.

5. **No message IDs**: Single-threaded execution means responses always match the preceding command.

## Related Files

- `orchestrator/communication.py` - Message parsing and serialization
- `orchestrator/main.py` - Main loop implementation
- `agent/src/container/manager.rs` - Agent-side protocol handling
