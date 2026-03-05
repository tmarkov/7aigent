# Orchestrator Tests Audit

**Note**: This audit was conducted in January 2026 and references the original v1 editor environment. The editor was redesigned in March 2026 (see task 26). Editor test findings may no longer apply to the current implementation.

Complete audit of all orchestrator test files (12 files, ~210 tests total). Each test classified as:
- **GOOD**: Verifies actual requirements, uses property-based testing, or tests substantive behavior
- **NEEDS-IMPROVEMENT**: Trivial tests that just verify bash/python work, or brittle string matching
- **REMOVE**: Redundant or no-value tests

## Summary Statistics

- **Total tests**: ~210
- **GOOD**: ~135 (64%)
- **NEEDS-IMPROVEMENT**: ~73 (35%)
- **REMOVE**: ~2 (1%)

## Files Analyzed

1. test_core_types.py (308 lines, 50+ tests) - **EXCELLENT**
2. test_screen.py (143 lines, 13 tests) - **GOOD**
3. test_communication.py (190 lines, 15 tests) - **GOOD**
4. test_loader.py (137 lines, 8 tests) - **GOOD**
5. test_bash_environment.py (321 lines, 23 tests) - **NEEDS WORK**
6. test_python_environment.py (456 lines, 36 tests) - **NEEDS WORK**
7. test_editor_environment.py (574 lines, 38 tests) - **MIXED**
8. test_system_environment.py (166 lines, 8 tests) - **GOOD**
9. test_executor.py (102 lines, 8 tests) - **GOOD**
10. test_declarative.py (308 lines, 19 tests) - **EXCELLENT**
11. test_minimal_orchestrator.py (16 lines, 1 test) - **TRIVIAL**

---

## File 1: test_core_types.py (EXCELLENT)

**Overall Quality**: ⭐⭐⭐⭐⭐ Exemplary use of property-based testing

All tests in this file are **GOOD**. This is exactly what we want:
- Property-based tests using Hypothesis for input space exploration
- Clear requirement-focused test names
- Tests verify actual type requirements (validation, immutability, hashability)
- Good mix of property-based and example-based tests for edge cases

### Representative Examples

**Test: `test_valid_identifiers_accepted`** - **GOOD**
- Uses Hypothesis to generate valid Python identifiers
- Verifies the actual requirement: "Valid Python identifiers should be accepted"
- Tests across the input space, not just hardcoded examples

**Test: `test_invalid_identifiers_rejected`** - **GOOD**
- Uses Hypothesis with filtered strategy
- Verifies rejection requirement with proper error matching
- Comprehensive coverage of invalid inputs

**Test: `test_all_types_are_frozen`** - **GOOD**
- Cross-cutting requirement test
- Verifies immutability requirement for all core types
- Uses property testing approach (test one property across multiple types)

**Recommendations**: None - this file is exemplary and should serve as a template for other tests.

---

## File 2: test_screen.py (GOOD)

**Overall Quality**: ⭐⭐⭐⭐ Well-structured requirement tests

All 13 tests are **GOOD**. Tests focus on actual requirements:
- Screen collection from multiple environments
- Truncation behavior
- Error handling
- Immutability

### Notable Tests

**Test: `test_truncation_applied`** - **GOOD**
- Requirement: Screen truncation must apply max_lines limit and add truncation message
- Verifies structure (line count, message format)
- Tests the actual behavior, not implementation

**Test: `test_environment_get_screen_exception`** - **GOOD**
- Requirement: Exceptions from get_screen() must be caught and displayed as errors
- Verifies error handling requirement
- Tests actual integration behavior

**Recommendations**: None - all tests are requirement-focused and well-structured.

---

## File 3: test_communication.py (GOOD)

**Overall Quality**: ⭐⭐⭐⭐ Solid JSON protocol tests

All 15 tests are **GOOD**. Tests verify actual communication protocol requirements:
- JSON parsing and validation
- Required field checking
- Error handling and messages
- Response serialization

### Notable Tests

