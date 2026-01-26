# Task: Rework Testing Strategy

## Description

Redesign and rewrite the project's test suite to focus on substantive requirement verification rather than superficial implementation checking. The current tests suffer from brittleness, redundancy, and low signal-to-noise ratio - passing tests don't guarantee working code.

## Context

- **Components affected**: All test suites (agent/src tests, orchestrator/tests, sandbox/tests)
- **Current state**: ~79 Rust tests, ~210 Python tests with mixed quality
- **Test infrastructure**: pytest + Hypothesis (Python), cargo test (Rust)
- **Build integration**: Tests run in `nix build .#agent` and `nix build .#orchestrator`
- **Documentation**: `docs/development/testing.md`, `docs/reference/coding-style.md`

## Motivation

Our current test suite has substantive quality issues that undermine its value:

1. **Tests verify implementation, not requirements** - Tests often just redundantly check that the output matches what the code produces, rather than verifying the code meets its actual requirements
2. **Brittle tests coupled to implementation details** - Tests break when wording changes or internal structure changes, even when behavior is correct
3. **Superficial coverage** - High line coverage masks low requirement coverage
4. **Missed requirement validation** - Tests don't verify that outputs conform to downstream consumer expectations

These issues violate our core principle: **"If it compiles, it works"**. Currently passing tests don't guarantee working code.

## Scenarios

These scenarios illustrate what good tests should look like and what problems they should catch:

### Scenario 1: Testing Message Generation
**Current problem**: `test_generate_simulated_message_markdown` checks that generated text contains "markdown file" and specific command strings. This is redundant (just verifying the template content) and brittle (breaks if wording changes).

**What we need**: Test that verifies:
1. Generated message can be parsed by `parse_commands`
2. Parser extracts exactly two editor commands
3. First command is a search with pattern `^#\s`
4. Second command is a view with section delimiters
5. Commands conform to editor environment API (verified by actually invoking the orchestrator)

### Scenario 2: Testing Parser Whitespace Handling
**Current state**: `test_parse_command_preserves_whitespace` checks that parsed Python code has correct indentation.

**Good example**: This test verifies the actual requirement (whitespace preservation) by parsing input and verifying the output structure. It's requirement-based, not implementation-based.

### Scenario 3: Testing EnvironmentName Validation
**Current state**: `test_core_types.py` uses property-based tests with Hypothesis to verify that valid identifiers are accepted and invalid ones rejected.

**Good example**: Tests the requirement (valid Python identifiers) across the input space using properties. This is the ideal approach.

### Scenario 4: Testing BashEnvironment
**Current problem**: Many tests like `test_basic_command_execution` just verify "echo hello" produces "hello". This is trivial - we're testing bash, not our code.

**What we need**: Tests that verify our actual requirements:
1. State persistence across commands (working directory, environment variables)
2. Exit code tracking and reporting
3. Output capture (stdout + stderr)
4. Screen state updates reflecting environment state
5. Background job tracking
6. Output truncation at limits

### Scenario 5: Testing format_event
**Current state**: Tests check that output "contains" specific strings from the event.

**What we need**:
1. For `DisplayMode::Runtime` - verify it's user-readable (maybe regex pattern matching?)
2. For `DisplayMode::Inspect` - verify it's machine-parseable and contains all data
3. Verify timestamp format is consistent
4. Verify costs are formatted to 4 decimal places

## Plan

This task redesigns the testing approach and rewrites tests to be substantive.

### Phase 1: Analysis and Design ✅ (Completed)

- [x] Study current tests and identify problems
- [x] Document specific problem examples and generalizations
- [x] Design new testing approach following project principles
- [x] Survey documentation for current testing approach
- [x] Compare old vs new approach and discuss
- [x] Update documentation with new testing approach

### Phase 2: Rework Agent Tests ✅ (Completed)

- [x] Audit all agent tests, classify by quality (good/needs-improvement/remove)
- [x] Rewrite `test_generate_simulated_message` family with integration validation
- [x] Rewrite `test_format_event` family with structure validation
- [x] Review `test_parse_commands` family (some are good, improve others)
- [x] Update all test names and add requirement docstrings
- [x] Verify `nix build .#agent` passes

### Phase 3: Rework Orchestrator Tests

