# Description

Implement the full orchestrator core with environment loading, multiple environment support, and screen aggregation. This builds on the minimal orchestrator (which only supports bash) to add the complete environment management system.

# Plan

- [ ] Extend communication.py module (if needed)
  - Note: Basic NDJSON communication already done in minimal orchestrator
  - [ ] Add any additional message types if needed

- [ ] Implement loader.py module
  - [ ] Implement load_all_environments()
  - [ ] Load built-in environments (bash, python, editor)
  - [ ] Load ad-hoc environments from env/ directory
  - [ ] Implement find_environment_class()
  - [ ] Implement validate_environment_class()
  - [ ] Handle validation errors with diagnostics

- [ ] Extend executor.py module
  - Note: Minimal version routes to bash only
  - [ ] Update to route to any loaded environment
  - [ ] Support multiple environments simultaneously

- [ ] Extend screen.py module
  - Note: Minimal version collects from bash only
  - [ ] Update to call get_screen() on ALL environments
  - [ ] Aggregate screens from multiple environments
  - [ ] Apply max_lines truncation across all screens

- [ ] Extend main.py module
  - Note: Minimal version hardcodes bash environment
  - [ ] Replace hardcoded bash with loader
  - [ ] Load all built-in environments on startup
  - [ ] Load ad-hoc environments from env/ directory
  - [ ] Update shutdown to handle all environments

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

- Requires: Minimal orchestrator (implement-minimal-orchestrator.md)
- Requires: All environments implemented (bash, python, editor)
- Requires: Orchestrator types

# Outcome

A complete orchestrator that can load environments, route commands, and communicate with the agent.
