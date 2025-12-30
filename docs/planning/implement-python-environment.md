# Description

Implement the Python REPL environment, which provides a persistent Python interpreter for executing code. This is more complex than bash due to namespace management and variable tracking.

# Plan

- [ ] Implement PythonEnvironment class
  - [ ] Set up pexpect spawn with Python REPL
  - [ ] Configure reliable prompt detection
  - [ ] Implement handle_command() method
  - [ ] Implement get_screen() method
  - [ ] Implement shutdown() method
  - [ ] Track namespace and working directory

- [ ] Implement variable tracking
  - [ ] Implement simplified assignment detection (var = ...)
  - [ ] Track variable usage ordering
  - [ ] Implement get_type_name() helper
  - [ ] Filter private variables and modules
  - [ ] Limit display to 100 variables

- [ ] Handle multi-line code
  - [ ] Implement multi-line command parsing per refined protocol
  - [ ] Test with function definitions
  - [ ] Test with class definitions

- [ ] Handle edge cases
  - [ ] SyntaxError handling
  - [ ] Exception traceback display
  - [ ] Handle infinite loops (per timeout design)
  - [ ] Document memory management responsibility

- [ ] Write tests
  - [ ] Test basic expression evaluation
  - [ ] Test variable persistence
  - [ ] Test variable tracking and display
  - [ ] Test multi-line code execution
  - [ ] Test exception handling
  - [ ] Test namespace introspection

- [ ] Manual testing
  - [ ] Test data analysis workflow (pandas)
  - [ ] Test plot generation (matplotlib)
  - [ ] Test variable tracking with complex objects

- [ ] Run formatters and linters

# Dependencies

- Requires: Orchestrator types (implement-orchestrator-types.md)
- Requires: Refined design with multi-line protocol specified

# Outcome

A working Python REPL environment that maintains namespace state and tracks variables across commands.