- [ ] Audit all orchestrator tests, classify by quality
- [ ] Rewrite environment tests to focus on state management and integration
- [ ] Remove trivial tests that just verify bash/python work
- [ ] Add missing requirement tests
- [ ] Verify `nix build .#orchestrator` passes

### Phase 4: Add Tier 2 Tests and Pre-Commit Hook

- [ ] Create pre-commit hook infrastructure
- [ ] Identify tests that belong in Tier 2 (too slow for build)
- [ ] Move or create Tier 2 tests
- [ ] Document Tier 2 test expectations

### Phase 5: Verification

- [ ] Run full test suite
- [ ] Verify Tier 1 tests run in < 30 seconds
- [ ] Manual review of test quality
- [ ] Update CLAUDE.md with testing workflow if needed

## Dependencies

None - this is foundational work that improves code quality across the project.

## Outcome

1. **Updated testing documentation** with new principles and examples
2. **Substantive test suite** where every test verifies specific requirements
3. **Fast build tests** (< 30 seconds) with comprehensive pre-commit tests
4. **High confidence** that passing tests mean working code
5. **Reduced maintenance burden** from less brittle tests

Success criteria:
- Every test can answer "What requirement does this verify?"
- No tests that just duplicate implementation logic
- Integration tests validate with real consumers (orchestrator subprocess)
- Test names clearly document requirements
- `nix build .#agent` and `nix build .#orchestrator` succeed

---

## Appendix: Analysis of Current Problems

### Problem Category 1: Template/String Duplication Tests

**Pattern**: Test generates output from template, then checks output contains template strings.

**Examples**:
- `test_generate_simulated_message_markdown` - checks for "markdown file", exact command strings
- `test_format_system_prompt` - checks for "=== SYSTEM ===" header string
- `test_format_llm_call_runtime` - checks for "[LLM Call 0 (Initialization)]" exact format

**Why problematic**:
- Just duplicates the code logic in test form
- Breaks when non-functional changes happen (rewording)
- Doesn't verify actual requirements (parseability, API compliance, data completeness)

**Fix approach**: Test the contract/requirements, not the content:
- Can downstream consumers parse it?
- Does it contain required data fields?
- Does it meet format specifications?

### Problem Category 2: Trivial Environment Tests

**Pattern**: Tests that verify the underlying tool (bash, python) works as expected, not our wrapper logic.

**Examples**:
- `test_basic_command_execution` - tests that bash echo works
- `test_basic_expression_evaluation` - tests that Python can evaluate 2+2
- `test_print_statement` - tests that Python print works

**Why problematic**:
- We're testing bash/python, not our code
- Adds no value beyond "the subprocess starts"
- High test count with low signal

**Fix approach**: Test our actual requirements:
- State management (persistence, isolation)
- Error handling (exit codes, exceptions)
- Output capture and processing
- Screen state synchronization
- Resource limits

### Problem Category 3: String-Contains Assertions

**Pattern**: Tests use `assert "substring" in output` to verify behavior.

**Examples**:
- `test_working_directory_tracking` - checks that tmpdir path "in" screen content
- `test_variable_tracking_in_screen` - checks "x: int" in screen
- `test_command_with_exit_code_zero` - checks "Last exit code: 0" in screen

**Why problematic**:
- Doesn't verify structure or completeness
- Fragile to formatting changes
- Misses malformed data that happens to contain the substring

**Better approaches**:
- Parse the output and verify structure
- Check for required fields in parsed data
- Use regex for format verification when string format is the requirement

### Problem Category 4: Missing Integration Validation

**Pattern**: Tests verify local behavior but don't verify integration contracts.

**Example**: The `generate_simulated_message` test doesn't verify:
- Parser can actually parse the output
- Editor environment can actually execute the commands
- Commands have valid syntax per editor API

**Why problematic**:
- Components can pass tests individually but fail when integrated
- Integration failures discovered late (runtime, not test time)
- No verification that outputs meet downstream consumer requirements

**Fix approach**:
- Test through the integration boundary
- Verify outputs work with actual consumers
- Don't mock interfaces that we own and control

### Problem Category 5: Unclear Test Purpose

**Pattern**: Tests with vague names and weak assertions.

**Examples**:
- Tests that just assert `response.success is True` without checking output
- Tests that set up state but don't verify the relevant effects

**Why problematic**:
- Can't tell what requirement is being tested
- Weak assertions allow bugs to pass
- Hard to debug failures