**Test: `test_invalid_environment_name`** - **GOOD**
- Requirement: Invalid environment names must be rejected with ParseError
- Integration with EnvironmentName validation
- Proper error message verification

**Test: `test_basic_response`** - **GOOD**
- Requirement: Responses must be valid JSON with specific structure
- Actually parses the JSON to verify structure
- Checks required fields

**Recommendations**: None - communication protocol is well-tested.

---

## File 4: test_loader.py (GOOD)

**Overall Quality**: ⭐⭐⭐⭐ Good loader behavior tests

All 8 tests are **GOOD**. Tests verify actual environment loading requirements:
- Built-in environments loaded
- Ad-hoc environments discovered
- Environment class validation
- Error reporting for invalid environments

### Notable Tests

**Test: `test_load_all_environments_with_valid_adhoc`** - **GOOD**
- Requirement: Ad-hoc environments must be loaded from env/ directory
- Creates actual environment file and verifies loading
- Integration test of the full loading mechanism

**Test: `test_validate_environment_class_rejects_missing_handle_command`** - **GOOD**
- Requirement: Environment classes must have handle_command method
- Tests actual validation logic
- Verifies error message contains method name

**Recommendations**: None - loader behavior is well-tested.

---

## File 5: test_bash_environment.py (NEEDS WORK)

**Overall Quality**: ⭐⭐ Many trivial tests that just verify bash works

**GOOD tests**: 8/23 (35%)
**NEEDS-IMPROVEMENT**: 14/23 (61%)
**REMOVE**: 1/23 (4%)

### GOOD Tests

**Test: `test_multiple_commands_maintain_state`** - **GOOD**
- Requirement: Bash state (env vars, directory) must persist across commands
- Tests our actual value-add (state management)
- Verifies integration of multiple state elements

**Test: `test_working_directory_tracking`** - **GOOD**
- Requirement: Working directory changes must be tracked and shown in screen
- Tests both internal state and screen display
- Verifies actual requirement

**Test: `test_background_job_tracking`** - **GOOD**
- Requirement: Background jobs must be tracked and shown
- Tests our actual feature
- Verifies screen display

**Test: `test_large_output_truncation`** - **GOOD**
- Requirement: Output over MAX_OUTPUT_SIZE must be truncated with warning
- Tests actual limit enforcement
- Verifies truncation message

**Test: `test_screen_shows_state_after_first_use`** - **GOOD**
- Requirement: Screen must show full state (working dir, exit code, jobs) after first command
- Tests screen state management
- Verifies all required state elements present

**Test: `test_help_text_always_shown`** - **GOOD**
- Requirement: Help text must always be shown (freeform environment design)
- Tests progressive disclosure requirement
- Verifies help persistence across multiple uses

**Test: `test_shutdown_cleanup`** - **GOOD**
- Requirement: Shutdown must terminate process
- Tests resource cleanup
- Verifies process termination

**Test: `test_exit_code_persistence`** - **GOOD**
- Requirement: Exit code must persist until next command
- Tests state persistence
- Verifies screen reflects state

### NEEDS-IMPROVEMENT Tests (Trivial bash tests)

**Test: `test_basic_command_execution`** - **NEEDS-IMPROVEMENT**
- Current: Tests that `echo hello` produces "hello"
- Problem: Just verifying bash works, not our code
- Should test: State initialization, process spawning, output capture mechanics

**Test: `test_command_with_exit_code_zero`** - **NEEDS-IMPROVEMENT**
- Current: Tests that `true` has exit code 0
- Problem: Testing bash, not our code
- Should test: Exit code tracking and screen update together (covered by test_exit_code_persistence)

**Test: `test_command_with_nonzero_exit_code`** - **NEEDS-IMPROVEMENT**
- Current: Tests that `false` has exit code 1
- Problem: Testing bash, not our code
- Should test: Verify success=False for nonzero exit (actual requirement)

**Test: `test_multiline_output`** - **NEEDS-IMPROVEMENT**
- Current: Tests that echo with \n produces multiple lines
- Problem: Testing bash, not our code
- Merge with: Output capture test

