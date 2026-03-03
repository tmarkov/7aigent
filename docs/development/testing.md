# Testing Guide

Comprehensive guide to testing in the 7aigent project.

## Testing Philosophy

**Test requirements, not implementation. Use property-based tests for correctness, integration tests for contracts.**

This project emphasizes thorough, substantive testing to ensure correctness in an LLM-driven codebase:

### Core Principles

1. **Test requirements, not implementation**: Every test verifies a specific requirement, not that code produces expected output
2. **Consumer-driven testing**: Tests verify outputs satisfy downstream consumer requirements
3. **Property-based testing for core types**: Use Hypothesis (Python) or proptest (Rust) for data types and public APIs
4. **Integration-first**: Test through real boundaries with actual dependencies, not mocks
5. **Structure-aware assertions**: Parse and verify structure, not substring matching
6. **Tests guide implementation**: Write tests as you write code, not after

### "If It Compiles, It Works"

Our goal: passing tests should give high confidence that code meets requirements.

**This means:**
- Tests verify behavioral contracts, not implementation details
- Strong types + strong tests = correctness guarantee
- Test failures indicate requirement violations, not just implementation changes

## Test Tiers

Tests are organized into two tiers based on speed and scope:

### Tier 1: Build Tests (Fast)

Run automatically during `nix build`. Must complete in < 30 seconds total.

**Includes:**
- Unit tests of pure functions
- Property-based tests of data types
- Fast integration tests (including spawning orchestrator subprocess)
- Core functionality and requirement validation

**Excludes:**
- Tests requiring VMs
- Tests making actual LLM API calls
- Long-running stress tests

**Key: Spawning orchestrator subprocess is FAST** (~100ms) and validates real integration. Not a reason to defer to Tier 2.

### Tier 2: Pre-Commit Tests (Comprehensive)

Run before commits via pre-commit hook. Can be slower.

**Includes:**
- End-to-end integration tests
- Stress tests and chaos testing
- VM-based sandbox tests (if needed)
- Any test too slow for Tier 1

**Run via**: Pre-commit hook (enforced)

## Test Timeouts

**Critical for tests that spawn subprocesses: All tests must have timeout protection to prevent hanging the test suite.**

### Why Timeouts Matter

Tests that interact with subprocesses (bash shells, Python REPLs, etc.) can hang indefinitely if:
- Process enters infinite loop
- Deadlock in communication (e.g., `readline()` waits forever)
- Process doesn't respond to termination signals

**Without timeouts**: One hanging test blocks all subsequent tests and CI pipelines indefinitely.

**With timeouts**: Tests fail quickly with clear error messages.

### Defense-in-Depth Strategy

Use **two layers** of timeout protection:

#### 1. Test-Level Timeouts (Python)

**Purpose**: Fast detection with precise error reporting - identifies which specific test hung.

**Implementation**: Import and use the `timeout` decorator from `orchestrator/tests/__init__.py` on all tests that spawn subprocesses.

```python
from . import timeout

class TestBashEnvironment:
    @timeout(10)
    def test_bash_environment_maintains_state(self):
        """Test must complete within 10 seconds."""
        env = BashEnvironment()
        # ... test code
```

**Guideline**: Set timeout to ~2-3x expected runtime. Most subprocess tests should complete in 1-3 seconds, so 10 seconds is generous.

**Location**: Decorator is defined in `orchestrator/tests/__init__.py`. **Always import it, never copy the implementation.**

**Limitation**: Unix-only (uses SIGALRM). Not needed for Rust tests (see Nix-level below).

#### 2. Nix-Level Timeouts (Build System)

**Purpose**: Safety net that catches everything - forgotten decorators, Rust tests, integration tests.

**Implementation**: Configured in Nix derivations:

```nix
# agent/default.nix (Rust tests)
checkPhase = ''
  echo "Building tests..."
  cargo test --release --no-run

  echo "Running cargo test..."
  ${pkgs.coreutils}/bin/timeout 30 cargo test --release
'';

# flake.nix (Python tests)
checkPhase = ''
  echo "Running pytest tests..."
  ${pkgs.coreutils}/bin/timeout 120 pytest tests/ -v
'';
```

**Guidelines**:
- **Cargo tests**: 30 seconds (currently ~6 seconds, 5x margin; compilation done separately with --no-run)
- **Pytest tests**: 120 seconds (currently ~25 seconds, 5x margin)
- Set timeout to 5x typical runtime to avoid flaky failures on slow CI

**When timeout triggers**: Entire test suite is killed. Less precise than test-level, but ensures build never hangs forever.

### Current Timeout Configuration