**Fix approach**:
- Clear, requirement-focused test names
- Strong assertions that verify the complete requirement
- One primary assertion per test

## Generalizations

### Anti-Pattern: Output Duplication Testing
Testing that output contains strings that are hardcoded in the implementation is redundant and brittle.

**Test the requirement**: What must the output satisfy? Parseability? API compliance? Data completeness?

### Anti-Pattern: Testing the Tools We Use
Testing that bash executes commands or Python evaluates expressions doesn't test our code.

**Test our value-add**: What does our wrapper provide? State management? Error handling? Output processing?

### Anti-Pattern: String-Contains Validation
Checking that output contains specific substrings doesn't verify structure or correctness.

**Test the structure**: Parse it, verify schema, check required fields.

### Anti-Pattern: Isolated Component Testing
Testing components in isolation doesn't verify they integrate correctly.

**Test integration contracts**: Verify outputs work with real consumers.

### Principle: Requirement-Driven Testing
Every test should map to a specific requirement of the code under test.

**Ask**: What must this code guarantee? Test that guarantee.

### Principle: Consumer-Driven Testing
Tests should verify that outputs satisfy downstream consumer requirements.

**Ask**: Who consumes this output? What do they need? Test that.

### Principle: Property-Based Core Testing
Use property-based testing (Hypothesis/proptest) for core data types and public APIs.

**Benefit**: Explores input space, catches edge cases, documents properties.

## Appendix: New Testing Approach Principles

### Testing Principles

1. **Requirement-Driven**: Every test maps to a specific requirement
2. **Consumer-Driven**: Tests verify outputs work with real consumers
3. **Structure-Aware**: Verify structure, not string content
4. **Property-Based Core**: Use Hypothesis/proptest for data types
5. **Integration-First**: Don't mock our own code
6. **Clear Purpose**: Test names document requirements

See `docs/development/testing.md` for complete details and examples.

## Appendix: Specific Test Rewrites Needed

### Agent Tests

#### `test_generate_simulated_message_markdown`
**Current**: Checks for "markdown file" substring and command tags.

**New**:
```rust
#[test]
fn test_generate_simulated_message_integration() {
    /// Requirements:
    /// 1. Message must be parseable by parse_commands
    /// 2. Must produce exactly 2 editor commands (search + view)
    /// 3. Commands must execute successfully in orchestrator
    /// 4. Execution must produce expected effects (view appears in screen)
    ///
    /// Sequential requirements sharing expensive setup (orchestrator spawn).
    ///
    /// WORKAROUND: Uses negative assertion to check for error messages because
    /// orchestrator currently returns success=true even for failed commands.
    /// See task: orchestrator-error-handling

    // Setup temp project with README.md
    let temp_dir = TempDir::new().unwrap();
    let readme = temp_dir.path().join("README.md");
    std::fs::write(&readme, "# Title\n\nContent\n\n# Section\n\nMore content").unwrap();

    let message = Agent::<MockLlmClient>::generate_simulated_message("README.md");

    // Requirement 1: Parseability
    let commands = parse_commands(&message)
        .expect("Generated message must be parseable by parse_commands");

    // Requirement 2: Command structure
    assert_eq!(commands.len(), 2, "Must generate exactly 2 editor commands");
    assert_eq!(commands[0].env, "editor");
    assert_eq!(commands[1].env, "editor");
    assert!(commands[0].command.starts_with("search"),
        "First command must be search");
    assert!(commands[1].command.starts_with("view"),
        "Second command must be view");

    // Requirement 3 & 4: Execution and effects
    let mut orchestrator = spawn_orchestrator(temp_dir.path()).unwrap();

    orchestrator.send_command(&commands[0].env, &commands[0].command).unwrap();
    orchestrator.send_command(&commands[1].env, &commands[1].command).unwrap();

    // Positive assertion (fail-safe) - verify effect
    let screen = orchestrator.get_screen().unwrap();
    assert!(screen.content.contains("[1]"),
        "View must appear in screen after execution. Screen:\n{}", screen.content);
    assert!(screen.content.contains("README.md"),
        "Screen must show filename in view");

    // WORKAROUND: Negative assertion (fail-dangerous) due to orchestrator silent failure
    // See task: orchestrator-error-handling
    assert!(!screen.content.contains("Error:") && !screen.content.contains("Invalid"),
        "Execution must not produce error messages. Screen:\n{}", screen.content);
}
```

