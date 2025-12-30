# Description

Implement the core type system for the orchestrator in Python. This provides the foundation for all environment implementations and the orchestrator itself.

# Plan

- [x] Create orchestrator/core_types.py module (renamed from types.py to avoid stdlib conflict)
  - [x] Implement EnvironmentName dataclass with validation
  - [x] Implement CommandText dataclass
  - [x] Implement CommandResponse dataclass
  - [x] Implement ScreenSection dataclass with validation
  - [x] Add comprehensive docstrings

- [x] Create orchestrator/protocol.py module
  - [x] Define Environment Protocol
  - [x] Document protocol requirements
  - [x] Add usage examples in docstrings

- [x] Write property-based tests
  - [x] Test EnvironmentName validation (valid/invalid identifiers)
  - [x] Test CommandResponse creation
  - [x] Test ScreenSection validation
  - [x] Test immutability of frozen dataclasses

- [x] Write example-based tests
  - [x] Test edge cases for type validation
  - [x] Test error messages are descriptive

- [x] Run formatters and linters
  - [x] black formatting
  - [x] ruff linting
  - [x] Ensure all tests pass

# Dependencies

None - this is the foundation task

# Outcome

A complete, well-tested type system that serves as the foundation for implementing environments and the orchestrator.

**Note**: The module was named `core_types.py` instead of `types.py` to avoid shadowing Python's standard library `types` module, which was causing import failures.
