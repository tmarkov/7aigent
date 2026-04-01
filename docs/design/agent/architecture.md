# Agent Architecture

This document describes the high-level architecture of the agent and how components interact.

## Overview

The agent is a Rust binary that runs on the host machine (outside the container). It:
- Manages user interaction via CLI
- Constructs prompts and calls LLM APIs
- Spawns and manages containerized orchestrator
- Maintains conversation history and state
- Tracks costs and enforces budgets
- Persists sessions for resumability

**Key design principle**: The agent handles the "intelligence" layer (LLM interaction, planning, cost management) while delegating tool execution to the orchestrator.

## Separation of Concerns

**Agent handles:**
- LLM communication (prompts, responses, tool calls)
- Session persistence (save/resume)
- Cost tracking and budgets
- Configuration management

**Orchestrator handles:**
- Command execution (bash, python, editor)
- Environment state (REPL variables, file views)
- Output formatting (screen rendering)

This separation allows:
- Agent to be language-agnostic (could support multiple LLMs)
- Orchestrator to be swapped (different language implementations)
- Clean protocol boundary (JSON over stdin/stdout)

## High-Level Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  Agent (Rust binary, runs on host)                          │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   CLI        │  │  Session     │  │  Config      │      │
│  │   Interface  │  │  (save/load) │  │  Loader      │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│         │                  │                  │              │
│         └──────────────────┼──────────────────┘              │
│                            │                                 │
│                    ┌───────▼────────┐                        │
│                    │  Agent Core    │                        │
│                    │  (Main Loop)   │                        │
│                    └───────┬────────┘                        │
│                            │                                 │
│      ┌─────────────────────┼─────────────────────┐          │
│      │                     │                     │          │
│  ┌───▼────────┐   ┌────────▼─────────┐  ┌───────▼──────┐  │
│  │  LLM       │   │  Container       │  │  History &   │  │
│  │  Client    │   │  Manager         │  │  Context     │  │
│  └────────────┘   └──────────────────┘  └──────────────┘  │
│                            │                                 │
└────────────────────────────┼─────────────────────────────────┘
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
| **LLM Client** | API communication, response parsing |
| **Container Manager** | Spawn sandbox, communicate with orchestrator |
| **History & Context** | Manage conversation, truncate for context limits |

## Responsibilities by Layer

### Intelligence Layer
- Send prompts to LLM (Claude, OpenAI, etc.)
- Parse LLM responses for tool calls
- Decide when task is complete

### Orchestration
- Spawn orchestrator in sandbox
- Send commands via stdin
- Receive results via stdout
- Manage orchestrator lifecycle

### State Management
- Persist full conversation history
- Save and resume sessions
- Track screen state across turns
- Maintain cost data

### Security
- Container isolation via bubblewrap
- Validate configuration
- Enforce resource limits

## Related Documents

- [Context Management](context-management.md) - How context is tracked and truncated
- [Cost Control](cost-control.md) - Token tracking and budgets
- [Sandboxing](sandboxing.md) - Security and isolation model
- [Sandbox Design](../sandbox/) - Complete sandbox implementation details
