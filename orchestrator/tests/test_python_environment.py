"""Tests for Python environment."""

from orchestrator.core_types import CommandText
from orchestrator.environments.python import PythonEnvironment


class TestPythonEnvironment:
    """Test PythonEnvironment implementation."""

    def test_initial_state_before_first_use(self) -> None:
        """Test that environment shows help before first use."""
        env = PythonEnvironment()
        try:
            screen = env.get_screen()
            # Should show help text even before first use
            assert (
                "Any Python code. Variables and imports persist across commands."
                in screen.content
            )
            assert screen.max_lines == 50
            # Should NOT show state info before first use
            assert "Working directory:" not in screen.content
        finally:
            env.shutdown()

    def test_basic_expression_evaluation(self) -> None:
        """Test executing a simple expression."""
        env = PythonEnvironment()
        try:
            response = env.handle_command(CommandText("2 + 2"))
            assert response.success is True
            assert "4" in response.output
        finally:
            env.shutdown()

    def test_print_statement(self) -> None:
        """Test print statement output."""
        env = PythonEnvironment()
        try:
            response = env.handle_command(CommandText("print('hello world')"))
            assert response.success is True
            assert "hello world" in response.output
        finally:
            env.shutdown()

    def test_variable_persistence(self) -> None:
        """Test that variables persist across commands."""
        env = PythonEnvironment()
        try:
            # Set variable
            response = env.handle_command(CommandText("x = 42"))
            assert response.success is True

            # Use variable
            response = env.handle_command(CommandText("x * 2"))
            assert response.success is True
            assert "84" in response.output

            # Modify variable
            env.handle_command(CommandText("x = x + 10"))

            # Verify modification
            response = env.handle_command(CommandText("x"))
            assert "52" in response.output
        finally:
            env.shutdown()

    def test_variable_tracking_in_screen(self) -> None:
        """Test that variables are displayed on screen with types."""
        env = PythonEnvironment()
        try:
            # Create some variables
            env.handle_command(CommandText("x = 42"))
            env.handle_command(CommandText("y = 'hello'"))
            env.handle_command(CommandText("z = [1, 2, 3]"))

            # Get screen
            screen = env.get_screen()

            # Should show variables with types
            assert "x: int" in screen.content
            assert "y: str" in screen.content
            assert "z: list" in screen.content
            assert "Variables (recent):" in screen.content
        finally:
            env.shutdown()

    def test_variable_ordering_by_recent_use(self) -> None:
        """Test that variables are ordered by recent use."""
        env = PythonEnvironment()
        try:
            # Create variables in order
            env.handle_command(CommandText("a = 1"))
            env.handle_command(CommandText("b = 2"))
            env.handle_command(CommandText("c = 3"))

            # Use 'a' to move it to front
            env.handle_command(CommandText("print(a)"))

            screen = env.get_screen()
            content_lines = screen.content.split("\n")

            # Find variable lines
            var_lines = [
                line
                for line in content_lines
                if line.strip().startswith(("a:", "b:", "c:"))
            ]

            # 'a' should be first since it was used most recently
            assert var_lines[0].strip().startswith("a:")
        finally:
            env.shutdown()

    def test_working_directory_tracking(self) -> None:
        """Test that working directory is displayed."""
        env = PythonEnvironment()
        try:
            # Execute command to initialize
            env.handle_command(CommandText("x = 1"))

            # Get screen
            screen = env.get_screen()

            # Should show working directory
            assert "Working directory:" in screen.content
        finally:
            env.shutdown()

    def test_working_directory_change(self) -> None:
        """Test changing working directory in Python."""
        env = PythonEnvironment()
        try:
            import tempfile

            with tempfile.TemporaryDirectory() as tmpdir:
                # Change directory
                env.handle_command(CommandText(f"import os; os.chdir('{tmpdir}')"))

                # Verify in screen
                screen = env.get_screen()
                assert tmpdir in screen.content
        finally:
            env.shutdown()

    def test_exception_handling(self) -> None:
        """Test that exceptions are captured in output."""
        env = PythonEnvironment()
        try:
            response = env.handle_command(CommandText("1 / 0"))
            assert response.success is True  # Command executed, even if it raised
            assert "ZeroDivisionError" in response.output
        finally:
            env.shutdown()

    def test_syntax_error_handling(self) -> None:
        """Test that syntax errors are captured."""
        env = PythonEnvironment()
        try:
            response = env.handle_command(CommandText("if True"))
            assert response.success is True  # Command executed
            assert "SyntaxError" in response.output
        finally:
            env.shutdown()

    def test_multi_line_code_function_definition(self) -> None:
        """Test defining a function with multiple lines."""
        env = PythonEnvironment()
        try:
            # Define function (multi-line)
            code = """def add(a, b):
    return a + b"""
            response = env.handle_command(CommandText(code))
            assert response.success is True

            # Use function
            response = env.handle_command(CommandText("add(3, 4)"))
            assert "7" in response.output
        finally:
            env.shutdown()

    def test_multi_line_code_class_definition(self) -> None:
        """Test defining a class with multiple lines."""
        env = PythonEnvironment()
        try:
            # Define class
            code = """class Point:
    def __init__(self, x, y):
        self.x = x
        self.y = y"""
            response = env.handle_command(CommandText(code))
            assert response.success is True

            # Create instance
            env.handle_command(CommandText("p = Point(10, 20)"))

            # Access attribute
            response = env.handle_command(CommandText("p.x"))
            assert "10" in response.output
        finally:
            env.shutdown()

    def test_import_statement(self) -> None:
        """Test importing modules."""
        env = PythonEnvironment()
        try:
            # Import module
            response = env.handle_command(CommandText("import math"))
            assert response.success is True

            # Use module
            response = env.handle_command(CommandText("math.pi"))
            assert "3.14" in response.output
        finally:
            env.shutdown()

    def test_from_import_statement(self) -> None:
        """Test from...import statements."""
        env = PythonEnvironment()
        try:
            response = env.handle_command(CommandText("from math import sqrt"))
            assert response.success is True

            response = env.handle_command(CommandText("sqrt(16)"))
            assert "4" in response.output
        finally:
            env.shutdown()

    def test_list_comprehension(self) -> None:
        """Test list comprehension."""
        env = PythonEnvironment()
        try:
            response = env.handle_command(CommandText("[x**2 for x in range(5)]"))
            assert response.success is True
            assert "[0, 1, 4, 9, 16]" in response.output
        finally:
            env.shutdown()

    def test_dictionary_operations(self) -> None:
        """Test dictionary creation and access."""
        env = PythonEnvironment()
        try:
            env.handle_command(CommandText("d = {'a': 1, 'b': 2}"))
            response = env.handle_command(CommandText("d['a']"))
            assert "1" in response.output
        finally:
            env.shutdown()

    def test_no_variables_displayed_initially(self) -> None:
        """Test that screen shows no variables message when none exist."""
        env = PythonEnvironment()
        try:
            # Execute command that doesn't create variables
            env.handle_command(CommandText("print('test')"))

            screen = env.get_screen()
            assert "(no variables)" in screen.content
        finally:
            env.shutdown()

    def test_private_variables_excluded(self) -> None:
        """Test that private variables (starting with _) are excluded."""
        env = PythonEnvironment()
        try:
            env.handle_command(CommandText("_private = 1"))
            env.handle_command(CommandText("public = 2"))

            screen = env.get_screen()

            # Should show public but not private
            assert "public: int" in screen.content
            assert "_private" not in screen.content
        finally:
            env.shutdown()

    def test_screen_after_first_use(self) -> None:
        """Test that screen shows full state after first command."""
        env = PythonEnvironment()
        try:
            # Execute a command
            env.handle_command(CommandText("x = 1"))

            # Screen should show full state
            screen = env.get_screen()
            assert "Working directory:" in screen.content
            assert "Variables (recent):" in screen.content
        finally:
            env.shutdown()

    def test_help_text_always_shown(self) -> None:
        """Test that help text is always shown (freeform environment design)."""
        env = PythonEnvironment()
        try:
            # Before first use - should show help
            screen_before = env.get_screen()
            assert (
                "Any Python code. Variables and imports persist across commands."
                in screen_before.content
            )

            # After first use - should still show help
            env.handle_command(CommandText("x = 1"))
            screen_after = env.get_screen()
            assert (
                "Any Python code. Variables and imports persist across commands."
                in screen_after.content
            )

            # After many uses - should still show help
            env.handle_command(CommandText("y = 2"))
            env.handle_command(CommandText("z = x + y"))
            screen_later = env.get_screen()
            assert (
                "Any Python code. Variables and imports persist across commands."
                in screen_later.content
            )
        finally:
            env.shutdown()

    def test_multiple_variables_with_same_usage(self) -> None:
        """Test multiple variables used in same command."""
        env = PythonEnvironment()
        try:
            # Create variables
            env.handle_command(CommandText("a = 1"))
            env.handle_command(CommandText("b = 2"))
            env.handle_command(CommandText("c = 3"))

            # Use b and c together
            env.handle_command(CommandText("result = b + c"))

            screen = env.get_screen()
            content_lines = screen.content.split("\n")

            # Find variable lines
            var_lines = [
                line
                for line in content_lines
                if line.strip().startswith(("a:", "b:", "c:", "result:"))
            ]

            # result, b, and c should be at the top (recently used)
            # Exact order may vary, but they should all appear before 'a'
            var_names = [line.split(":")[0].strip() for line in var_lines]
            result_idx = var_names.index("result")
            b_idx = var_names.index("b")
            c_idx = var_names.index("c")
            a_idx = var_names.index("a")

            # All recently used vars should come before 'a'
            assert result_idx < a_idx
            assert b_idx < a_idx
            assert c_idx < a_idx
        finally:
            env.shutdown()

    def test_shutdown_cleanup(self) -> None:
        """Test that shutdown properly cleans up process."""
        env = PythonEnvironment()

        # Execute a command to start process
        env.handle_command(CommandText("x = 1"))

        # Shutdown should not raise
        env.shutdown()

        # Process should be terminated
        assert env._process is None or not env._process.isalive()

    def test_shutdown_without_starting_process(self) -> None:
        """Test that shutdown works even if process was never started."""
        env = PythonEnvironment()
        # Should not raise
        env.shutdown()

    def test_long_running_computation(self) -> None:
        """Test a computation that takes some time."""
        env = PythonEnvironment()
        try:
            # Compute sum of range (should be fast but tests blocking)
            response = env.handle_command(CommandText("sum(range(1000000))"))
            assert response.success is True
            # Result should be (n * (n-1)) / 2 for range(n)
            assert "499999500000" in response.output
        finally:
            env.shutdown()

    def test_string_with_newlines(self) -> None:
        """Test handling strings with newlines."""
        env = PythonEnvironment()
        try:
            response = env.handle_command(CommandText("print('line1\\nline2\\nline3')"))
            assert response.success is True
            assert "line1" in response.output
            assert "line2" in response.output
            assert "line3" in response.output
        finally:
            env.shutdown()

    def test_empty_command(self) -> None:
        """Test handling of empty command."""
        env = PythonEnvironment()
        try:
            response = env.handle_command(CommandText(""))
            # Empty command should succeed with no output
            assert response.success is True
        finally:
            env.shutdown()

    def test_comment_only_command(self) -> None:
        """Test command that is only a comment."""
        env = PythonEnvironment()
        try:
            response = env.handle_command(CommandText("# This is a comment"))
            assert response.success is True
            # Should have no output
        finally:
            env.shutdown()

    def test_variable_deletion(self) -> None:
        """Test deleting variables."""
        env = PythonEnvironment()
        try:
            # Create variable
            env.handle_command(CommandText("x = 42"))

            # Verify it exists
            screen = env.get_screen()
            assert "x: int" in screen.content

            # Delete variable
            env.handle_command(CommandText("del x"))

            # Verify it's gone
            screen = env.get_screen()
            assert "x:" not in screen.content
        finally:
            env.shutdown()

    def test_reassign_variable_with_different_type(self) -> None:
        """Test reassigning variable with different type."""
        env = PythonEnvironment()
        try:
            # Create int variable
            env.handle_command(CommandText("x = 42"))
            screen = env.get_screen()
            assert "x: int" in screen.content

            # Reassign as string
            env.handle_command(CommandText("x = 'hello'"))
            screen = env.get_screen()
            assert "x: str" in screen.content
            assert "x: int" not in screen.content
        finally:
            env.shutdown()
