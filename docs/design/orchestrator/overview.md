# Orchestrator Overview

The orchestrator is a Python tool that provides command execution environments for the agent. It runs inside the sandbox and handles all tool execution.

## Purpose

The orchestrator:
- Receives commands via stdin (JSON protocol)
- Executes commands in appropriate environments (bash, python, editor)
- Returns results via stdout (JSON protocol)
- Maintains persistent state across commands
- Renders current state as "screen" for LLM

## Responsibilities

### Environment Management
- Load and initialize environments (bash, python, editor, custom)
- Route commands to correct environment
- Maintain environment state (REPL variables, file views, etc.)

### Command Execution
- Execute commands synchronously
- Capture output (stdout, stderr)
- Enforce timeouts
- Handle errors gracefully

### State Rendering
- Generate "screen" showing current state of all environments
- Truncate output to reasonable size
- Format for LLM readability

## Use Cases

This design is driven by concrete scenarios:

### Example Scenarios

1. **C + Python iterative optimization**: Compile C program, run it to generate data, analyze in Python, iterate
2. **Story editing**: Edit markdown files, improve grammar and coherence
3. **Crash debugging**: Investigate crashed program, analyze state
4. **Large codebase refactoring**: Rename functions across many files, run tests
5. **Data visualization**: Load data, create plots, iterate on presentation
6. **Performance profiling**: Profile code, identify bottlenecks, optimize

### Key Requirements Derived

From these scenarios, we identified critical requirements:

- **Long-running commands**: Compilation, training, service startup
- **Multi-language coordination**: C + Python, bash + Python
- **Large outputs**: Profiling data, logs, visualizations
- **Persistent state**: Variables, working directory, open files
- **File operations**: Edit, create, search across codebase
- **Background processes**: Services, streaming logs

## Architecture Principles

**Synchronous execution**: Commands run one at a time, sequentially
- Simplifies state management
- Matches how humans use REPL
- No race conditions

**Independent environments**: Each environment has its own state
- Bash: Working directory, env vars, history
- Python: REPL variables, imports
- Editor: Open file views
- No inter-environment communication (only through filesystem)

**Graceful degradation**: Errors don't crash, they inform
- Unknown environment → error response with available environments
- Invalid command → error with help text
- Timeout → partial output with timeout indication

## Related Documents

- [Architecture](architecture.md) - Component structure and data flow
- [Environments](environments.md) - Environment contract and built-ins
- [Bash Environment](bash-environment.md) - Shell command execution
- [Python Environment](python-environment.md) - Persistent REPL
- [Editor Environment](editor-environment-v2.md) - Query-based file viewing and editing
