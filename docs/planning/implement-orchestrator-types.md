# Description

Implement the core type system for the orchestrator in Python. This provides the foundation for all environment implementations and the orchestrator itself.

# Plan

- [ ] Create orchestrator/types.py module
  - [ ] Implement EnvironmentName dataclass with validation
  - [ ] Implement CommandText dataclass
  - [ ] Implement CommandResponse dataclass
  - [ ] Implement ScreenSection dataclass with validation
  - [ ] Add comprehensive docstrings

- [ ] Create orchestrator/protocol.py module
  - [ ] Define Environment Protocol
  - [ ] Document protocol requirements
  - [ ] Add usage examples in docstrings

- [ ] Write property-based tests
  - [ ] Test EnvironmentName validation (valid/invalid identifiers)
  - [ ] Test CommandResponse creation
  - [ ] Test ScreenSection validation
  - [ ] Test immutability of frozen dataclasses

- [ ] Write example-based tests
  - [ ] Test edge cases for type validation
  - [ ] Test error messages are descriptive

- [ ] Run formatters and linters
  - [ ] black formatting
  - [ ] ruff linting
  - [ ] Ensure all tests pass

# Dependencies

None - this is the foundation task

# Outcome

A complete, well-tested type system that serves as the foundation for implementing environments and the orchestrator.