**Test: `test_stderr_captured`** - **NEEDS-IMPROVEMENT**
- Current: Tests that stderr redirection works
- Problem: Testing bash, not our code
- Should be: Part of comprehensive output capture test

**Test: `test_file_operations`** - **NEEDS-IMPROVEMENT**
- Current: Tests that bash can create and read files
- Problem: Testing bash, not our code
- Remove: Not testing our requirements

**Test: `test_command_chaining`** - **NEEDS-IMPROVEMENT**
- Current: Tests that `&&` and `||` work in bash
- Problem: Testing bash, not our code
- Remove: Not testing our requirements

**Test: `test_empty_command`** - **NEEDS-IMPROVEMENT**
- Current: Tests that empty command succeeds
- Problem: Edge case handling could be useful, but test is trivial
- Keep but improve: Add to edge case test group

**Test: `test_special_characters_in_output`** - **NEEDS-IMPROVEMENT**
- Current: Tests that bash can echo special characters
- Problem: Testing bash, not our code
- Should test: Our output sanitization/encoding if we do any

**Test: `test_command_with_pipes`** - **NEEDS-IMPROVEMENT**
- Current: Tests that pipes work in bash
- Problem: Testing bash, not our code
- Remove: Not testing our requirements

**Test: `test_initial_state_before_first_use`** - **NEEDS-IMPROVEMENT**
- Current: Tests help shown before first use and state info not shown
- Problem: Partially good, but brittle string matching
- Improve: Verify structure, not exact strings

**Test: `test_shutdown_without_starting_process`** - **NEEDS-IMPROVEMENT**
- Current: Tests shutdown works without starting process
- Problem: Edge case but trivial
- Merge: With shutdown_cleanup test

**Test: `test_working_directory_tracking`** - **NEEDS-IMPROVEMENT** (partially)
- Current: Good test but uses string matching "Working directory: {tmpdir}"
- Improve: Parse screen structure to find working directory field

### REMOVE Tests

**Test: `test_command_chaining`** - **REMOVE**
- Reason: Just testing that bash && and || work
- Not testing our code at all

**Recommended Rewrites**:

```python
def test_bash_environment_maintains_state_across_commands():
    """Bash environment must maintain shell state between commands.

    Requirements tested:
    1. Environment variables persist
    2. Working directory persists
    3. Shell functions persist
    4. All state persists in same process
    """
    env = BashEnvironment()
    try:
        # Set up state: env var, directory, function
        with tempfile.TemporaryDirectory() as tmpdir:
            env.handle_command(CommandText("export MY_VAR=hello"))
            env.handle_command(CommandText(f"cd {tmpdir}"))
            env.handle_command(CommandText("my_func() { echo $MY_VAR; }"))

            # Verify all state persists
            response = env.handle_command(CommandText("echo $MY_VAR"))
            assert "hello" in response.output, "Env var should persist"

            response = env.handle_command(CommandText("pwd"))
            assert tmpdir in response.output, "Directory should persist"

            response = env.handle_command(CommandText("my_func"))
            assert "hello" in response.output, "Function should persist"
    finally:
        env.shutdown()


def test_bash_environment_screen_reflects_state():
    """Screen must show current working directory, exit code, and background jobs.

    Requirements tested:
    1. Working directory shown in screen
    2. Last exit code shown in screen
    3. Background jobs shown in screen
    4. Screen updates after each command
    """
    env = BashEnvironment()
    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            # Change state
            env.handle_command(CommandText(f"cd {tmpdir}"))
            env.handle_command(CommandText("false"))  # Exit code 1
            env.handle_command(CommandText("sleep 10 &"))  # Background job

            # Parse screen to verify state
            screen = env.get_screen()
            lines = screen.content.split('\n')

            # Verify working directory
            wd_lines = [l for l in lines if 'Working directory:' in l]
            assert len(wd_lines) == 1, "Screen must show working directory"
            assert tmpdir in wd_lines[0], f"Working directory must show {tmpdir}"

            # Verify exit code
            exit_lines = [l for l in lines if 'Last exit code:' in l]
            assert len(exit_lines) == 1, "Screen must show exit code"
            assert '1' in exit_lines[0], "Exit code must be 1"

            # Verify background job
            assert 'sleep' in screen.content or 'Background jobs:' in screen.content, \
                "Screen must show background job"
    finally:
        env.shutdown()


def test_bash_environment_captures_stdout_and_stderr():
    """Output capture must include both stdout and stderr.

    Requirements tested:
    1. Stdout captured in output
    2. Stderr captured in output
    3. Output interleaving preserved
    """
    env = BashEnvironment()
    try:
        # Command that writes to both stdout and stderr
        cmd = "echo 'stdout message' && echo 'stderr message' >&2"
        response = env.handle_command(CommandText(cmd))

        assert response.success is True, "Command should succeed"
        assert 'stdout message' in response.output, "Stdout must be captured"
        assert 'stderr message' in response.output, "Stderr must be captured"
    finally:
        env.shutdown()


def test_bash_environment_tracks_exit_codes():
    """Exit codes must be tracked and reflected in response.success.

    Requirements tested:
    1. Zero exit code → success=True
    2. Non-zero exit code → success=False
    3. Exit code shown in screen
    """
    env = BashEnvironment()
    try:
        # Success case
        response = env.handle_command(CommandText("true"))
        assert response.success is True, "Exit code 0 should mean success"

        screen = env.get_screen()
        assert "Last exit code: 0" in screen.content

        # Failure case
        response = env.handle_command(CommandText("false"))
        assert response.success is False, "Exit code 1 should mean failure"

        screen = env.get_screen()
        assert "Last exit code: 1" in screen.content
    finally:
        env.shutdown()
```

