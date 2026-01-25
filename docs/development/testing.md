# Testing Guide

Comprehensive guide to testing in the 7aigent project.

## Testing Philosophy

**Property-based testing for correctness, example tests for clarity.**

This project emphasizes thorough testing to ensure correctness in an LLM-driven codebase:

1. **Public APIs must be tested**: All public functions and classes require tests
2. **Property-based tests for public APIs**: Use Hypothesis (Python) or proptest (Rust)
3. **Example tests for edge cases**: Specific scenarios that property tests might miss
4. **Integration tests for component interaction**: Verify components work together
5. **Tests guide implementation**: Write tests as you write code, not after

## Running Tests

### Quick Test Runs

<bash>
# Build agent with tests (runs cargo test)
nix build .#agent

# Build orchestrator with tests (runs pytest)
nix build .#orchestrator

# Run all checks including tests
nix flake check
</bash>

### Development Testing

Within the development shell, you can run tests directly:

<bash>
# Enter development shell
nix develop

# Python tests (orchestrator)
pytest orchestrator/tests/
pytest orchestrator/tests/test_environment.py  # Single file
pytest -k "test_bash"                          # By keyword
pytest -v                                       # Verbose output

# Rust tests (agent)
cargo test
cargo test --package agent                     # Single package
cargo test test_llm_client                     # By name
cargo test -- --nocapture                      # Show stdout
</bash>

### Test Coverage

<bash>
# Python coverage
pytest --cov=orchestrator --cov-report=html

# Rust coverage (requires additional tools)
cargo tarpaulin --out Html
</bash>

## Writing Tests

### Python: Property-Based Testing

Use [Hypothesis](https://hypothesis.readthedocs.io/) for public API testing:

<python>
from hypothesis import given, strategies as st
import pytest

@dataclass(frozen=True)
class EnvironmentName:
    value: str

    def __post_init__(self):
        if not self.value.isidentifier():
            raise ValueError("Invalid environment name")

# Property: Valid identifiers should be accepted
@given(st.from_regex(r"[a-zA-Z_][a-zA-Z0-9_]*", fullmatch=True))
def test_valid_identifiers_accepted(identifier: str):
    name = EnvironmentName(identifier)
    assert name.value == identifier

# Property: Invalid identifiers should be rejected
@given(st.text().filter(lambda s: not s.isidentifier()))
def test_invalid_identifiers_rejected(invalid: str):
    with pytest.raises(ValueError):
        EnvironmentName(invalid)
</python>

### Python: Example Tests

Use specific examples for complex scenarios and edge cases:

<python>
class TestBashEnvironment:
    """Test bash environment with specific examples."""

    def test_command_execution(self):
        """Simple command should execute and return output."""
        env = BashEnvironment()
        response = env.handle_command(CommandText("echo hello"))

        assert response.exit_code == 0
        assert "hello" in response.output

    def test_working_directory_persistence(self):
        """Working directory should persist across commands."""
        env = BashEnvironment()

        env.handle_command(CommandText("cd /tmp"))
        response = env.handle_command(CommandText("pwd"))

        assert "/tmp" in response.output

    def test_environment_variables(self):
        """Environment variables should be accessible."""
        env = BashEnvironment()
        env.handle_command(CommandText("export TEST_VAR=value"))
        response = env.handle_command(CommandText("echo $TEST_VAR"))

        assert "value" in response.output
</python>

### Rust: Property-Based Testing

Use [proptest](https://github.com/proptest-rs/proptest) for property-based tests:

```rust
use proptest::prelude::*;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvironmentName(String);

impl EnvironmentName {
    pub fn new(name: String) -> Result<Self, String> {
        if name.chars().all(|c| c.is_alphanumeric() || c == '_') {
            Ok(Self(name))
        } else {
            Err(format!("Invalid environment name: {}", name))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    proptest! {
        #[test]
        fn valid_names_accepted(name in "[a-zA-Z_][a-zA-Z0-9_]*") {
            assert!(EnvironmentName::new(name).is_ok());
        }

        #[test]
        fn invalid_names_rejected(name in ".*[^a-zA-Z0-9_].*") {
            assert!(EnvironmentName::new(name).is_err());
        }
    }
}
```

### Rust: Example Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_execution_succeeds() {
        let cmd = Command::new("bash", vec!["ls"]);
        let result = execute_command(cmd).unwrap();
        assert_eq!(result.exit_code, 0);
    }

    #[test]
    fn handles_command_failure() {
        let cmd = Command::new("bash", vec!["invalid_command"]);
        let result = execute_command(cmd).unwrap();
        assert_ne!(result.exit_code, 0);
    }
}
```

## Test Organization

### Python Test Structure

```
orchestrator/
├── environments/
│   ├── bash.py
│   ├── python.py
│   └── ...
└── tests/
    ├── test_bash_environment.py
    ├── test_python_environment.py
    ├── test_screen.py
    └── ...
