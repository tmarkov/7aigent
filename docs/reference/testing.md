# Testing Strategy

This document defines the testing strategy and conventions for the 7aigent project.

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

**Key:** Spawning orchestrator subprocess is FAST (~100ms) and validates real integration. Not a reason to defer to Tier 2.

### Tier 2: Comprehensive Tests (Not Yet Implemented)

Slower tests that would run before commits. Currently we have **NO Tier 2 tests**.

**Future tests:**
- Real LLM integration tests (requires API key, expensive)
- Session management tests (create, pause, resume)
- Cost tracking and budget enforcement
- Long-running scenario tests (minutes per scenario)
- Stress tests and performance benchmarks
- Multi-session integration tests

**Run via:** Pre-commit hook (when implemented)

## Test Timeouts

**Critical for tests that spawn subprocesses: All tests must have timeout protection to prevent hanging the test suite.**

### Why Timeouts Matter

Tests that interact with subprocesses (bash shells, Python REPLs, etc.) can hang indefinitely if:
- Process enters infinite loop
- Deadlock in communication (e.g., `readline()` waits forever)
- Process doesn't respond to termination signals

**Without timeouts:** One hanging test blocks all subsequent tests and CI pipelines indefinitely.

**With timeouts:** Tests fail quickly with clear error messages.

### Defense-in-Depth Strategy

Use **two layers** of timeout protection:

#### 1. Test-Level Timeouts (Python)

**Purpose:** Fast detection with precise error reporting - identifies which specific test hung.

**Implementation:** Import and use the `timeout` decorator from `orchestrator/tests/__init__.py` on all tests that spawn subprocesses.

```python
from . import timeout

class TestBashEnvironment:
    @timeout(10)
    def test_bash_environment_maintains_state(self):
        """Test must complete within 10 seconds."""
        env = BashEnvironment()
        # ... test code
```

**Guideline:** Set timeout to ~2-3x expected runtime. Most subprocess tests should complete in 1-3 seconds, so 10 seconds is generous.

**Location:** Decorator is defined in `orchestrator/tests/__init__.py`. **Always import it, never copy the implementation.**

**Limitation:** Unix-only (uses SIGALRM). Not needed for Rust tests (see Nix-level below).

#### 2. Nix-Level Timeouts (Build System)

**Purpose:** Safety net that catches everything - forgotten decorators, Rust tests, integration tests.

**Implementation:** Configured in Nix derivations:

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

**Guidelines:**
- **Cargo tests:** 30 seconds (currently ~6 seconds, 5x margin; compilation done separately with --no-run)
- **Pytest tests:** 120 seconds (currently ~25 seconds, 5x margin)
- Set timeout to 5x typical runtime to avoid flaky failures on slow CI

**When timeout triggers:** Entire test suite is killed. Less precise than test-level, but ensures build never hangs forever.

### Current Timeout Configuration

| Test Suite | Test-Level | Nix-Level | Typical Runtime | Notes |
|------------|-----------|-----------|----------------|-------|
| Agent (Rust) - Unit | N/A | 30s | ~6s | Tier 1 |
| Agent (Rust) - Integration | 180s | 180s | ~2-5s | Tier 1 (full stack) |
| Orchestrator (Python) | 10s per test | 120s | ~25s total | Tier 1 |
| Sandbox (Python) | 10s per test | 120s | Varies | Tier 1 |

**Note:** Integration test has generous 180s timeout because it spawns subprocesses and uses thread-based timeout enforcement for diagnostics. Actual runtime is ~2-5s.

### Best Practices

1. **Always use timeout decorator** for tests spawning subprocesses (Python)
2. **Set generous timeout values** - 2-5x expected runtime
3. **Document expected runtime** in test docstring if unusual
4. **Fix hanging tests, don't increase timeout** - if test hits timeout, there's a bug
5. **Use timeout to debug** - when test hangs, timeout converts hang into failure with clear message

## Running Tests

### Quick Test Runs (Tier 1)

```bash
# Build agent with tests (runs cargo test)
nix build .#agent

# Build orchestrator with tests (runs pytest)
nix build .#orchestrator

# Run all checks including tests
nix flake check
```

### Development Testing

Within the development shell, you can run tests directly:

```bash
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
```

### Test Coverage

```bash
# Python coverage
pytest --cov=orchestrator --cov-report=html

# Rust coverage (requires additional tools)
cargo tarpaulin --out Html
```

## Testing Anti-Patterns

### Anti-Pattern: Output Duplication Testing

**Problem:** Testing that output contains strings hardcoded in the implementation.

**Example of bad test:**
```rust
#[test]
fn test_generate_message() {
    let message = generate_message("file.md");
    assert!(message.contains("markdown file"));  // Just checking template string
    assert!(message.contains("<editor>"));  // Just checking template string
}
```

**Why bad:** Redundantly duplicates implementation logic. Breaks on non-functional changes (rewording). Doesn't verify actual requirements.

**Better approach:** Test the requirement - what must the output satisfy?

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

**Problem:** Testing that bash executes commands or Python evaluates expressions.

**Example of bad test:**
```python
def test_basic_execution(self):
    env = PythonEnvironment()
    response = env.handle_command(CommandText("2 + 2"))
    assert "4" in response.output  # Testing Python, not our code
```

**Why bad:** Tests Python's math, not our wrapper logic. Adds no value beyond "subprocess starts".

**Better approach:** Test our value-add (state management, error handling, output processing).

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

**Problem:** Using `assert "substring" in output` to verify behavior.

**Example of bad test:**
```python
def test_screen_shows_variables(self):
    env.handle_command(CommandText("x = 42"))
    screen = env.get_screen()
    assert "x: int" in screen.content  # Weak assertion
```

**Why bad:** Doesn't verify structure. Fragile to formatting changes. Misses malformed data.

**Better approach:** Parse and verify structure.

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

**Problem:** Testing components in isolation without verifying they integrate correctly.

**Example of bad test:**
```rust
#[test]
fn test_generate_commands() {
    let message = generate_commands("file.md");
    // Just checks string format, doesn't verify parser can parse it
    // or orchestrator can execute it
}
```

**Why bad:** Components pass individually but may fail when integrated. No verification outputs work with consumers.

**Better approach:** Test through integration boundaries.

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

**Pattern:** `test_<component>_<requirement_as_fact>`

Where:
- **component** = the specific thing being tested (function name, class name, type name)
- **requirement** = what must be true (in present tense, as a fact)

**Examples:**
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

**Benefits:**
- Component being tested is immediately clear from name
- Easy to find all tests for a specific component (grep/search)
- Requirement is stated as what must be true
- Self-documenting test suite

### Test Docstring Convention

**Format:**
```
"""Requirement: <What must be true>

[Optional: Additional context about why this requirement exists,
what it protects against, or how it relates to other requirements]

[Optional: WORKAROUND note if using brittle assertions due to other
component limitations - include reference to task for fixing]
"""
```

**Examples:**

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

**With WORKAROUND note:**

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

## Related Files

- [General Conventions](./conventions/general.md) - Project-wide conventions
- [Rust Conventions](./conventions/rust.md) - Rust-specific style guidelines
- [Python Conventions](./conventions/python.md) - Python-specific style guidelines
