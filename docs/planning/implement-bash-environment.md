# Description

Implement the bash environment, which provides a persistent bash shell for executing commands. This is the simplest environment and validates our implementation approach.

# Plan

- [ ] Implement BashEnvironment class
  - [ ] Set up pexpect spawn with bash
  - [ ] Configure unique prompt marker for reliable detection
  - [ ] Implement handle_command() method
  - [ ] Implement get_screen() method
  - [ ] Implement shutdown() method
  - [ ] Track working directory, exit code, background jobs

- [ ] Handle edge cases
  - [ ] Large output truncation (10MB limit)
  - [ ] Prompt detection reliability
  - [ ] Command timeout handling (per refined design)

- [ ] Write tests
  - [ ] Test basic command execution
  - [ ] Test working directory tracking
  - [ ] Test exit code tracking
  - [ ] Test background job display
  - [ ] Test large output truncation
  - [ ] Test shutdown cleanup

- [ ] Manual testing
  - [ ] Test interactive workflow with various commands
  - [ ] Test cd command updates working directory
  - [ ] Test background jobs (&)
  - [ ] Test error handling

- [ ] Documentation
  - [ ] Add usage examples
  - [ ] Document limitations

- [ ] Run formatters and linters

# Dependencies

- Requires: Orchestrator types (implement-orchestrator-types.md)

# Outcome

A working bash environment that can execute shell commands and maintain state across invocations.
