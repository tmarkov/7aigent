# Agent Overview

The agent is a Rust binary that runs on the host machine (outside the container). It:
- Manages user interaction via CLI
- Constructs prompts and calls LLM APIs
- Spawns and manages containerized orchestrator
- Maintains conversation history and state
- Tracks costs and enforces budgets
- Persists sessions for resumability

**Key design principle**: The agent handles the "intelligence" layer (LLM interaction, planning, cost management) while delegating tool execution to the orchestrator.

## Responsibilities

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

## Related Documents

- [Architecture](architecture.md) - Component structure and data flow
- [Type System](types.md) - Semantic types used throughout
- [Sandboxing](sandboxing.md) - Security and isolation model
- [Context Management](context-management.md) - How context is tracked
- [Cost Control](cost-control.md) - Token tracking and budgets