#### `test_format_system_prompt`, `test_format_llm_call_*`
**Current**: Check for header strings and content substrings.

**New**: Verify structure and completeness:
```rust
#[test]
fn test_format_llm_call_inspect_contains_all_data() {
    let event = make_llm_call_event(); // Helper
    let output = format_event(&event, DisplayMode::Inspect);

    // Parse output as structured data (if it's meant to be parseable)
    // Or use regex to verify required fields are present
    let required_fields = [
        r"Call ID: \d+",
        r"Purpose: \w+",
        r"Timestamp: \d{4}-\d{2}-\d{2}",
        r"Model: \w+",
        r"Tokens: \d+",
        r"Cost: \$\d+\.\d{4}",
        r"Response:",
    ];

    for pattern in required_fields {
        assert!(Regex::new(pattern).unwrap().is_match(&output),
            "Output missing required field: {}", pattern);
    }
}
```

### Orchestrator Tests

#### `test_basic_command_execution`, `test_basic_expression_evaluation`
**Current**: Just verify bash/python work.

**Replace with**: Tests of our actual requirements:

```python
def test_bash_environment_maintains_state_across_commands():
    """Bash environment should maintain shell state between commands."""
    env = BashEnvironment()

    # Set up state: env var, directory, function
    env.handle_command(CommandText("export MY_VAR=hello"))
    env.handle_command(CommandText("cd /tmp"))
    env.handle_command(CommandText("my_func() { echo $MY_VAR; }"))

    # Verify state persists: all three should still work
    response = env.handle_command(CommandText("echo $MY_VAR"))
    assert "hello" in response.output, "Env var should persist"

    response = env.handle_command(CommandText("pwd"))
    assert "/tmp" in response.output, "Directory should persist"

    response = env.handle_command(CommandText("my_func"))
    assert "hello" in response.output, "Function should persist"

def test_bash_environment_screen_reflects_state():
    """Screen should show current working directory and exit code."""
    env = BashEnvironment()

    # Initial state
    screen = env.get_screen()
    assert "Working directory:" in screen.content

    # Change state
    env.handle_command(CommandText("cd /tmp"))
    env.handle_command(CommandText("false"))  # Exit code 1

    # Screen should reflect changes
    screen = env.get_screen()
    assert "/tmp" in screen.content, "Screen should show new directory"
    assert "Last exit code: 1" in screen.content, "Screen should show exit code"
```

#### `test_working_directory_tracking`
**Current**: Checks tmpdir path is "in" screen content.

**Better**:
```python
def test_bash_environment_tracks_working_directory():
    """Working directory should update when changed and appear in screen."""
    env = BashEnvironment()

    with tempfile.TemporaryDirectory() as tmpdir:
        # Change directory
        response = env.handle_command(CommandText(f"cd {tmpdir}"))
        assert response.success, "cd command should succeed"

        # Verify internal state tracks it
        response = env.handle_command(CommandText("pwd"))
        assert tmpdir in response.output, "pwd should show new directory"

        # Verify screen shows it
        screen = env.get_screen()
        # Parse screen to find working directory line
        lines = screen.content.split('\n')
        wd_lines = [l for l in lines if l.startswith("Working directory:")]
        assert len(wd_lines) == 1, "Screen should have exactly one working directory line"
        assert tmpdir in wd_lines[0], "Working directory line should show current directory"
```

## Notes

**Key Insights**:

1. **Brittleness hierarchy**: Not all brittleness is equal. Tests brittle to component being tested (worst) vs tests brittle to downstream components with fail-safe failures (acceptable).

2. **Positive vs negative assertions**: Positive assertions ("screen contains [1]") are fail-safe - we notice when they break incorrectly. Negative assertions ("response doesn't contain Error:") are fail-dangerous - bugs slip through unnoticed.

3. **Integration is requirement validation**: Spawning orchestrator to validate generated commands is NOT just "integration testing" - it's verifying the requirement that "generated commands execute successfully". The requirement involves integration, so the test must too.

4. **Orchestrator silent failure workaround**: Orchestrator currently returns `success: true` even for malformed commands, forcing us to use negative assertions to check for error messages. This is marked as WORKAROUND and tracked in a separate task.

**Trade-offs**:
- More thorough tests take longer to write initially
- But they catch more bugs, require less maintenance, provide more confidence
- Right trade-off for LLM-driven codebase where human review is minimal