| Test Suite | Test-Level | Nix-Level | Typical Runtime | Notes |
|------------|-----------|-----------|----------------|-------|
| Agent (Rust) | N/A | 30s | ~6s | Nix-level only |
| Orchestrator (Python) | 10s per test | 120s | ~25s total | Both layers |
| Sandbox (Python) | 10s per test | 120s | Varies | Both layers |

### Best Practices

1. **Always use timeout decorator** for tests spawning subprocesses (Python)
2. **Set generous timeout values** - 2-5x expected runtime
3. **Document expected runtime** in test docstring if unusual
4. **Fix hanging tests, don't increase timeout** - if test hits timeout, there's a bug
5. **Use timeout to debug** - when test hangs, timeout converts hang into failure with clear message

### Common Hanging Scenarios

**Subprocess readline blocks forever**:
```python
# Bad - can hang forever
response_line = proc.stdout.readline()

# Good - timeout on read
import select
ready, _, _ = select.select([proc.stdout], [], [], 10)
if not ready:
    raise TimeoutError("Process didn't respond")
response_line = proc.stdout.readline()
```

**Python REPL waits for continuation**:
```python
# Issue: Single-line compound statements need extra newline
process.send("def foo(): return 42\n")  # Hangs - waits for more input
process.send("def foo(): return 42\n\n")  # Works - double newline completes
```

**Process doesn't terminate**:
```python
# Ensure cleanup handles stuck processes
try:
    process.send("exit()\n")
    process.expect(pexpect.EOF, timeout=2)
except pexpect.TIMEOUT:
    process.terminate(force=True)  # Force kill if graceful exit fails
```

## Running Tests

### Quick Test Runs (Tier 1)

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

## Testing Anti-Patterns

### Anti-Pattern: Output Duplication Testing

**Problem**: Testing that output contains strings hardcoded in the implementation.

**Example of bad test**:
```rust
#[test]
fn test_generate_message() {
    let message = generate_message("file.md");
    assert!(message.contains("markdown file"));  // Just checking template string
    assert!(message.contains("<editor>"));  // Just checking template string
}
```

**Why bad**: Redundantly duplicates implementation logic. Breaks on non-functional changes (rewording). Doesn't verify actual requirements.

**Better approach**: Test the requirement - what must the output satisfy?

```rust
#[test]
fn test_generate_message_produces_parseable_commands() {
    let message = generate_message("file.md");

    // Requirement 1: Must be parseable
    let commands = parse_commands(&message)
        .expect("Generated message should be parseable");

    // Requirement 2: Must have expected command structure
    assert_eq!(commands.len(), 2);
    assert_eq!(commands[0].env, "editor");

    // Requirement 3: Commands must be executable (integration test)
    let mut orchestrator = spawn_orchestrator(temp_dir).unwrap();
    for cmd in commands {
        let response = orchestrator.send_command(&cmd.env, &cmd.command).unwrap();
        assert!(response.success, "Generated commands must be executable");
    }
}
```

### Anti-Pattern: Testing The Tools We Use

**Problem**: Testing that bash executes commands or Python evaluates expressions.

**Example of bad test**:
```python
def test_basic_execution(self):
    env = PythonEnvironment()
    response = env.handle_command(CommandText("2 + 2"))
    assert "4" in response.output  # Testing Python, not our code
```

**Why bad**: Tests Python's math, not our wrapper logic. Adds no value beyond "subprocess starts".

**Better approach**: Test our value-add (state management, error handling, output processing).

```python
def test_python_environment_maintains_state_across_commands(self):
    """Variables and imports should persist across multiple commands."""
    env = PythonEnvironment()

    # Set up state
    env.handle_command(CommandText("x = 42"))
    env.handle_command(CommandText("import math"))

    # Verify state persistence
    response = env.handle_command(CommandText("x + math.ceil(3.14)"))
    assert "46" in response.output, "Should use persisted variable and import"

    # Verify screen reflects state
    screen = env.get_screen()
    assert "x:" in screen.content, "Screen should show defined variables"
```

### Anti-Pattern: String-Contains Validation

**Problem**: Using `assert "substring" in output` to verify behavior.

**Example of bad test**:
```python
def test_screen_shows_variables(self):
    env.handle_command(CommandText("x = 42"))
    screen = env.get_screen()
    assert "x: int" in screen.content  # Weak assertion
```

**Why bad**: Doesn't verify structure. Fragile to formatting changes. Misses malformed data.

**Better approach**: Parse and verify structure.

```python
def test_screen_shows_current_variables_with_types(self):
    """Screen should show variables in structured format with types."""
    env = PythonEnvironment()
    env.handle_command(CommandText("x = 42"))
    env.handle_command(CommandText("y = 'hello'"))

    screen = env.get_screen()

    # Parse the screen structure
    lines = screen.content.split('\n')
    var_section = extract_section(lines, "Variables (recent):")

    # Verify structure
    variables = {parse_var_line(l) for l in var_section if ':' in l}
    assert len(variables) == 2, "Should show both variables"
    assert ("x", "int") in variables
    assert ("y", "str") in variables
```