```

Group related tests in classes:

<python>
class TestEnvironmentValidation:
    """Test environment module validation."""

    def test_missing_handle_command(self):
        """Module missing handle_command should fail validation."""
        ...

    def test_wrong_signature_types(self):
        """handle_command with wrong parameter type should fail."""
        ...

    def test_complete_valid_environment(self):
        """Complete valid environment should pass validation."""
        ...
</python>

### Rust Test Structure

```rust
// Unit tests in same file
mod module {
    pub fn function() -> Result<(), Error> {
        // Implementation
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn test_function_success() {
            assert!(function().is_ok());
        }
    }
}

// Integration tests in tests/ directory
// tests/integration_test.rs
use agent::Client;

#[test]
fn test_client_orchestrator_communication() {
    // Test cross-module interactions
}
```

## What to Test

### Public APIs (Required)

All public functions and classes must have tests:

- **Validation logic**: Test all validation rules
- **State transitions**: Test all state changes
- **Error conditions**: Test all error paths
- **Edge cases**: Empty inputs, boundary values, null cases

### Private APIs (Selective)

Test private code if:

- Logic is complex
- Behavior is well-defined and stable
- Testing through public API is impractical

Otherwise, test through the public API.

### Integration Points

Test component interactions:

- Agent to orchestrator communication
- Orchestrator to environment protocol
- Environment state management
- Error propagation across boundaries

## Test Quality Guidelines

### Good Test Characteristics

1. **Independent**: Can run in isolation without setup order dependencies
2. **Repeatable**: Same result every time
3. **Fast**: Tests should run quickly
4. **Focused**: Test one thing per test
5. **Readable**: Clear names and assertions

### Example of Good Test

<python>
def test_bash_environment_preserves_working_directory():
    """Working directory should persist between commands."""
    env = BashEnvironment()

    # Change directory
    env.handle_command(CommandText("cd /tmp"))

    # Verify persistence
    response = env.handle_command(CommandText("pwd"))
    assert "/tmp" in response.output
</python>

### Example of Bad Test

<python>
def test_bash():  # Unclear what this tests
    env = BashEnvironment()
    env.handle_command(CommandText("cd /tmp"))
    assert True  # Weak assertion
</python>

## Fixtures and Test Utilities

### Python Fixtures

<python>
import pytest

@pytest.fixture
def bash_env():
    """Provide a fresh bash environment for each test."""
    return BashEnvironment()

@pytest.fixture
def temp_workspace(tmp_path):
    """Provide a temporary workspace with test files."""
    test_file = tmp_path / "test.py"
    test_file.write_text("print('hello')")
    return tmp_path

def test_with_fixtures(bash_env, temp_workspace):
    """Test using fixtures."""
    bash_env.handle_command(CommandText(f"cd {temp_workspace}"))
    response = bash_env.handle_command(CommandText("python test.py"))
    assert "hello" in response.output
</python>

## Debugging Tests

### Python Debugging

<bash>
# Run with verbose output
pytest -v

# Show print statements
pytest -s

# Drop into debugger on failure
pytest --pdb

# Run single test with output
pytest -xvs orchestrator/tests/test_bash.py::test_command_execution
</bash>

### Rust Debugging

<bash>
# Show stdout
cargo test -- --nocapture

# Run single test
cargo test test_name -- --nocapture

# Show backtraces
RUST_BACKTRACE=1 cargo test
</bash>

## Coverage Expectations

- **New code**: Aim for 90%+ coverage
- **Critical paths**: 100% coverage required
- **Error handling**: All error paths must be tested
- **Edge cases**: Boundary conditions must be tested

Coverage is automatically checked in the Nix build.

## Success Criteria

Tests are good if:

- All public APIs have property-based tests
- Edge cases have specific example tests
- Tests are independent and repeatable
- Test names clearly describe what's being tested
- All tests pass in `nix build`
- Coverage meets expectations
