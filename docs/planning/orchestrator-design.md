# Description

Design the orchestrator, built-in environments (bash, python, editor), and the environment contract. This design should be use-case driven: start with concrete examples of what the built-in environments need to support, then determine how they should work, and finally derive the orchestrator architecture and environment contract that best accommodates them.

# Plan

- [x] Identify concrete use cases for the bash environment
- [x] Identify concrete use cases for the python environment
- [x] Identify concrete use cases for the editor environment
- [x] Design how each environment should work to support its use cases
- [x] Define the environment contract (interface/protocol)
- [x] Design the orchestrator architecture
- [x] Document the complete design

# Outcome

The complete design has been documented in [docs/orchestrator.md](../orchestrator.md). After review and iteration, the design includes:

- 12 diverse use-case scenarios that drove the design decisions
- Detailed designs for bash, python, and editor environments
- Environment contract (Protocol) with class-based implementation for both built-in and ad-hoc environments
- Interactive program helper base class for wrapping programs like GDB
- Orchestrator architecture with all components
- Agent-Orchestrator communication protocol (NDJSON over stdin/stdout)
- Design rationale explaining key decisions and alternatives considered

Key design principles:
- **Synchronous environments**: Simplicity over async complexity
- **File-based output**: For large/visual data (plots, profiling)
- **Line-based editor**: No LSP initially (deferred to future)
- **Explicit state management**: No automatic rollback
- **Class-based environments**: Both built-in and ad-hoc use same contract
- **No timeouts**: Agent must be careful; future may allow killing environment
- **Minimal screen clutter**: Unused environments show only description
- **Multi-line commands**: First line is command, rest is content (for editor)
- **Working directories**: Python has own cwd, shown on screen to avoid confusion
- **Variable display**: Dict iteration order (no modification time tracking)
