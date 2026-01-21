# Agent Architecture

This document describes the internal structure of the agent and how components interact.

## High-Level Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  Agent (Rust binary, runs on host)                         │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │   CLI        │  │  Session     │  │  Config      │     │
│  │   Interface  │  │  (with save/ │  │  Loader      │     │
│  │              │  │   load API)  │  │              │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
│         │                  │                  │             │
│         └──────────────────┼──────────────────┘             │
│                            │                                │
│                    ┌───────▼────────┐                       │
│                    │  Agent Core    │                       │
│                    │  (Main Loop)   │                       │
│                    └───────┬────────┘                       │
│                            │                                │
│      ┌─────────────────────┼─────────────────────┐         │
│      │                     │                     │         │
│  ┌───▼────────┐   ┌────────▼─────────┐  ┌───────▼──────┐ │
│  │  LLM       │   │  Container       │  │  History &   │ │
│  │  Client    │   │  Manager         │  │  Context     │ │
│  └────────────┘   └──────────────────┘  └──────────────┘ │
│                            │                                │
└────────────────────────────┼────────────────────────────────┘
                             │ JSON protocol (stdin/stdout)
                             │
                    ┌────────▼────────┐
                    │  Bubblewrap     │
                    │  Sandbox        │
                    │                 │
                    │  ┌───────────┐  │
                    │  │Orchestrator│  │
                    │  └───────────┘  │
                    │                 │
                    │  Environments:  │
                    │  bash, python,  │
                    │  editor, ...    │
                    └─────────────────┘
```

## Component Responsibilities

| Component | Purpose |
|-----------|---------|
| **CLI Interface** | Parse args, handle user input, display progress |
| **Config Loader** | Load and merge project + global configs |
| **Session** | Owns session state and persistence (create/load/save methods) |
| **Agent Core** | Main interaction loop orchestration |
| **LLM Client** | Call OpenAI-compatible APIs, retry logic, cost tracking |
| **Container Manager** | Build/spawn/manage bubblewrap sandbox with orchestrator |
| **History & Context** | Loaded from session, maintained in-memory during execution |

## Data Flow

### Session Start

1. **CLI** parses arguments (task, session ID to resume, etc.)
2. **Config Loader** loads and validates configuration
3. **Session** either:
   - Creates new session with task
   - Loads existing session from disk
4. **Container Manager** spawns orchestrator in sandbox
5. **Agent Core** begins interaction loop

### Interaction Loop

1. **Agent Core** constructs prompt from:
   - Task description
   - Conversation history
   - Current screen state (all environments)
2. **LLM Client** sends prompt to LLM API
3. **LLM Client** receives response with tool calls
4. **Agent Core** for each tool call:
   - Sends command to **Container Manager**
   - Receives result from orchestrator
   - Appends to conversation history
5. **Session** persists:
   - Updated conversation history
   - New screen state
   - Token usage
6. Repeat until LLM indicates task complete

### Session End

1. **Session** saves final state to disk
2. **Container Manager** shuts down orchestrator
3. **CLI** displays summary (cost, turns, result)

## Module Structure

```
agent/
├── src/
│   ├── main.rs              # CLI entry point
│   ├── config.rs            # Configuration loading and validation
│   ├── session.rs           # Session struct with save/load/create
│   ├── agent.rs             # Agent core (main loop)
│   ├── llm_client.rs        # LLM API client trait and implementations
│   ├── container.rs         # Container management (bubblewrap + orchestrator)
│   ├── types.rs             # Semantic types (SessionId, TokenUsage, etc.)
│   └── persistence.rs       # Low-level file I/O for sessions
└── Cargo.toml
```

## Related Documents

- [Overview](overview.md) - High-level purpose and responsibilities
- [Type System](types.md) - Semantic types and design rationale
- [Sandboxing](sandboxing.md) - Container security model
- [Context Management](context-management.md) - How context is tracked
- [Cost Control](cost-control.md) - Token tracking and budgets
