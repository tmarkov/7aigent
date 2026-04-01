# Orchestrator Architecture

The orchestrator is a Python process that provides command execution environments for the agent. It runs inside the sandbox and handles all tool execution.

## Purpose

The orchestrator mediates between the agent and execution environments:

- Receives commands via stdin (JSON protocol)
- Routes commands to appropriate environments
- Returns results via stdout (JSON protocol)
- Maintains persistent state across commands
- Renders current state as "screen" for the LLM

## Architecture Principles

### Synchronous Execution

Commands run one at a time, sequentially. This design choice:

- Simplifies state management (no race conditions)
- Matches how humans use REPLs
- Makes debugging straightforward

**Trade-off**: Long-running commands block everything. The agent must be careful with infinite loops. Future versions may allow killing environments.

### Independent Environments

Each environment maintains its own state:

- **Bash**: Working directory, environment variables, history
- **Python**: REPL variables, imports
- **Editor**: Open file views

Environments don't communicate directly—they coordinate only through the filesystem. This isolation:

- Prevents cascading failures
- Makes each environment testable in isolation
- Allows adding new environments without modifying existing ones

### Graceful Degradation

Errors don't crash the system; they inform:

- Unknown environment → error response with available environments
- Invalid command → error with help text
- Timeout → partial output with timeout indication

This ensures the agent always receives useful feedback.

## Key Requirements

The design was driven by concrete scenarios:

- **Long-running commands**: Compilation, training, service startup
- **Multi-language coordination**: C + Python, bash + Python
- **Large outputs**: Profiling data, logs, visualizations
- **Persistent state**: Variables, working directory, open files
- **File operations**: Edit, create, search across codebase
- **Background processes**: Services, streaming logs

## Related Files

- `orchestrator/main.py` - Main entry point and interaction loop
- `orchestrator/executor.py` - Command routing and execution
- `orchestrator/screen.py` - Screen collection and aggregation
- `orchestrator/loader.py` - Environment loading and validation
- `docs/design/orchestrator/protocol.md` - Communication protocol rationale
- `docs/design/orchestrator/environments/` - Individual environment designs