---

## File 6: test_python_environment.py (NEEDS WORK)

**Overall Quality**: ⭐⭐ Many trivial tests that just verify Python works

**GOOD tests**: 13/36 (36%)
**NEEDS-IMPROVEMENT**: 23/36 (64%)

### GOOD Tests

**Test: `test_variable_persistence`** - **GOOD**
- Requirement: Variables must persist across commands
- Tests our actual value-add (REPL state management)
- Verifies multiple command sequence

**Test: `test_variable_tracking_in_screen`** - **GOOD**
- Requirement: Variables must be displayed in screen with types
- Tests screen state integration
- Verifies type tracking

**Test: `test_variable_ordering_by_recent_use`** - **GOOD**
- Requirement: Variables must be ordered by recent use (LRU)
- Tests actual feature
- Verifies ordering logic

**Test: `test_working_directory_tracking`** - **GOOD**
- Requirement: Working directory must be displayed in screen
- Tests state tracking

**Test: `test_working_directory_change`** - **GOOD**
- Requirement: Working directory changes must be reflected in screen
- Tests state update

**Test: `test_exception_handling`** - **GOOD**
- Requirement: Exceptions must be captured in output (not crash environment)
- Tests error handling
- Verifies graceful failure

**Test: `test_syntax_error_handling`** - **GOOD**
- Requirement: Syntax errors must be captured in output
- Tests error handling

**Test: `test_no_variables_displayed_initially`** - **GOOD**
- Requirement: Screen must show "(no variables)" when none exist
- Tests display logic

**Test: `test_private_variables_excluded`** - **GOOD**
- Requirement: Variables starting with _ must be excluded from display
- Tests filtering logic
- Verifies privacy convention

**Test: `test_screen_after_first_use`** - **GOOD**
- Requirement: Screen must show full state after first command
- Tests state initialization

**Test: `test_help_text_always_shown`** - **GOOD**
- Requirement: Help text must always be shown (freeform environment design)
- Tests progressive disclosure

**Test: `test_shutdown_cleanup`** - **GOOD**
- Requirement: Shutdown must terminate process
- Tests resource cleanup

**Test: `test_variable_deletion`** - **GOOD**
- Requirement: Deleted variables must be removed from screen
- Tests state update on deletion
- Verifies del statement handling

### NEEDS-IMPROVEMENT Tests (Trivial Python tests)