### Anti-Pattern: Isolated Component Testing Without Integration

**Problem**: Testing components in isolation without verifying they integrate correctly.

**Example of bad test**:
```rust
#[test]
fn test_generate_commands() {
    let message = generate_commands("file.md");
    // Just checks string format, doesn't verify parser can parse it
    // or orchestrator can execute it
}
```

**Why bad**: Components pass individually but may fail when integrated. No verification outputs work with consumers.

**Better approach**: Test through integration boundaries.

```rust
#[test]
fn test_generated_commands_integrate_with_parser_and_orchestrator() {
    // Generate message
    let message = generate_commands("README.md");

    // Integration point 1: Parser must parse it
    let commands = parse_commands(&message)
        .expect("Parser should parse generated message");

    // Integration point 2: Orchestrator must execute it
    let mut orchestrator = spawn_orchestrator(temp_dir.path()).unwrap();
    for cmd in commands {
        let response = orchestrator.send_command(&cmd.env, &cmd.command).unwrap();
        assert!(response.success, "Orchestrator should execute generated commands");
    }
}
```

## Writing Tests

### Test Naming Convention

**Pattern**: `test_<component>_<requirement_as_fact>`

Where:
- **component** = the specific thing being tested (function name, class name, type name)
- **requirement** = what must be true (in present tense, as a fact)

**Examples**:
```rust
// Function tests
test_generate_simulated_message_produces_parseable_commands
test_parse_commands_preserves_whitespace_in_code_blocks
test_format_event_includes_all_required_fields

// Class/Type tests (Python)
test_bash_environment_persists_working_directory_across_commands
test_environment_name_accepts_valid_python_identifiers
test_python_environment_shows_variables_in_screen

// Integration tests
test_simulated_message_integrates_with_parser_and_orchestrator
test_agent_to_orchestrator_executes_parsed_commands
```

**Benefits**:
- Component being tested is immediately clear from name
- Easy to find all tests for a specific component (grep/search)
- Requirement is stated as what must be true
- Self-documenting test suite

### Test Docstring Convention

**Format**:
```
"""Requirement: <What must be true>

[Optional: Additional context about why this requirement exists,
what it protects against, or how it relates to other requirements]

[Optional: WORKAROUND note if using brittle assertions due to other
component limitations - include reference to task for fixing]
"""
```

**Examples**:

```rust
#[test]
fn test_parse_commands_preserves_whitespace_in_code_blocks() {
    /// Requirement: Parser must preserve all whitespace within command blocks,
    /// including indentation needed for Python code.
    ///
    /// This ensures Python code with significant whitespace is not corrupted
    /// during parsing.
    ...
}
```

```python
def test_bash_environment_persists_working_directory_across_commands(self):
    """Requirement: Bash environment must maintain working directory state
    between commands - cd in one command affects pwd in the next.

    This is essential for the environment to function as a persistent shell.
    """
    ...
```

**With WORKAROUND note**:

```rust
#[test]
fn test_generated_message_produces_working_commands() {
    /// Requirements:
    /// 1. Message must be parseable by parse_commands
    /// 2. Commands must execute successfully in orchestrator
    /// 3. Execution must produce expected effects (view appears in screen)
    ///
    /// WORKAROUND: Uses negative assertion to check for error messages because
    /// orchestrator currently returns success=true even for failed commands.
    /// See task: orchestrator-error-handling
    ...
}
```

### Test Granularity

**Default: One test per requirement** for clarity and debuggability.

**Combine multiple requirements in one test when:**
- Requirements are sequential/dependent (requirement B depends on A passing)
- Requirements share expensive setup (process spawning, file I/O, network calls)
- Requirements form a natural integration contract (producer → consumer)

**When combining multiple requirements:**
- List all requirements in the docstring (numbered list)
- Mark each requirement with a comment in the test body
- Keep combined tests focused (< ~50 lines as guideline)
- If test becomes complex, split even if it means duplication

**Example of appropriate combination**:

