# Coding Style Guide

This document defines the coding conventions and style guidelines for the 7aigent project.

## Python (Orchestrator & Environments)

### Core Principles

1. **Mandatory type hints**: All function signatures must have complete type annotations
2. **No primitive obsession**: Define semantic types instead of using primitives directly
3. **Prefer immutable**: Use frozen dataclasses and immutable collections by default
4. **Thorough testing**: Property-based testing for public APIs, specific examples for edge cases
5. **Explicit over implicit**: Make behavior clear and obvious

### Type System

#### Semantic Types Over Primitives

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

#### Immutability

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

#### Type Hints Requirements

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

### Testing Strategy

#### Public API Testing

**Use Hypothesis for property-based testing of public APIs:**

```python
from hypothesis import given, strategies as st

@dataclass(frozen=True)
class EnvironmentName:
    value: str

    def __post_init__(self):
        if not self.value.isidentifier():
            raise ValueError(f"Invalid environment name")

# Property: Valid identifiers should create valid EnvironmentNames
@given(st.from_regex(r"[a-zA-Z_][a-zA-Z0-9_]*", fullmatch=True))
def test_valid_identifiers_accepted(identifier: str):
    name = EnvironmentName(identifier)
    assert name.value == identifier

# Property: Invalid identifiers should raise ValueError
@given(st.text().filter(lambda s: not s.isidentifier()))
def test_invalid_identifiers_rejected(invalid: str):
    with pytest.raises(ValueError):
        EnvironmentName(invalid)
```

**Use specific examples for corner cases and complex scenarios:**

```python
class TestEnvironmentValidation:
    """Test environment module validation with specific examples"""

    def test_missing_handle_command(self):
        """Module missing handle_command should fail validation"""
        module = types.ModuleType('test_env')
        module.get_screen = lambda: ScreenSection("")

        errors = validate_environment(module)
        assert "Missing required method: handle_command" in errors

    def test_wrong_signature_types(self):
        """handle_command with wrong parameter type should fail"""
        module = types.ModuleType('test_env')

        def handle_command(cmd: int) -> CommandResponse:  # Wrong type
            ...

        module.handle_command = handle_command
        module.get_screen = lambda: ScreenSection("")

        errors = validate_environment(module)
        assert any("cmd should be CommandText" in e for e in errors)

    def test_complete_valid_environment(self):
        """Complete valid environment should pass validation"""
        module = types.ModuleType('test_env')
        module.handle_command = lambda cmd: CommandResponse("", 0)
        module.get_screen = lambda: ScreenSection("")

        errors = validate_environment(module)
        assert errors == []
```

#### Testing Guidelines

- **Public API**: Must be thoroughly tested with both property-based and example tests
- **Private APIs**: Test if complex, well-defined, and stable; otherwise test through public API
- **Test organization**: Group related tests in classes, use descriptive names
- **Test independence**: Each test should be runnable in isolation
- **Fixtures**: Use pytest fixtures for common test setup

### Code Organization

#### Explicit Over Implicit

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

#### Error Handling

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

#### Documentation

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

#### Module Structure

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

### Tooling

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

## Rust (Agent)

### Core Principles

1. **Compile-time guarantees**: Leverage type system to prevent errors
2. **Explicit error handling**: No `.unwrap()` in production code
3. **Documentation**: Doc comments for all public APIs
4. **Idiomatic Rust**: Follow Rust conventions and best practices

### Style Guidelines

#### Type Safety

```rust
// Use type system to make invalid states unrepresentable
#[derive(Debug, Clone)]
pub struct ValidatedConfig {
    api_key: String,
    timeout: Duration,
}

impl ValidatedConfig {
    // Constructor validates, so struct always contains valid data
    pub fn new(api_key: String, timeout: Duration) -> Result<Self, ConfigError> {
        if api_key.is_empty() {
            return Err(ConfigError::EmptyApiKey);
        }
        Ok(Self { api_key, timeout })
    }
}

// Use newtypes for semantic distinction
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvironmentName(String);

#[derive(Debug, Clone)]
pub struct CommandText(String);
```

#### Error Handling

```rust
use thiserror::Error;

// Define specific error types with thiserror
#[derive(Error, Debug)]
pub enum LLMError {
    #[error("Rate limit exceeded")]
    RateLimit,

    #[error("Request timeout after {0:?}")]
    Timeout(Duration),

    #[error("Authentication failed: {0}")]
    AuthError(String),

    #[error("HTTP error: {0}")]
    HttpError(#[from] reqwest::Error),
}

// Pattern match on specific errors for different handling
async fn call_llm_with_retry(request: Request) -> Result<Response, LLMError> {
    match call_llm(request).await {
        Err(LLMError::RateLimit | LLMError::Timeout(_) | LLMError::ServerError) => {
            exponential_backoff_retry(request).await
        }
        Err(LLMError::AuthError(msg)) => {
            eprintln!("Authentication failed: {msg}");
            std::process::exit(1);
        }
        Ok(response) => Ok(response),
        Err(e) => Err(e),
    }
}

// Use ? for error propagation
pub async fn process_task(task: Task) -> Result<TaskResult, AgentError> {
    let response = call_llm(task.into_request()).await?;
    let command = parse_command(&response)?;
    let result = execute_command(command).await?;
    Ok(result)
}
```

#### Documentation

```rust
/// Execute a command in the orchestrator and wait for response.
///
/// This function sends the command to the orchestrator via stdin,
/// then reads the response from stdout. It handles serialization
/// and deserialization of messages.
///
/// # Arguments
///
/// * `command` - The command to execute
///
/// # Returns
///
/// The response from the orchestrator
///
/// # Errors
///
/// Returns `OrchestratorError::EOF` if orchestrator process died
/// Returns `OrchestratorError::ParseError` if response is invalid
///
/// # Example
///
/// ```
/// let cmd = Command::new(EnvironmentName("bash"), CommandText("ls"));
/// let response = execute_command(cmd).await?;
/// ```
pub async fn execute_command(command: Command) -> Result<Response, OrchestratorError> {
    // Implementation
}
```

### Tooling

**Formatting:**
- `rustfmt` with default configuration
- Run on all code before commits

**Linting:**
- `clippy` with strict settings
- Treat warnings as errors in CI: `#![deny(clippy::all)]`

**Testing:**
- Unit tests in same file as code: `#[cfg(test)] mod tests { ... }`
- Integration tests in `tests/` directory
- Property-based testing with `proptest` where applicable

## General Conventions

### Version Control

**Commit Messages:**
- Follow Conventional Commits format
- Examples: `feat: add environment validation`, `fix: handle EOF from orchestrator`

**Branching:**
- Feature branches for new work
- Descriptive branch names: `feature/environment-validation`, `fix/llm-retry-logic`

### Code Review

- Focus on correctness, clarity, and adherence to these conventions
- Check that type hints are complete (Python)
- Verify error handling is explicit (Rust)
- Ensure public APIs are documented and tested
