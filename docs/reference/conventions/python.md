# Python Conventions

This document defines coding conventions for Python code in the 7aigent project (the orchestrator and environments).

## Core Principles

1. **Mandatory type hints**: All function signatures must have complete type annotations
2. **No primitive obsession**: Define semantic types instead of using primitives directly
3. **Prefer immutable**: Use frozen dataclasses and immutable collections by default
4. **Thorough testing**: Property-based testing for public APIs, specific examples for edge cases
5. **Explicit over implicit**: Make behavior clear and obvious

## Type System

### Semantic Types Over Primitives

Define new types for each semantically different use case using dataclasses:

```python
from dataclasses import dataclass

# Good: Semantic types with validation
@dataclass(frozen=True)
class EnvironmentName:
    value: str

    def __post_init__(self):
        if not self.value.isidentifier():
            raise ValueError(f"Invalid environment name: {self.value}")

@dataclass(frozen=True)
class CommandText:
    value: str

# Bad: Primitive obsession
def execute_command(env: str, cmd: str) -> str:
    ...

# Good: Clear semantics
def execute_command(env: EnvironmentName, cmd: CommandText) -> CommandResponse:
    ...
```

### Immutability

**Default to immutable data structures:**

```python
from dataclasses import dataclass
from typing import Mapping, Sequence
import types

# Use frozen dataclasses
@dataclass(frozen=True)
class CommandResponse:
    output: str
    exit_code: int
    timestamp: datetime

# Use immutable collection types in signatures
@dataclass(frozen=True)
class ScreenState:
    sections: Mapping[EnvironmentName, ScreenSection]

    @staticmethod
    def create(sections: dict) -> 'ScreenState':
        """Create with immutable sections mapping"""
        return ScreenState(sections=types.MappingProxyType(sections))

# Use Sequence instead of list for immutable collections
def process_commands(commands: Sequence[CommandText]) -> None:
    ...
```

**Exceptions to immutability:**
- Environment classes are stateful and mutable by design
- Internal buffers and caches where performance is critical
- Mark mutable classes clearly in documentation

```python
class BashEnvironment:
    """
    Stateful environment managing a bash process.

    Note: This class is mutable and maintains state across commands.
    """

    def __init__(self):
        self._process = None
        self._current_directory = Path.cwd()
```

### Type Hints Requirements

```python
from typing import Protocol, runtime_checkable

# All function signatures must have complete type hints
def handle_command(cmd: CommandText) -> CommandResponse:
    """Execute a command and return response"""
    ...

# Use Protocol for defining contracts
@runtime_checkable
class Environment(Protocol):
    def handle_command(self, cmd: CommandText) -> CommandResponse: ...
    def get_screen(self) -> ScreenSection: ...

# Generic types where appropriate
from typing import TypeVar, Generic

T = TypeVar('T')

@dataclass(frozen=True)
class Result(Generic[T]):
    value: T | None
    error: str | None
```

## Code Organization

### Explicit Over Implicit

```python
# No wildcard imports
# Bad:
from typing import *

# Good:
from typing import Protocol, Mapping, Sequence

# Explicit return types even when obvious
# Bad:
def get_name():
    return self._name

# Good:
def get_name(self) -> EnvironmentName:
    return self._name

# No monkey patching
# Bad:
module.new_attribute = some_function

# Good: Wrap or extend properly
class ExtendedModule:
    def __init__(self, module):
        self._module = module

    def new_method(self):
        ...
```

### Error Handling

```python
# Define custom exception classes
class EnvironmentError(Exception):
    """Base exception for environment-related errors"""
    pass

class EnvironmentValidationError(EnvironmentError):
    """Environment module failed validation"""

    def __init__(self, module_name: str, errors: Sequence[str]):
        self.module_name = module_name
        self.errors = errors
        super().__init__(
            f"Environment '{module_name}' validation failed: {', '.join(errors)}"
        )

# Include context in error messages
# Bad:
raise ValueError("Invalid name")

# Good:
raise ValueError(f"Invalid environment name '{name}': must be a valid identifier")

# Document exceptions in docstrings
def load_environment(name: EnvironmentName) -> Environment:
    """
    Load and validate an environment module.

    Args:
        name: The name of the environment to load

    Returns:
        The loaded and validated environment

    Raises:
        EnvironmentNotFoundError: If module doesn't exist
        EnvironmentValidationError: If module fails validation
        ImportError: If module has import errors
    """
    ...
```

### Documentation

```python
def process_command(
    env: EnvironmentName,
    cmd: CommandText
) -> CommandResponse:
    """
    Execute a command in the specified environment.

    This function routes the command to the appropriate environment,
    waits for execution, and returns the response including output
    and exit code.

    Args:
        env: The environment in which to execute the command
        cmd: The command text to execute

    Returns:
        The response from executing the command, including output
        and exit code

    Raises:
        EnvironmentNotFoundError: If the environment doesn't exist
        CommandExecutionError: If the command fails to execute

    Example:
        >>> env = EnvironmentName("bash")
        >>> cmd = CommandText("echo hello")
        >>> response = process_command(env, cmd)
        >>> response.output
        'hello\\n'
    """
    ...
```

**Documentation requirements:**
- All public functions and classes must have docstrings
- Type hints document types, docstrings document behavior and usage
- Include examples in docstrings for complex or non-obvious APIs
- Document side effects, exceptions, and assumptions

### Module Structure

```python
# Standard import order (enforced by isort):
# 1. Standard library imports
import types
from dataclasses import dataclass
from pathlib import Path

# 2. Third-party imports
import pexpect
from typing import Protocol, Mapping

# 3. Local imports
from .types import EnvironmentName, CommandText
from .validation import validate_environment

# One primary class per file for complex classes
# File: orchestrator/environments/bash_environment.py
class BashEnvironment:
    """Implementation of bash environment"""
    ...

# Multiple related classes can share a file if they're small
# File: orchestrator/types.py
@dataclass(frozen=True)
class EnvironmentName:
    ...

@dataclass(frozen=True)
class CommandText:
    ...
```

## Tooling

**Formatting:**
- `black` with default configuration (88 character line length)
- `isort` for import sorting with black-compatible settings
- Run on all code before commits

**Linting:**
- `ruff` for fast, comprehensive linting
- Enable strict type checking in development

**Type Checking:**
- Runtime validation using `typing.Protocol` and introspection
- Optional: Use `mypy` or `pyright` in development for static checking

## Related Files

- [General Conventions](./general.md) - Project-wide conventions
- [Rust Conventions](./rust.md) - Rust-specific style guidelines
- [Testing](../testing.md) - Testing strategy and guidelines