```rust
#[test]
fn test_generate_simulated_message_integration() {
    /// Requirements:
    /// 1. Message must be parseable by parse_commands
    /// 2. Must produce exactly 2 editor commands (search + view)
    /// 3. Commands must execute successfully in orchestrator
    /// 4. Execution must produce expected effects (view in screen)
    ///
    /// Sequential requirements sharing expensive setup (orchestrator spawn).

    let temp_dir = TempDir::new().unwrap();
    let readme = temp_dir.path().join("README.md");
    std::fs::write(&readme, "# Title\n\nContent\n").unwrap();

    let message = generate_simulated_message("README.md");

    // Requirement 1: Parseability
    let commands = parse_commands(&message)
        .expect("Generated message must be parseable");

    // Requirement 2: Command structure
    assert_eq!(commands.len(), 2, "Must generate 2 editor commands");
    assert_eq!(commands[0].env, "editor");
    assert!(commands[0].command.starts_with("search"));

    // Requirement 3 & 4: Execution and effects
    let mut orchestrator = spawn_orchestrator(temp_dir.path()).unwrap();
    orchestrator.send_command(&commands[0].env, &commands[0].command).unwrap();

    let screen = orchestrator.get_screen().unwrap();
    assert!(screen.content.contains("[1]"), "View must appear in screen");
}
```

**Counter-example - should be separate**:

```rust
// These are independent requirements - keep as separate tests
#[test]
fn test_bash_environment_persists_working_directory() { ... }

#[test]
fn test_bash_environment_persists_environment_variables() { ... }

#[test]
fn test_bash_environment_tracks_exit_codes() { ... }
```

### Assertion Strategy: Brittleness Hierarchy

Not all brittleness is equal. Tests can be brittle in different ways with different failure modes:

#### 1. Worst: Testing Implementation of Component Itself

**Example**: Checking that `generate_simulated_message` output contains "markdown file"

**Problem**:
- Breaks on non-functional changes to the component being tested
- Prevents refactoring and wording improvements
- **Eliminate this type of brittleness**

#### 2. Fail-Dangerous: Negative Assertions on Downstream Components

**Example**: Checking that orchestrator response doesn't contain "Error:"

**Problem**:
- Breaks on changes to error message format in downstream component
- **Failure mode: Test passes when it should fail (false positive)**
- Bugs slip through unnoticed

**When necessary**: Mark with WORKAROUND comment and reference task to fix underlying issue

```rust
// WORKAROUND: Negative assertion due to orchestrator silent failure
// See task: orchestrator-error-handling
assert!(!response.output.contains("Error:"),
    "Execution should not produce errors");
```

#### 3. Fail-Safe: Positive Assertions on Downstream Components

**Example**: Checking that screen contains "[1]" after view command

**Problem**:
- Breaks on changes to screen format in downstream component
- **Failure mode: Test fails when it should pass (false negative)**
- We notice immediately and can update the test

**This is acceptable**: Natural consequence of integration testing

```rust
// Positive assertion - fail-safe brittleness
let screen = orchestrator.get_screen().unwrap();
assert!(screen.content.contains("[1]"),
    "View must appear in screen. Screen:\n{}", screen.content);
```

### General Assertion Guidelines

**Prefer**:
- Positive assertions (check for presence of expected things)
- Effect verification (check the state change, not just the message)
- Structure parsing (parse output, verify schema)
- Strong comparisons (`assert_eq!`, not just "contains")

**Avoid**:
- Negative assertions (checking for absence of errors)
- String template duplication (checking hardcoded strings from implementation)
- Weak assertions (`assert!(response.success)` without checking output)

**When negative assertions are necessary**:
- Mark clearly with WORKAROUND comment
- Explain why it's needed
- Reference task to fix underlying issue
- Include context in assertion message

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

Focus on **requirement coverage**, not just line coverage.

- **New code**: All requirements must have tests
- **Critical paths**: 100% test coverage of requirements
- **Error handling**: All error paths must be tested
- **Edge cases**: Boundary conditions must be tested
- **Integration points**: All consumer contracts must be validated

Line coverage is automatically checked in the Nix build, but it's a proxy metric. What matters is that all requirements are verified.

## Success Criteria

### Good Test Characteristics

Tests are substantive if:

1. **Requirement-focused**: Every test answers "What requirement does this verify?"
2. **Consumer-validated**: Tests verify outputs work with real consumers
3. **Structure-aware**: Tests parse outputs and verify structure, not just string matching
4. **Integration-validated**: Tests verify components work together through real boundaries
5. **Independent**: Can run in isolation without setup order dependencies
6. **Repeatable**: Same result every time
7. **Fast** (Tier 1): Complete in < 30 seconds total
8. **Clear naming**: Test name documents the requirement being verified
9. **Strong assertions**: Verify complete requirement, not just that code runs

### Bad Test Characteristics

Tests are superficial if:

1. **Implementation duplication**: Just checking code produces expected output (redundant)
2. **String matching**: Only using `assert "substring" in output`
3. **Testing tools**: Testing that bash/python work, not our wrapper logic
4. **Isolated without integration**: Testing components without verifying they integrate
5. **Unclear purpose**: Test name doesn't indicate what requirement is being verified
6. **Weak assertions**: Just checking `success == True` without verifying output
7. **Brittle**: Break on non-functional changes (wording, formatting)
