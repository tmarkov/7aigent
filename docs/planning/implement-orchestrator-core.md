# Description

Implement the orchestrator core that manages environments, routes commands, and handles communication with the agent.

# Plan

- [ ] Implement communication.py module
  - [ ] Implement read_message() for NDJSON parsing
  - [ ] Implement send_response() for NDJSON serialization
  - [ ] Implement send_error_response()
  - [ ] Handle EOF and parse errors

- [ ] Implement loader.py module
  - [ ] Implement load_all_environments()
  - [ ] Load built-in environments (bash, python, editor)
  - [ ] Load ad-hoc environments from env/ directory
  - [ ] Implement find_environment_class()
  - [ ] Implement validate_environment_class()
  - [ ] Handle validation errors with diagnostics

- [ ] Implement executor.py module
  - [ ] Implement execute_command()
  - [ ] Route commands to appropriate environment
  - [ ] Handle unknown environment errors
  - [ ] Catch and report environment exceptions

- [ ] Implement screen.py module
  - [ ] Implement collect_screen_updates()
  - [ ] Call get_screen() on all environments
  - [ ] Handle get_screen() exceptions
  - [ ] Aggregate into Screen object
  - [ ] Apply max_lines truncation

- [ ] Implement main.py module
  - [ ] Implement main() entry point
  - [ ] Main interaction loop
  - [ ] Load environments on startup
  - [ ] Read commands from stdin
  - [ ] Execute and collect screen
  - [ ] Send responses to stdout
  - [ ] Handle EOF for shutdown
  - [ ] Implement shutdown_all_environments()

- [ ] Write tests
  - [ ] Test message parsing and serialization
  - [ ] Test environment loading and validation
  - [ ] Test command routing
  - [ ] Test screen aggregation
  - [ ] Test error handling at each layer
  - [ ] Test shutdown sequence

- [ ] Create test ad-hoc environment
  - [ ] Implement simple timer environment for testing
  - [ ] Test ad-hoc environment loading

- [ ] Integration testing
  - [ ] Test full orchestrator with all environments
  - [ ] Test stdin/stdout communication
  - [ ] Test error cases end-to-end

- [ ] Run formatters and linters

# Dependencies

- Requires: All environments implemented (bash, python, editor)
- Requires: Orchestrator types

# Outcome

A complete orchestrator that can load environments, route commands, and communicate with the agent.
