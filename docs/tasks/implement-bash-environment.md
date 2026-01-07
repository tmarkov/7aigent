# Description

Implement the bash environment, which provides a persistent bash shell for executing commands. This is the simplest environment and validates our implementation approach.

# Plan

- [x] Implement BashEnvironment class
  - [x] Set up pexpect spawn with bash
  - [x] Configure unique prompt marker for reliable detection
  - [x] Implement handle_command() method
  - [x] Implement get_screen() method
  - [x] Implement shutdown() method
  - [x] Track working directory, exit code, background jobs

- [x] Handle edge cases
  - [x] Large output truncation (10MB limit)
  - [x] Prompt detection reliability
  - [x] Command timeout handling (per refined design)

- [x] Write tests
  - [x] Test basic command execution
  - [x] Test working directory tracking
  - [x] Test exit code tracking
  - [x] Test background job display
  - [x] Test large output truncation
  - [x] Test shutdown cleanup

- [x] Manual testing
  - [x] Test interactive workflow with various commands
  - [x] Test cd command updates working directory
  - [x] Test background jobs (&)
  - [x] Test error handling

- [x] Documentation
  - [x] Add usage examples
  - [x] Document limitations

- [x] Run formatters and linters

# Dependencies

- Requires: Orchestrator types (implement-orchestrator-types.md)

# Outcome

A working bash environment that can execute shell commands and maintain state across invocations.
