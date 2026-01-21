# Architecture Overview

This document provides a high-level overview of 7aigent's architecture and how components interact.

## Terminology Note

**"Container" in this project means "sandbox"**, specifically a bubblewrap-based namespace isolation. This project does **not** use Docker or OCI containers. When you see "container" in the codebase or documentation, it refers to the lightweight bubblewrap sandbox that isolates the orchestrator process.

## System Components

```
┌─────────────────────────────────────────────────────────────┐
│                          User                                │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            │ CLI commands
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                      Agent (Rust)                            │
│  ┌─────────────┬──────────────┬─────────────┬─────────────┐ │
│  │   CLI       │    Session   │  Container  │   LLM       │ │
│  │  Interface  │  Manager     │   Manager   │  Client     │ │
│  └─────────────┴──────────────┴─────────────┴─────────────┘ │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            │ JSON protocol (stdin/stdout)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│              Orchestrator (Python in Sandbox)                │
│  ┌────────────┬─────────────┬──────────────┬──────────────┐ │
│  │   Bash     │   Python    │    Editor    │   Custom     │ │
│  │   Env      │    Env      │     Env      │    Envs      │ │
│  └────────────┴─────────────┴──────────────┴──────────────┘ │
└───────────────────────────┬─────────────────────────────────┘
                            │
                            │ System calls (isolated)
                            ▼
                    ┌───────────────┐
                    │  Filesystem   │
                    │   (Project    │
                    │   Directory)  │
                    └───────────────┘
```

## Agent (Rust)

The agent is the main binary users interact with. It:

- **Manages sessions**: Creates, saves, resumes sessions with full conversation history
- **Orchestrates LLM loop**: Sends prompts to LLM, receives tool calls, executes them
- **Handles sandboxing**: Launches orchestrator in bubblewrap container
- **Controls costs**: Tracks token usage, enforces limits

**Key files**: `agent/src/main.rs`, `agent/src/session.rs`, `agent/src/container.rs`

**See**: [Agent Design](design/agent/) for complete details

## Orchestrator (Python)

The orchestrator provides tool execution environments. It:

- **Runs in sandbox**: Isolated by bubblewrap, only sees project directory
- **Manages environments**: Bash, Python REPL, Editor (file viewing/editing)
- **Handles commands**: Receives JSON commands via stdin, returns JSON responses
- **Maintains state**: Each environment keeps persistent state (bash session, Python variables, open files)

**Key files**: `orchestrator/main.py`, `orchestrator/environments/`

**See**: [Orchestrator Design](design/orchestrator/) for complete details

## Communication Protocol

Agent and orchestrator communicate via JSON over stdin/stdout:

**Command** (agent → orchestrator):
```json
{
  "environment": "bash",
  "command": "ls -la"
}
```

**Response** (orchestrator → agent):
```json
{
  "response": {
    "output": "total 24\ndrwxr-xr-x ...",
    "success": true
  },
  "screen": {
    "bash": {"content": "$ ls -la\ntotal 24...", "max_lines": 50}
  }
}
```

**See**: [Agent-Orchestrator Protocol](reference/agent-orchestrator-protocol.md)

## Sandboxing

The orchestrator runs in a bubblewrap sandbox with:

- **Filesystem isolation**: Only project directory visible, rest of system hidden
- **No network**: Network access disabled by default
- **Resource limits**: Prevents runaway processes
- **Custom tools**: Via `shell_prefix` configuration

**See**: [Sandbox Design](design/sandbox/)

## Environment System

Each environment is independent with its own state:

- **Bash**: Persistent shell session, working directory, environment variables
- **Python**: Persistent REPL, variables survive across commands
- **Editor**: File views with pattern-based navigation

Environments communicate only through the filesystem. No inter-environment messaging.

**See**: [Environment Protocol](reference/environment-protocol.md)

## Session Management

Sessions are persisted to disk in `~/.7aigent/sessions/`:

```
~/.7aigent/sessions/<session-id>/
├── metadata.json        # Session metadata, cost tracking
├── conversation.jsonl   # Full message history
└── screens.jsonl        # Screen state snapshots
```

This enables:
- Resume interrupted sessions
- Inspect session history for debugging
- Track costs across sessions

**See**: [Agent Design - Session Persistence](design/agent/architecture.md)

## Data Flow

1. **User starts agent** with a task
2. **Agent** creates session, sends task to LLM
3. **LLM** responds with tool calls
4. **Agent** sends commands to orchestrator via stdin
5. **Orchestrator** executes in appropriate environment
6. **Orchestrator** returns results via stdout
7. **Agent** appends results to conversation
8. **LLM** sees results, decides next action
9. **Repeat** until task complete

## Design Philosophy

- **Type safety**: Semantic types make invalid states unrepresentable
- **Graceful degradation**: Errors don't crash, they inform the LLM
- **Explicit state**: Screen shows current environment state clearly
- **Simple protocols**: JSON over stdin/stdout, no complex RPC

## Next Steps

- [Agent Design](design/agent/) - Deep dive into agent architecture
- [Orchestrator Design](design/orchestrator/) - How environments work
- [Sandbox Design](design/sandbox/) - Security and isolation
- [Environment Protocol](reference/environment-protocol.md) - Implement custom environments