**Test: `test_basic_expression_evaluation`** - **NEEDS-IMPROVEMENT**
- Current: Tests that `2 + 2` evaluates to 4
- Problem: Testing Python, not our code
- Remove: Not testing our requirements

**Test: `test_print_statement`** - **NEEDS-IMPROVEMENT**
- Current: Tests that print() works
- Problem: Testing Python, not our code
- Remove: Not testing our requirements

**Test: `test_multi_line_code_function_definition`** - **NEEDS-IMPROVEMENT**
- Current: Tests that Python can define functions
- Problem: Testing Python, not our code
- Should test: Multiline code parsing/execution if we do anything special

**Test: `test_multi_line_code_class_definition`** - **NEEDS-IMPROVEMENT**
- Current: Tests that Python can define classes
- Problem: Testing Python, not our code
- Remove: Not testing our requirements

**Test: `test_import_statement`** - **NEEDS-IMPROVEMENT**
- Current: Tests that Python imports work
- Problem: Testing Python, not our code
- Remove: Not testing our requirements

**Test: `test_from_import_statement`** - **NEEDS-IMPROVEMENT**
- Current: Tests that from...import works
- Problem: Testing Python, not our code
- Remove: Not testing our requirements

**Test: `test_list_comprehension`** - **NEEDS-IMPROVEMENT**
- Current: Tests that list comprehensions work
- Problem: Testing Python, not our code
- Remove: Not testing our requirements

**Test: `test_dictionary_operations`** - **NEEDS-IMPROVEMENT**
- Current: Tests that dictionaries work
- Problem: Testing Python, not our code
- Remove: Not testing our requirements

**Test: `test_multiple_variables_with_same_usage`** - **NEEDS-IMPROVEMENT**
- Current: Good test idea (multiple variables used in same command)
- Problem: Complex test checking ordering details
- Simplify: Focus on requirement "variables used together are all marked recent"

**Test: `test_long_running_computation`** - **NEEDS-IMPROVEMENT**
- Current: Tests that sum(range(1000000)) works
- Problem: Testing Python, not our code
- Remove or repurpose: Could test timeout if we have one

**Test: `test_string_with_newlines`** - **NEEDS-IMPROVEMENT**
- Current: Tests that Python can print strings with newlines
- Problem: Testing Python, not our code
- Remove: Not testing our requirements

**Test: `test_empty_command`** - **NEEDS-IMPROVEMENT**
- Current: Tests that empty command succeeds
- Problem: Edge case but trivial
- Keep minimal: Part of edge case suite

**Test: `test_comment_only_command`** - **NEEDS-IMPROVEMENT**
- Current: Tests that comments work
- Problem: Testing Python, not our code
- Remove: Not testing our requirements

**Test: `test_reassign_variable_with_different_type`** - **NEEDS-IMPROVEMENT**
- Current: Tests that variable can change type
- Problem: Testing Python, not our code
- Improve: Test that our type display updates (which it does test)

**Test: `test_initial_state_before_first_use`** - **NEEDS-IMPROVEMENT**
- Current: Tests help shown before first use
- Problem: Brittle string matching
- Improve: Verify structure

**Test: `test_shutdown_without_starting_process`** - **NEEDS-IMPROVEMENT**
- Current: Tests shutdown works without starting
- Problem: Edge case but trivial
- Merge: With shutdown_cleanup

All remaining tests (15 more) follow similar patterns - they test Python language features, not our Python environment wrapper.

**Recommended Consolidation**:

```python
def test_python_environment_maintains_repl_state():
    """Python REPL must maintain state (variables, imports) across commands.

    Requirements tested:
    1. Variables persist across commands
    2. Imports persist across commands
    3. Functions persist across commands
    4. Classes persist across commands
    """
    env = PythonEnvironment()
    try:
        # Create various state elements
        env.handle_command(CommandText("import math"))
        env.handle_command(CommandText("x = 42"))
        env.handle_command(CommandText("def foo(): return x"))
        env.handle_command(CommandText("class Bar: pass"))

        # Verify all persist
        response = env.handle_command(CommandText("math.pi"))
        assert "3.14" in response.output, "Import should persist"

        response = env.handle_command(CommandText("x * 2"))
        assert "84" in response.output, "Variable should persist"

        response = env.handle_command(CommandText("foo()"))
        assert "42" in response.output, "Function should persist"

        response = env.handle_command(CommandText("Bar()"))
        assert response.success, "Class should persist"
    finally:
        env.shutdown()


def test_python_environment_tracks_variables_in_screen():
    """Screen must show user-defined variables with types, ordered by recent use.

    Requirements tested:
    1. Variables shown with types (x: int)
    2. Private variables (_x) excluded
    3. Variables ordered by recent use (LRU)
    4. Deleted variables removed
    5. Type changes reflected
    """
    env = PythonEnvironment()
    try:
        # Create variables
        env.handle_command(CommandText("a = 1"))
        env.handle_command(CommandText("_private = 2"))
        env.handle_command(CommandText("b = 'hello'"))

        screen = env.get_screen()

        # Verify display with types
        assert "a: int" in screen.content, "Must show variable with type"
        assert "b: str" in screen.content, "Must show string type"
        assert "_private" not in screen.content, "Must exclude private variables"

        # Use 'a' to move it to front
        env.handle_command(CommandText("print(a)"))
        screen = env.get_screen()
        lines = screen.content.split('\n')
        var_lines = [l for l in lines if l.strip().startswith(('a:', 'b:'))]
        assert var_lines[0].strip().startswith('a:'), "Most recently used should be first"

        # Delete variable
        env.handle_command(CommandText("del a"))
        screen = env.get_screen()
        assert "a:" not in screen.content, "Deleted variable must be removed"

        # Change type
        env.handle_command(CommandText("b = 123"))
        screen = env.get_screen()
        assert "b: int" in screen.content, "Type change must be reflected"
        assert "b: str" not in screen.content
    finally:
        env.shutdown()


def test_python_environment_handles_errors_gracefully():
    """Errors must be captured in output without crashing environment.

    Requirements tested:
    1. Runtime exceptions captured
    2. Syntax errors captured
    3. Environment continues working after error
    """
    env = PythonEnvironment()
    try:
        # Runtime exception
        response = env.handle_command(CommandText("1 / 0"))
        assert response.success is True, "Command executed even with exception"
        assert "ZeroDivisionError" in response.output, "Exception must be in output"

        # Syntax error
        response = env.handle_command(CommandText("if True"))
        assert response.success is True, "Command executed even with syntax error"
        assert "SyntaxError" in response.output, "Syntax error must be in output"

        # Environment still works
        response = env.handle_command(CommandText("2 + 2"))
        assert "4" in response.output, "Environment must continue working after errors"
    finally:
        env.shutdown()
```

---

## File 7: test_editor_environment.py (MIXED)

**Overall Quality**: ⭐⭐⭐ Good view/edit tests, some overly detailed

**GOOD tests**: 28/38 (74%)
**NEEDS-IMPROVEMENT**: 10/38 (26%)

This file is generally better than bash/python tests. Most tests verify actual editor requirements.

### GOOD Tests (Selection)

**Test: `test_view_command_simple`** - **GOOD**
- Requirement: view command must create view with pattern matching
- Tests actual feature
- Verifies screen display

**Test: `test_view_command_multiple_matches`** - **GOOD**
- Requirement: Multiple pattern matches must be tracked
- Tests match navigation feature

**Test: `test_edit_command`** - **GOOD**
- Requirement: edit command must modify file at specified lines
- Tests actual editing feature
- Verifies file changes

**Test: `test_edit_command_outside_view`** - **GOOD**
- Requirement: Editing lines not in a view must fail with error
- Tests safety requirement
- Verifies error message

**Test: `test_edit_command_file_changed`** - **GOOD**
- Requirement: Editing must fail if file changed since view was created
- Tests safety requirement (prevents race conditions)
- Verifies error detection

**Test: `test_max_views_limit`** - **GOOD**
- Requirement: Maximum 5 views, oldest auto-closed when exceeded
- Tests resource limit
- Verifies LRU eviction

