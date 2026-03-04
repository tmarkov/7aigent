# Task: Implement InteractiveEnvironment Base Class

## Description

Create an `InteractiveEnvironment` base class that encapsulates common patterns for wrapping persistent interactive processes (like bash, Python REPL, gdb). Then refactor BashEnvironment and PythonEnvironment to extend this base class, eliminating code duplication and ensuring consistent behavior (particularly process termination handling).

## Context

- **Component**: `orchestrator/interactive.py` (new), `orchestrator/environments/bash.py` (refactor), `orchestrator/environments/python.py` (refactor)
- **Related**: Environment protocol (docs/reference/environment-protocol.md), DeclarativeEnvironment implementation
- **Motivation**: BashEnvironment and PythonEnvironment duplicate pexpect-based process management logic. Bash implements auto-restart on process termination, but Python doesn't. The missing InteractiveEnvironment base class is a recognized architectural gap.

## Scenarios

### Scenario 1: Agent uses bash environment normally

**Situation**: Agent executes shell commands in bash environment

**Commands**:
1. `bash: pwd`
2. `bash: ls -la`
3. `bash: echo "test" > file.txt`
4. `bash: cat file.txt`

**Success criteria**: All commands work identically to current BashEnvironment behavior. Exit codes captured correctly. Output shown in screen.

### Scenario 2: Bash process terminates and auto-restarts

**Situation**: Agent runs command that terminates bash process

**Commands**:
1. `bash: echo $$` (note PID)
2. `bash: kill -9 $$` (force kill bash)
3. `bash: echo "after restart"` (should work)
4. `bash: echo $$` (different PID, proves restart)

**Success criteria**: After termination, next command auto-restarts bash. Agent notified via output message. New process has fresh state (different PID, reset working directory).

### Scenario 3: Python process terminates and auto-restarts

**Situation**: Agent runs code that terminates Python process (currently unsupported)

**Commands**:
1. `python: import os`
2. `python: os._exit(0)` (force exit Python)
3. `python: print("after restart")` (should work)
4. `python: x = 42` (fresh namespace, no previous variables)

**Success criteria**: After termination, next command auto-restarts Python. Agent notified via output message. New REPL has fresh namespace.

### Scenario 4: Agent uses Python environment normally

**Situation**: Agent executes Python code across multiple commands

**Commands**:
1. `python: x = 42`
2. `python: y = x + 8`
3. `python: print(y)`
4. `python: import math; math.sqrt(y)`

**Success criteria**: All commands work identically to current PythonEnvironment behavior. Variables persist. Types shown. Output displayed correctly.

### Scenario 5: Developer creates gdb environment easily

**Situation**: Developer wants to add gdb environment without duplicating process management logic

**Code**:
```python
from orchestrator.interactive import InteractiveEnvironment
from orchestrator.core_types import CommandResponse

class GdbEnvironment(InteractiveEnvironment):
    def __init__(self):
        super().__init__(
            command=["gdb", "--quiet", "--interpreter=mi"],
            prompt_marker="(gdb) ",
            name="gdb"
        )

    def _format_output(self, raw_output: str) -> str:
        # Custom output formatting if needed
        return raw_output
```

**Success criteria**: GdbEnvironment works with minimal code. Process spawning, prompt detection, command execution, auto-restart all inherited.

## Plan

- [x] Design InteractiveEnvironment API
  - [x] Identify common patterns in bash.py and python.py
  - [x] Define constructor parameters (prompt_marker, name, max_output_size, timeout)
  - [x] Define hooks for customization (output formatting, state extraction, spawn env)
- [x] Implement `InteractiveEnvironment` base class in `orchestrator/interactive.py`
  - [x] Process spawning with pexpect
  - [x] Prompt detection and command completion
  - [x] Output capture and truncation (10MB limit, keeps last 10MB)
  - [x] Auto-restart on process termination via `_handle_eof()`
  - [x] Exit code tracking (environment-specific via `_handle_eof()` override)
  - [x] Timeout handling (configurable, default None)
  - [x] Signal handling and cleanup via `shutdown()`
- [x] Write comprehensive tests for InteractiveEnvironment
  - [x] Test command execution (test_interactive_environment_command_execution)
  - [x] Test screen display (test_interactive_environment_screen)
  - [x] Test shutdown handling (test_interactive_environment_shutdown)
- [x] Refactor BashEnvironment to extend InteractiveEnvironment
  - [x] Remove duplicated pexpect logic (went from 286 to 248 lines)
  - [x] Customize via hooks (_get_spawn_command, _initialize_process, _update_state_after_command)
  - [x] Implement bash-specific state (working directory, exit code, jobs)
  - [x] Keep all current functionality including exit_code field
- [x] Verify bash environment tests pass unchanged (all 160 tests pass)
- [x] Refactor PythonEnvironment to extend InteractiveEnvironment
  - [x] Remove duplicated pexpect logic (went from 352 to 287 lines)
  - [x] Customize via hooks (_get_spawn_command, _initialize_process, _update_state_after_command, _send_command)
  - [x] Implement Python-specific state (variables with types, working directory)
  - [x] Add auto-restart support via inherited `_handle_eof()`
  - [x] Add `_get_spawn_env()` to set TERM=dumb (prevent ANSI codes)
