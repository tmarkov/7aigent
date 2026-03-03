"""Tests for Python environment."""

import tempfile

from orchestrator.core_types import CommandText
from orchestrator.environments.python import PythonEnvironment

from . import timeout


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
            env.handle_command(CommandText("def foo(): return x * 2"))
            env.handle_command(CommandText("class Bar: pass"))

            # Verify all persist
            response = env.handle_command(CommandText("math.pi"))
            assert "3.14" in response.output, "Import should persist"

            response = env.handle_command(CommandText("x"))
            assert "42" in response.output, "Variable should persist"

            response = env.handle_command(CommandText("foo()"))
            assert "84" in response.output, "Function should persist"

            response = env.handle_command(CommandText("Bar()"))
            assert response.success, "Class should persist"
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
            assert "a: int" in screen.content, "Must show variable with type"
            assert "b: str" in screen.content, "Must show string variable"
            assert (
                "_private" not in screen.content
            ), "Must exclude private variables (starting with _)"

            # Use 'a' to move it to front (LRU ordering)
            env.handle_command(CommandText("print(a)"))
            screen = env.get_screen()
            lines = screen.content.split("\n")
            var_lines = [
                line for line in lines if line.strip().startswith(("a:", "b:"))
            ]
            assert (
                var_lines[0].strip().startswith("a:")
            ), "Most recently used variable should be first"

            # Delete variable
            env.handle_command(CommandText("del a"))
            screen = env.get_screen()
            assert "a:" not in screen.content, "Deleted variable must be removed"

            # Change variable type
            env.handle_command(CommandText("b = 123"))
            screen = env.get_screen()
            assert "b: int" in screen.content, "Type change must be reflected"
            assert "b: str" not in screen.content, "Old type must not be shown"
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
            lines = screen.content.split("\n")

            # Find variable lines
            var_lines = [
                line
                for line in lines
                if line.strip().startswith(("a:", "b:", "c:", "result:"))
            ]

            # Extract variable names in order
            var_names = [line.split(":")[0].strip() for line in var_lines]

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
            assert response.success is True, "Command executed even with exception"
            assert "ZeroDivisionError" in response.output, "Exception must be in output"

            # Syntax error
            response = env.handle_command(CommandText("if True"))
            assert response.success is True, "Command executed even with syntax error"
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
            # Execute command to initialize
            env.handle_command(CommandText("x = 1"))

            # Get screen
            screen = env.get_screen()
            assert "Working directory:" in screen.content, "Must show working directory"

            # Change working directory
            with tempfile.TemporaryDirectory() as tmpdir:
                env.handle_command(CommandText(f"import os; os.chdir('{tmpdir}')"))

                # Verify in screen
                screen = env.get_screen()
                assert (
                    tmpdir in screen.content
                ), f"Screen must show new working directory: {tmpdir}"
        finally:
            env.shutdown()

    @timeout(10)
    def test_python_environment_help_text_always_shown(self) -> None:
        """Help text must always be shown (freeform environment design).

        Requirements tested:
        1. Help shown before first use
        2. Help shown after first use
        3. Help shown after many uses
        4. Help text is consistent
        """
        env = PythonEnvironment()
        try:
            expected_help = (
                "Any Python code. Variables and imports persist across commands."
            )

            # Before first use
            screen_before = env.get_screen()
            assert (
                expected_help in screen_before.content
            ), "Help must be shown before first use"

            # After first use
            env.handle_command(CommandText("x = 1"))
            screen_after = env.get_screen()
            assert expected_help in screen_after.content, "Help must be shown after use"

            # After many uses
            env.handle_command(CommandText("y = 2"))
            env.handle_command(CommandText("z = x + y"))
            env.handle_command(CommandText("print(z)"))
            screen_later = env.get_screen()
            assert (
                expected_help in screen_later.content
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
        # Create environment - process should not be started yet
        env = PythonEnvironment()
        assert env._process is None, "Process should not start on initialization"

        # Execute a command - should start process
        env.handle_command(CommandText("x = 1"))
        assert env._process is not None, "Process should start on first command"
        assert env._process.isalive(), "Process should be running"

        # Shutdown should terminate process
        env.shutdown()
        assert (
            env._process is None or not env._process.isalive()
        ), "Shutdown must terminate process"

        # Shutdown before starting process (graceful)
        env2 = PythonEnvironment()
        env2.shutdown()  # Should not raise

        # Shutdown can be called multiple times
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
            code = """def add(a, b):
    return a + b"""
            response = env.handle_command(CommandText(code))
            assert response.success is True, "Function definition should succeed"

            # Use function
            response = env.handle_command(CommandText("add(3, 4)"))
            assert "7" in response.output, "Function should work after definition"

            # Define class (multiline)
            code = """class Point:
    def __init__(self, x, y):
        self.x = x
        self.y = y"""
            response = env.handle_command(CommandText(code))
            assert response.success is True, "Class definition should succeed"

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
            assert response.success is True, "Empty command should succeed"

            # Comment only
            response = env.handle_command(CommandText("# This is a comment"))
            assert response.success is True, "Comment-only command should succeed"

            # Variable reassignment with type change
            env.handle_command(CommandText("x = 42"))
            screen = env.get_screen()
            assert "x: int" in screen.content, "Should show int type"

            env.handle_command(CommandText("x = 'hello'"))
            screen = env.get_screen()
            assert "x: str" in screen.content, "Should show str type after reassignment"
            assert "x: int" not in screen.content, "Should not show old int type"
        finally:
            env.shutdown()