**Test: `test_view_patterns_not_found`** - **GOOD**
- Requirement: Views with unfound patterns must be marked BROKEN and auto-removed
- Tests error handling
- Verifies cleanup behavior

**Test: `test_binary_file_detection`** - **GOOD**
- Requirement: Binary files must be rejected
- Tests safety requirement
- Verifies error message

**Test: `test_line_truncation`** - **GOOD**
- Requirement: Long lines must be truncated with "..."
- Tests display requirement
- Verifies truncation marker

### NEEDS-IMPROVEMENT Tests

**Test: `test_initialization`** - **NEEDS-IMPROVEMENT**
- Current: Tests initial screen shows "(no views)"
- Problem: Brittle string matching
- Improve: Verify structure

**Test: `test_view_command_with_label`** - **NEEDS-IMPROVEMENT**
- Current: Tests that label appears in screen with quotes
- Problem: Testing exact formatting detail
- Improve: Just verify label is associated with view

**Test: `test_next_match_command`** - **NEEDS-IMPROVEMENT**
- Current: Good test but checks for specific "Showing match" string in response
- Improve: Verify screen shows different content (next match)

**Test: `test_invalid_commands`** - **NEEDS-IMPROVEMENT**
- Current: Tests multiple invalid commands in one test
- Problem: Should be separate tests for each requirement
- Split: One test per error type

**Test: `test_shutdown`** - **NEEDS-IMPROVEMENT**
- Current: Just calls shutdown and checks it doesn't raise
- Problem: Trivial test
- Remove or merge: With other shutdown tests

### Progressive Disclosure Tests - **ALL GOOD**

Tests for progressive disclosure (help system) are all **GOOD**:
- `test_initial_screen_shows_long_help_for_all_commands`
- `test_progressive_disclosure_after_using_view`
- `test_progressive_disclosure_multiple_commands`
- `test_progressive_disclosure_all_commands_used`
- `test_help_text_updates_per_command_not_per_environment`

These tests verify actual requirements for the help system and use appropriate structural checks.

**Recommendations**: Minor improvements to reduce string matching brittleness. Overall file is in good shape.

---

## File 8: test_system_environment.py (GOOD)

**Overall Quality**: ⭐⭐⭐⭐ All tests verify actual requirements

All 8 tests are **GOOD**. Tests verify system environment display requirements:
- Project directory shown
- AGENTS.md content included when present
- Git status shown in git repos
- File tree shown

### Notable Tests

**Test: `test_screen_shows_git_status_in_git_repo`** - **GOOD**
- Requirement: Git status must be shown in git repositories
- Actually initializes a git repo for testing
- Integration test of git detection

**Test: `test_screen_without_git_repo`** - **GOOD**
- Requirement: Screen must work gracefully in non-git directories
- Tests fallback behavior

**Test: `test_has_no_commands_initially`** - **GOOD**
- Requirement: SystemEnvironment has no commands (read-only)
- Tests architectural requirement

**Recommendations**: None - all tests are requirement-focused.

---

## File 9: test_executor.py (GOOD)

**Overall Quality**: ⭐⭐⭐⭐ All tests verify routing and error handling

All 8 tests are **GOOD**. Tests verify executor requirements:
- Command routing to correct environment
- Unknown environment handling
- Exception handling
- Error messages

### Notable Tests

**Test: `test_unknown_environment_shows_available`** - **GOOD**
- Requirement: Error for unknown environment must list available environments
- Tests helpful error message
- Verifies user experience requirement

**Test: `test_environment_exception_caught`** - **GOOD**
- Requirement: Exceptions from environments must be caught and returned as errors
- Tests error isolation
- Verifies exception doesn't propagate

**Recommendations**: None - executor behavior is well-tested.

---

## File 10: test_declarative.py (EXCELLENT)

**Overall Quality**: ⭐⭐⭐⭐⭐ Comprehensive tests of declarative environment abstraction