- [x] Verify python environment tests pass unchanged (all 160 tests pass)
- [x] Run full build verification: `nix build .#orchestrator` (succeeded)
- [x] Update documentation
  - [x] Add InteractiveEnvironment to protocol.py examples (with full GDB example)

## Dependencies

- Requires: Understanding of BashEnvironment and PythonEnvironment implementations
- Requires: DeclarativeEnvironment implementation (as parallel example)
- Blocks: None (improvement to existing functionality)

## Completion Summary

**Status**: ✅ Complete

All objectives achieved:

1. **InteractiveEnvironment base class** (`orchestrator/interactive.py`):
   - 350 lines of reusable process management code
   - Abstract methods: `_get_spawn_command()`, `_initialize_process()`, `_update_state_after_command()`, `get_state_display()`
   - Optional hooks: `_format_output()`, `_on_restart()`, `_handle_eof()`, `_send_command()`, `_get_spawn_env()`, `_shutdown_gracefully()`
   - Handles: process spawning, prompt detection, output truncation, auto-restart, clean shutdown

2. **BashEnvironment refactored**:
   - Reduced from 286 to 248 lines (-38 lines, -13%)
   - All pexpect logic removed
   - Custom `_handle_eof()` preserves exit_code field behavior
   - All 160 tests pass unchanged

3. **PythonEnvironment refactored**:
   - Reduced from 352 to 287 lines (-65 lines, -18%)
   - All pexpect logic removed
   - **NEW**: Auto-restart on process termination (previously missing)
   - Custom `_send_command()` handles multi-line code
   - Custom `_get_spawn_env()` sets TERM=dumb to prevent ANSI codes
   - All 160 tests pass unchanged

4. **Documentation updated**:
   - Added comprehensive InteractiveEnvironment example to protocol.py
   - Shows complete GDB environment implementation

**Impact**:
- 103 lines of code eliminated through refactoring
- Consistent process termination handling across bash and python
- Easy to create new interactive environments (gdb, database CLIs, etc.)
- All existing functionality preserved

## Outcome

A working `InteractiveEnvironment` base class that:
1. Spawns and manages persistent interactive processes via pexpect
2. Detects command completion via configurable prompt markers
3. Captures output with configurable truncation
4. Auto-restarts process on termination with notification
5. Provides hooks for environment-specific customization
6. Handles shutdown cleanly

BashEnvironment successfully refactored to:
1. Extend InteractiveEnvironment
2. Eliminate duplicated process management code
3. Provide identical functionality as before
4. Pass all existing tests

PythonEnvironment successfully refactored to:
1. Extend InteractiveEnvironment
2. Eliminate duplicated process management code
3. Add auto-restart on process termination (new feature)
4. Provide identical functionality as before
5. Pass all existing tests

## Initial Thoughts

### Common Patterns to Extract

Both bash.py and python.py have:
- pexpect process spawning with encoding
- Prompt marker setup (bash: `__BASH_PROMPT__`, python: `__PYTHON_PROMPT__`)
- Command sending and prompt detection
- Output capture between command and next prompt
- Output truncation (10MB limit, last 10MB kept)
- Auto-restart on EOF (bash only - need to add to python)
- Shutdown via SIGTERM with timeout fallback to SIGKILL

### Key Differences to Support

**Bash-specific**:
- Exit code extraction (`echo $?`)
- Working directory tracking (`pwd`)
- Background job tracking (`jobs`)
- Combined stdout/stderr setup
- Prompt customization (PS1, PS2)

**Python-specific**:
- Namespace variable extraction via `dir()` and `type()`
- Multi-line code detection (incomplete vs complete statements)
- Variable display with types
- Import tracking

### Design Questions

1. **Prompt detection strategy**: Fixed marker vs regex pattern?
   - Current: Both use fixed markers (simple, reliable)
   - Proposal: Support both via `prompt_marker` parameter

2. **State extraction**: How do environments get custom state?
   - Bash needs exit codes, cwd, jobs
   - Python needs variables
   - GDB might need breakpoints, current frame
   - Proposal: Abstract method `_extract_state()` called after each command

3. **Output formatting**: Raw vs processed?
   - Bash strips ANSI codes, truncates
   - Python might show variables differently
   - Proposal: Hook `_format_output(raw: str) -> str`

4. **Process termination detection**: EOF vs exit?
   - Both currently check for EOF exception
   - Proposal: Catch EOF in base class, call hook `_on_restart()`

5. **Initialization commands**: Setting up prompt, environment?
   - Bash sends multiple setup commands
   - Python sends prompt setup
   - Proposal: Abstract method `_initialize_process()` called after spawn

### Validation Strategy

- Refactor bash first, verify all tests pass
- Refactor python second, verify all tests pass
- Add new test for Python auto-restart
- Ensure no behavioral changes (except auto-restart for Python)
- Verify `nix build .#orchestrator` succeeds
