# Description

Implement the Python REPL environment, which provides a persistent Python interpreter for executing code. This is more complex than bash due to namespace management and variable tracking.

# Plan

- [x] Implement PythonEnvironment class
  - [x] Set up pexpect spawn with Python REPL
  - [x] Configure reliable prompt detection
  - [x] Implement handle_command() method
  - [x] Implement get_screen() method
  - [x] Implement shutdown() method
  - [x] Track namespace and working directory

- [x] Implement variable tracking
  - [x] Implement regex-based variable usage detection
  - [x] Track variable usage ordering
  - [x] Implement get_type_name() helper
  - [x] Filter private variables and modules
  - [x] Limit display to 100 variables

- [x] Handle multi-line code
  - [x] Implement multi-line command handling (blank line termination)
  - [x] Test with function definitions
  - [x] Test with class definitions

- [x] Handle edge cases
  - [x] SyntaxError handling
  - [x] Exception traceback display
  - [x] Handle infinite loops (per timeout design - no timeout, matches bash)
  - [x] Document memory management responsibility

- [x] Write tests
  - [x] Test basic expression evaluation
  - [x] Test variable persistence
  - [x] Test variable tracking and display
  - [x] Test multi-line code execution
  - [x] Test exception handling
  - [x] Test namespace introspection

- [ ] Manual testing
  - [ ] Test data analysis workflow (pandas)
  - [ ] Test plot generation (matplotlib)
  - [ ] Test variable tracking with complex objects

- [x] Run formatters and linters

# Dependencies

- Requires: Orchestrator types (implement-orchestrator-types.md)
- Requires: Refined design with multi-line protocol specified

# Outcome

A working Python REPL environment that maintains namespace state and tracks variables across commands.
