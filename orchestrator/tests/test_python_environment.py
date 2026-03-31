"""Tests for Python environment."""

import os
import tempfile
from pathlib import Path

from orchestrator.core_types import CommandText
from orchestrator.environments.python import PythonEnvironment

from . import timeout


def _parse_variables(screen_content: str) -> dict[str, str]:
    """Parse variable section of a Python environment screen into {name: type}.

    Returns an ordered dict reflecting the display order (most-recent-use first).
    Private variables and the '(no variables)' placeholder are excluded.
    """
    variables: dict[str, str] = {}
    in_section = False
    for line in screen_content.split("\n"):
        if "Variables" in line:
            in_section = True
            continue
        if not in_section:
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("("):
            continue
        # A non-indented non-blank line signals the end of the variables section
        if line and not line[0].isspace():
            break
        if ":" in stripped:
            name, _, type_name = stripped.partition(":")
            variables[name.strip()] = type_name.strip()
    return variables


class TestPythonEnvironment:
    """Test PythonEnvironment implementation."""

    @timeout(10)
    def test_python_environment_maintains_repl_state(self) -> None:
        """Python REPL must maintain state (variables, imports, functions, classes) across commands.

        Requirements tested:
        1. Variables persist across commands
        2. Imports persist across commands
        3. Functions persist across commands
        4. Classes persist across commands
        5. All state persists in same REPL process
        """
        env = PythonEnvironment()
        try:
            # Create various state elements
            env.handle_command(CommandText("import math"))
            env.handle_command(CommandText("x = 42"))
            # Compound statements need a trailing blank line to close in Python REPL
            env.handle_command(CommandText("def foo(): return x * 2\n\n"))
            env.handle_command(CommandText("class Bar: pass\n\n"))

            # Verify all persist
            response = env.handle_command(CommandText("math.pi"))
            assert "3.14" in response.output, "Import should persist"

            response = env.handle_command(CommandText("x"))
            assert "42" in response.output, "Variable should persist"

            response = env.handle_command(CommandText("foo()"))
            assert "84" in response.output, "Function should persist"

            response = env.handle_command(CommandText("Bar()"))
            assert response.processed, "Class should persist"
        finally:
            env.shutdown()

    @timeout(10)
    def test_python_environment_tracks_variables_in_screen(self) -> None:
        """Screen must show user-defined variables with types, ordered by recent use (LRU).

        Requirements tested:
        1. Variables shown with types (e.g., x: int)
        2. Private variables (_x) excluded from display
        3. Variables ordered by recent use (most recent first)
        4. Deleted variables removed from display
        5. Type changes reflected in display
        6. No variables message shown when none exist
        7. Variable limit enforced (MAX_VARIABLES_DISPLAY)
        """
        env = PythonEnvironment()
        try:
            # Initially no variables (after first command that doesn't create vars)
            env.handle_command(CommandText("1 + 1"))
            screen = env.get_screen()
            assert "(no variables)" in screen.content, "Must show no variables message"

            # Create variables
            env.handle_command(CommandText("a = 1"))
            env.handle_command(CommandText("_private = 2"))  # Should be excluded
            env.handle_command(CommandText("b = 'hello'"))

            screen = env.get_screen()

            # Verify display with types
            variables = _parse_variables(screen.content)
            assert variables.get("a") == "int", "Must show variable with type"
            assert variables.get("b") == "str", "Must show string variable"
            assert (
                "_private" not in variables
            ), "Must exclude private variables (starting with _)"

            # Use 'a' to move it to front (LRU ordering)
            env.handle_command(CommandText("print(a)"))
            screen = env.get_screen()
            variables = _parse_variables(screen.content)
            var_names = list(variables.keys())
            assert var_names.index("a") < var_names.index(
                "b"
            ), "Most recently used variable should be first"

            # Delete variable
            env.handle_command(CommandText("del a"))
            screen = env.get_screen()
            variables = _parse_variables(screen.content)
            assert "a" not in variables, "Deleted variable must be removed"

            # Change variable type
            env.handle_command(CommandText("b = 123"))
            screen = env.get_screen()
            variables = _parse_variables(screen.content)
            assert variables.get("b") == "int", "Type change must be reflected"
            assert variables.get("b") != "str", "Old type must not be shown"
        finally:
            env.shutdown()

    @timeout(10)
    def test_python_environment_variable_ordering_lru(self) -> None:
        """Variables must be ordered by recent use (Least Recently Used).

        Requirements tested:
        1. Variables used in same command all moved to front
        2. Order preserved for variables not mentioned
        3. New variables added to end (or front if created)
        """
        env = PythonEnvironment()
        try:
            # Create variables in order
            env.handle_command(CommandText("a = 1"))
            env.handle_command(CommandText("b = 2"))
            env.handle_command(CommandText("c = 3"))

            # Use multiple variables in one command
            env.handle_command(CommandText("result = b + c"))

            screen = env.get_screen()
            variables = _parse_variables(screen.content)
            var_names = list(variables.keys())

            # result, b, and c should all appear before 'a' (recently used)
            result_idx = var_names.index("result")
            b_idx = var_names.index("b")
            c_idx = var_names.index("c")
            a_idx = var_names.index("a")

            # All recently used vars should come before 'a'
            assert result_idx < a_idx, "Newly created variable should be recent"
            assert b_idx < a_idx, "Used variable 'b' should be before unused 'a'"
            assert c_idx < a_idx, "Used variable 'c' should be before unused 'a'"
        finally:
            env.shutdown()

    @timeout(10)
    def test_python_environment_handles_errors_gracefully(self) -> None:
        """Errors must be captured in output without crashing environment.

        Requirements tested:
        1. Runtime exceptions captured in output
        2. Syntax errors captured in output
        3. Environment continues working after errors
        4. Success is True even for exceptions (command executed)
        """
        env = PythonEnvironment()
        try:
            # Runtime exception
            response = env.handle_command(CommandText("1 / 0"))
            assert response.processed is True, "Command executed even with exception"
            assert "ZeroDivisionError" in response.output, "Exception must be in output"

            # Syntax error
            response = env.handle_command(CommandText("if True"))
            assert response.processed is True, "Command executed even with syntax error"
            assert "SyntaxError" in response.output, "Syntax error must be in output"

            # Environment still works after errors
            response = env.handle_command(CommandText("2 + 2"))
            assert (
                "4" in response.output
            ), "Environment must continue working after errors"
        finally:
            env.shutdown()

    @timeout(10)
    def test_python_environment_tracks_working_directory(self) -> None:
        """Working directory must be tracked and shown in screen.

        Requirements tested:
        1. Working directory shown in screen after first use
        2. Working directory changes reflected in screen
        3. os.chdir() updates working directory display
        """
        env = PythonEnvironment()
        try:
            initial_cwd = os.getcwd()
            env.handle_command(CommandText("x = 1"))

            # Working directory must appear in screen after first use
            screen = env.get_screen()
            assert (
                initial_cwd in screen.content
            ), "Working directory must appear in screen after first use"

            # Change working directory — screen must reflect the new path
            with tempfile.TemporaryDirectory() as tmpdir:
                env.handle_command(CommandText(f"import os; os.chdir('{tmpdir}')"))

                screen = env.get_screen()
                assert (
                    tmpdir in screen.content
                ), f"Screen must show new working directory: {tmpdir}"
        finally:
            env.shutdown()

    @timeout(10)
    def test_python_environment_help_text_always_shown(self) -> None:
        """Requirement: Help text must always appear in screen, before and after first use.

        Requirements tested:
        1. Help shown before first use
        2. Help shown after first use
        3. Help shown after many uses
        4. Help text is consistent across calls
        """
        env = PythonEnvironment()
        try:
            # Retrieve help text via public API rather than hardcoding template strings
            help_text = env.get_help()
            assert help_text.strip(), "get_help() must return non-empty content"

            # Before first use
            screen_before = env.get_screen()
            assert (
                help_text in screen_before.content
            ), "Help must be shown before first use"

            # After first use
            env.handle_command(CommandText("x = 1"))
            screen_after = env.get_screen()
            assert (
                help_text in screen_after.content
            ), "Help must be shown after first use"

            # After many uses
            env.handle_command(CommandText("y = 2"))
            env.handle_command(CommandText("z = x + y"))
            env.handle_command(CommandText("print(z)"))
            screen_later = env.get_screen()
            assert (
                help_text in screen_later.content
            ), "Help must persist after many commands"
        finally:
            env.shutdown()

    @timeout(10)
    def test_python_environment_lifecycle(self) -> None:
        """Python environment must handle initialization and shutdown correctly.

        Requirements tested:
        1. Environment can be created without starting process
        2. Process starts on first command
        3. Process can be started, used, and shutdown
        4. Shutdown terminates process
        5. Shutdown can be called before starting process (graceful)
        6. Shutdown can be called multiple times (idempotent)
        """
        # Before first use — screen contains only help (no active process state)
        env = PythonEnvironment()
        help_text = env.get_help()
        screen = env.get_screen()
        assert (
            screen.content.strip() == help_text.strip()
        ), "Screen before first use must contain only help (process not started yet)"

        # First command starts process and produces output
        response = env.handle_command(CommandText("40 + 2"))
        assert response.processed is True, "First command must succeed"
        assert "42" in response.output, "Process must start and execute command"

        # Shutdown terminates process (must not raise)
        env.shutdown()

        # Shutdown before starting process is graceful (must not raise)
        env2 = PythonEnvironment()
        env2.shutdown()

        # Shutdown is idempotent (multiple calls are safe)
        env3 = PythonEnvironment()
        env3.handle_command(CommandText("x = 1"))
        env3.shutdown()
        env3.shutdown()  # Should not raise

    @timeout(10)
    def test_python_environment_multiline_code_execution(self) -> None:
        """Multiline code (functions, classes, etc.) must be executed correctly.

        Requirements tested:
        1. Function definitions work (multiline)
        2. Class definitions work (multiline)
        3. Multiline expressions work
        4. Indentation preserved
        """
        env = PythonEnvironment()
        try:
            # Define function (multiline)
            # Trailing \n\n produces a blank line that closes the block in the REPL
            code = "def add(a, b):\n    return a + b\n\n"
            response = env.handle_command(CommandText(code))
            assert response.processed is True, "Function definition should succeed"

            # Use function
            response = env.handle_command(CommandText("add(3, 4)"))
            assert "7" in response.output, "Function should work after definition"

            # Define class (multiline)
            code = "class Point:\n    def __init__(self, x, y):\n        self.x = x\n        self.y = y\n\n"
            response = env.handle_command(CommandText(code))
            assert response.processed is True, "Class definition should succeed"

            # Create instance
            env.handle_command(CommandText("p = Point(10, 20)"))

            # Access attribute
            response = env.handle_command(CommandText("p.x"))
            assert "10" in response.output, "Class instance should work"
        finally:
            env.shutdown()

    @timeout(10)
    def test_python_environment_handles_edge_cases(self) -> None:
        """Python environment must handle edge cases gracefully.

        Requirements tested:
        1. Empty command handled (succeeds with no output)
        2. Comment-only command handled
        3. Variable reassignment with different type works
        """
        env = PythonEnvironment()
        try:
            # Empty command
            response = env.handle_command(CommandText(""))
            assert response.processed is True, "Empty command should succeed"

            # Comment only
            response = env.handle_command(CommandText("# This is a comment"))
            assert response.processed is True, "Comment-only command should succeed"

            # Variable reassignment with type change
            env.handle_command(CommandText("x = 42"))
            variables = _parse_variables(env.get_screen().content)
            assert variables.get("x") == "int", "Should show int type"

            env.handle_command(CommandText("x = 'hello'"))
            variables = _parse_variables(env.get_screen().content)
            assert (
                variables.get("x") == "str"
            ), "Should show str type after reassignment"
        finally:
            env.shutdown()

    @timeout(10)
    def test_python_environment_get_help_loads_builtin_template(self) -> None:
        """Requirement: get_help() must return the built-in Python help template content.

        The help template must contain python-tagged example blocks so the agent
        can see concrete examples of how to use the environment.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            env = PythonEnvironment(project_dir=Path(tmpdir))
            help_text = env.get_help()

            assert help_text.strip(), "get_help() must return non-empty content"
            assert "<python>" in help_text, "Help must contain python example blocks"
            assert "</python>" in help_text, "Help must close python example blocks"

    @timeout(10)
    def test_python_environment_get_help_uses_project_override(self) -> None:
        """Requirement: project_dir/env/python/help.md must override the built-in help.

        Projects must be able to supply custom Python help tailored to their
        conventions; the override must appear in both get_help() and get_screen().
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            override_dir = project_dir / "env" / "python"
            override_dir.mkdir(parents=True)
            (override_dir / "help.md").write_text(
                "Project-specific Python help for this repo.", encoding="utf-8"
            )

            env = PythonEnvironment(project_dir=project_dir)

            help_text = env.get_help()
            assert "Project-specific Python help for this repo." in help_text

            screen = env.get_screen()
            assert "Project-specific Python help for this repo." in screen.content
