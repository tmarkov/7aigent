# Bash Environment Design

The bash environment provides persistent shell command execution for file operations, build processes, and system interactions.

## Purpose

Execute shell commands, manage processes, handle file system operations. This is the primary environment for:
- Build/compilation tasks
- File system operations
- Git operations
- Running tests
- Starting background services

## Design Decisions

### Combined stdout/stderr

Output combines stdout and stderr into a single stream. This matches terminal behavior and is simpler than separate streams. Most users expect combined output, and separating them adds complexity without clear benefit.

### Background Jobs via Shell

Background jobs use the shell's job control (`&`, `jobs`), not orchestrator tracking. This leverages existing shell functionality rather than reimplementing process management.

**Trade-off**: Background jobs are managed by the shell, not the orchestrator. If the shell dies, background jobs die with it.

### Unique Prompt Marker

Use a special prompt marker (`<<<PROMPT>>>`) to reliably detect command completion. This avoids ambiguity when command output might contain the default prompt string.

### No Interactive Programs

Interactive programs like `gdb`, `vim`, etc. are not supported initially. These require different handling (see `InteractiveEnvironment` base class for wrapping such programs).

### Minimal Screen Until First Use

Before the first command, show only "Bash shell (ready)" to avoid clutter. The screen becomes useful after the agent starts using the environment.

## State Maintained

- Current working directory
- Environment variables (inherited, modified via `export`)
- Last exit code
- Background job list

## Edge Cases

- **Infinite commands**: Will block the system indefinitely. Agent must be careful. Future: allow agent to kill environment (losing state) or continue waiting.
- **Large output**: Truncate at 10MB, show warning
- **Prompt detection**: Use unique marker to avoid ambiguity

## Related Files

- `orchestrator/environments/bash.py` - Implementation
- `orchestrator/interactive.py` - Base class for process management
- `docs/design/orchestrator/protocol.md` - Communication protocol
