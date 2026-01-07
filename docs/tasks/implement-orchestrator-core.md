# Description

Implement the full orchestrator core with environment loading, multiple environment support, and screen aggregation. This builds on the minimal orchestrator (which only supports bash) to add the complete environment management system.

# Plan

- [x] Extend communication.py module (if needed)
  - Note: Basic NDJSON communication already done in minimal orchestrator
  - [x] Add any additional message types if needed
  - Result: No changes needed - existing implementation is sufficient

- [x] Implement loader.py module
  - [x] Implement load_all_environments()
  - [x] Load built-in environments (bash, python, editor)
  - [x] Load ad-hoc environments from env/ directory
  - [x] Implement find_environment_class()
  - [x] Implement validate_environment_class()
  - [x] Handle validation errors with diagnostics

- [x] Extend executor.py module
  - Note: Minimal version routes to bash only
  - [x] Update to route to any loaded environment
  - [x] Support multiple environments simultaneously
  - Result: No changes needed - already supports multiple environments via mapping

- [x] Extend screen.py module
  - Note: Minimal version collects from bash only
  - [x] Update to call get_screen() on ALL environments
  - [x] Aggregate screens from multiple environments
  - [x] Apply max_lines truncation across all screens
  - Result: No changes needed - already supports multiple environments via mapping

- [x] Extend main.py module
  - Note: Minimal version hardcodes bash environment
  - [x] Replace hardcoded bash with loader
  - [x] Load all built-in environments on startup
  - [x] Load ad-hoc environments from env/ directory
  - [x] Update shutdown to handle all environments
  - Result: Shutdown already iterates over all environments in mapping

- [x] Write tests
  - [x] Test message parsing and serialization
  - [x] Test environment loading and validation
  - [x] Test command routing
  - [x] Test screen aggregation
  - [x] Test error handling at each layer
  - [x] Test shutdown sequence
  - Result: 155 tests pass, including 8 new loader tests

- [x] Create test ad-hoc environment
  - [x] Implement simple timer environment for testing
  - [x] Test ad-hoc environment loading
  - Result: Timer environment in env/timer.py successfully loaded

- [x] Integration testing
  - [x] Test full orchestrator with all environments
  - [x] Test stdin/stdout communication
  - [x] Test error cases end-to-end
  - Result: test_manual.py confirms all environments work correctly

- [x] Run formatters and linters
  - Result: All checks pass (black, isort, ruff, pytest)

# Dependencies

- Requires: Minimal orchestrator (implement-minimal-orchestrator.md)
- Requires: All environments implemented (bash, python, editor)
- Requires: Orchestrator types

# Outcome

A complete orchestrator that can load environments, route commands, and communicate with the agent.