All 19 tests are **GOOD**. Tests verify DeclarativeEnvironment base class requirements:
- Command decorator and metadata
- Command discovery
- Command routing
- Usage tracking
- Progressive disclosure
- Error handling

### Notable Tests

**Test: `test_command_decorator_attaches_metadata`** - **GOOD**
- Requirement: @command decorator must attach metadata to methods
- Tests decorator behavior
- Verifies metadata structure

**Test: `test_handle_command_routes_correctly`** - **GOOD**
- Requirement: handle_command must route to correct method based on command name
- Tests routing logic
- Verifies method invocation

**Test: `test_get_screen_progressive_disclosure`** - **GOOD**
- Requirement: get_screen must show SHORT help for used commands, LONG for unused
- Tests progressive disclosure feature
- Verifies help format changes

**Test: `test_multiple_environments_separate_usage_tracking`** - **GOOD**
- Requirement: Different environment instances must track usage separately
- Tests isolation
- Verifies no shared state

**Recommendations**: None - this file is exemplary and tests a key abstraction comprehensively.

---

## File 11: test_minimal_orchestrator.py (TRIVIAL)

**Overall Quality**: ⭐ Single trivial import test

**REMOVE**: 1/1
- `test_imports` - Just verifies imports work, provides no value

**Recommendation**: Remove this file or consolidate into another test file.

---

## Overall Recommendations

### High Priority: Rewrite Environment Tests

**Bash and Python environment tests** need significant work:
- **Remove**: ~40 tests that just verify bash/python work (not our code)
- **Consolidate**: Remaining tests into focused requirement tests
- **Add**: Missing requirement tests (see below)

### Consolidation Strategy

Replace 23 bash tests with ~8 focused tests:
1. `test_bash_environment_maintains_state_across_commands` - State persistence
2. `test_bash_environment_screen_reflects_state` - Screen display
3. `test_bash_environment_captures_output` - Stdout/stderr capture
4. `test_bash_environment_tracks_exit_codes` - Exit code handling
5. `test_bash_environment_tracks_background_jobs` - Job tracking
6. `test_bash_environment_enforces_output_limits` - Truncation
7. `test_bash_environment_progressive_disclosure` - Help system
8. `test_bash_environment_lifecycle` - Initialization and shutdown

Replace 36 python tests with ~7 focused tests:
1. `test_python_environment_maintains_repl_state` - State persistence
2. `test_python_environment_tracks_variables_in_screen` - Variable display
3. `test_python_environment_handles_errors_gracefully` - Error handling
4. `test_python_environment_tracks_working_directory` - Directory display
5. `test_python_environment_progressive_disclosure` - Help system
6. `test_python_environment_lifecycle` - Initialization and shutdown
7. `test_python_environment_excludes_private_variables` - Filtering logic

### Missing Requirement Tests

**Bash environment**:
- Response success/failure mapping to exit codes (partially covered)
- Output size limits enforcement (covered by test_large_output_truncation)
- Process lifecycle (spawn, communicate, cleanup)

**Python environment**:
- REPL crash recovery (if implemented)
- Variable limit enforcement (if we have one)
- Output capture from expressions vs statements

**Editor environment**:
- View cache invalidation on file changes (covered)
- Concurrent view update behavior
- Pattern matching edge cases (empty patterns, etc.)

### Update All Test Names

All tests should follow the pattern:
```python
def test_<environment>_<requirement_as_fact>():
    """<Requirement statement>

    Requirements tested:
    1. Specific requirement one
    2. Specific requirement two
    ...
    """
```

### Keep Excellent Tests as Examples

Files to use as templates for other tests:
- `test_core_types.py` - Property-based testing with Hypothesis
- `test_declarative.py` - Comprehensive abstraction testing
- `test_screen.py` - Clean requirement-focused tests

### Next Steps

1. **Start with bash environment**: Rewrite test_bash_environment.py
2. **Then python environment**: Rewrite test_python_environment.py
3. **Minor improvements**: Fix string matching in editor tests
4. **Add missing tests**: Fill gaps identified above
5. **Verify build**: Run `nix build .#orchestrator` after each change
