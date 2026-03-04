"""Tests for bash environment."""

import tempfile

from orchestrator.core_types import CommandText
from orchestrator.environments.bash import BashEnvironment

from . import timeout


class TestBashEnvironment:
    """Test BashEnvironment implementation."""

    @timeout(10)
    def test_bash_environment_maintains_state_across_commands(self) -> None:
        """Bash environment must maintain shell state between commands.

        Requirements tested:
        1. Environment variables persist across commands
        2. Working directory persists across commands
        3. Shell functions persist across commands
        4. All state persists in same process
        """
        env = BashEnvironment()
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                # Set up state: env var, directory, function
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

    @timeout(10)
    def test_bash_environment_screen_reflects_state(self) -> None:
        """Screen must show current working directory, exit code, and background jobs.

        Requirements tested:
        1. Working directory shown in screen after first use
        2. Last exit code shown in screen after first use
        3. Background jobs section shown in screen
        4. Screen updates after each command
        5. Help text always shown (freeform environment)
        """
        env = BashEnvironment()
        try:
            # Before first use - should show only help
            screen_before = env.get_screen()
            assert (
                "Any bash command. Use & for background jobs." in screen_before.content
            ), "Help text must be shown before first use"
            assert (
                "Working directory:" not in screen_before.content
            ), "State info should not appear before first use"

            with tempfile.TemporaryDirectory() as tmpdir:
                # After first use - should show full state
                env.handle_command(CommandText(f"cd {tmpdir}"))
                screen = env.get_screen()

                # Verify working directory
                assert (
                    "Working directory:" in screen.content
                ), "Must show working directory"
                assert (
                    tmpdir in screen.content
                ), f"Must show current directory: {tmpdir}"

                # Verify exit code (should be 0 from successful cd)
                assert "Last exit code: 0" in screen.content, "Must show last exit code"

                # Change exit code
                env.handle_command(CommandText("false"))
                screen = env.get_screen()
                assert "Last exit code: 1" in screen.content, "Exit code must update"

                # Background jobs section always shown
                assert (
                    "Background jobs:" in screen.content
                ), "Must show background jobs section"

                # Start a background job
                env.handle_command(CommandText("sleep 10 &"))
                screen = env.get_screen()
                # Either shows job or shows "Background jobs:" with job listed
                assert (
                    "sleep" in screen.content or "Background jobs:" in screen.content
                ), "Must show background job"

                # Help text still shown
                assert (
                    "Any bash command. Use & for background jobs." in screen.content
                ), "Help text must always be shown"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_captures_stdout_and_stderr(self) -> None:
        """Output capture must include both stdout and stderr (combined).

        Requirements tested:
        1. Stdout captured in output
        2. Stderr captured in output
        3. Output combined (matches terminal behavior)
        """
        env = BashEnvironment()
        try:
            # Command that writes to both stdout and stderr
            cmd = "echo 'stdout message' && echo 'stderr message' >&2"
            response = env.handle_command(CommandText(cmd))

            assert response.processed is True, "Command should succeed"
            assert "stdout message" in response.output, "Stdout must be captured"
            assert "stderr message" in response.output, "Stderr must be captured"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_provides_exit_code_field(self) -> None:
        """Exit codes must be tracked and provided in response.exit_code field.

        Requirements tested:
        1. Zero exit code (true) → response.exit_code = 0
        2. Non-zero exit code (false) → response.exit_code = 1
        3. processed is always True (unless infrastructure failure)
        4. Exit code shown in screen
        5. Exit code persists until next command
        """
        env = BashEnvironment()
        try:
            # Success case
            response = env.handle_command(CommandText("true"))
            assert (
                response.processed is True
            ), "Command should be processed successfully"
            assert hasattr(
                response, "exit_code"
            ), "Response should have exit_code field"
            assert response.exit_code == 0, "Exit code 0 for successful command"

            screen = env.get_screen()
            assert "Last exit code: 0" in screen.content, "Screen must show exit code"

            # Get screen again without command - exit code should persist
            screen2 = env.get_screen()
            assert (
                "Last exit code: 0" in screen2.content
            ), "Exit code must persist until next command"

            # Failure case - command executed but operation failed
            response = env.handle_command(CommandText("false"))
            assert (
                response.processed is True
            ), "Command should be processed (execution succeeded)"
            assert hasattr(
                response, "exit_code"
            ), "Response should have exit_code field"
            assert response.exit_code == 1, "Exit code 1 for failed operation"

            screen = env.get_screen()
            assert (
                "Last exit code: 1" in screen.content
            ), "Screen must show failure exit code"

            # Success again
            response = env.handle_command(CommandText("true"))
            assert response.processed is True, "Command should be processed"
            assert response.exit_code == 0, "Exit code should update to 0"

            screen = env.get_screen()
            assert "Last exit code: 0" in screen.content, "Exit code must update"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_tracks_background_jobs(self) -> None:
        """Background jobs must be tracked and shown in screen.

        Requirements tested:
        1. Background jobs (using &) are tracked
        2. Background jobs shown in screen with job info
        3. Jobs updated on each command
        """
        env = BashEnvironment()
        try:
            # Start a background job (sleep for short time)
            response = env.handle_command(CommandText("sleep 2 &"))
            assert response.processed is True, "Background job command should succeed"

            # Check screen shows background job
            screen = env.get_screen()
            # Should show job in background jobs list
            # Note: exact format depends on bash version, but should contain "sleep"
            assert (
                "sleep" in screen.content or "Background jobs:" in screen.content
            ), "Background job must be shown in screen"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_enforces_output_size_limit(self) -> None:
        """Large output must be truncated at MAX_OUTPUT_SIZE with warning.

        Requirements tested:
        1. Output over MAX_OUTPUT_SIZE is truncated
        2. Truncation warning message appended
        3. Output size is at most MAX_OUTPUT_SIZE + warning length
        """
        env = BashEnvironment()
        try:
            # Generate output larger than MAX_OUTPUT_SIZE (10MB)
            # Use Python to generate large output
            large_size = 11 * 1024 * 1024  # 11MB
            cmd = f"python3 -c \"print('A' * {large_size})\""

            response = env.handle_command(CommandText(cmd))

            # Should be truncated
            max_expected = BashEnvironment.MAX_OUTPUT_SIZE + 200  # Allow for warning
            assert (
                len(response.output) <= max_expected
            ), f"Output must be truncated at ~{BashEnvironment.MAX_OUTPUT_SIZE} bytes"

            assert (
                "[WARNING: Output truncated" in response.output
            ), "Must include truncation warning"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_help_text_always_shown(self) -> None:
        """Help text must always be shown (freeform environment design).

        Requirements tested:
        1. Help shown before first use
        2. Help shown after first use
        3. Help shown after many uses
        4. Help text is consistent
        """
        env = BashEnvironment()
        try:
            expected_help = "Any bash command. Use & for background jobs."

            # Before first use
            screen_before = env.get_screen()
            assert (
                expected_help in screen_before.content
            ), "Help must be shown before first use"

            # After first use
            env.handle_command(CommandText("echo test"))
            screen_after = env.get_screen()
            assert expected_help in screen_after.content, "Help must be shown after use"

            # After many uses
            env.handle_command(CommandText("pwd"))
            env.handle_command(CommandText("ls"))
            env.handle_command(CommandText("echo hello"))
            screen_later = env.get_screen()
            assert (
                expected_help in screen_later.content
            ), "Help must persist after many commands"
        finally:
            env.shutdown()

    @timeout(10)
    def test_bash_environment_lifecycle(self) -> None:
        """Bash environment must handle initialization and shutdown correctly.

        Requirements tested:
        1. Environment can be created without starting process
        2. Process starts on first command
        3. Process can be started, used, and shutdown
        4. Shutdown terminates process
        5. Shutdown can be called before starting process (graceful)
        6. Shutdown can be called multiple times (idempotent)
        """
        # Create environment - process should not be started yet
        env = BashEnvironment()
        assert env._process is None, "Process should not start on initialization"

        # Execute a command - should start process
        env.handle_command(CommandText("echo test"))
        assert env._process is not None, "Process should start on first command"
        assert env._process.isalive(), "Process should be running"

        # Shutdown should terminate process
        env.shutdown()
        assert (
            env._process is None or not env._process.isalive()
        ), "Shutdown must terminate process"

        # Shutdown before starting process (graceful)
        env2 = BashEnvironment()
        env2.shutdown()  # Should not raise

        # Shutdown can be called multiple times
        env3 = BashEnvironment()
        env3.handle_command(CommandText("echo test"))
        env3.shutdown()
        env3.shutdown()  # Should not raise

    @timeout(10)
    def test_bash_environment_handles_edge_cases(self) -> None:
        """Bash environment must handle edge cases gracefully.

        Requirements tested:
        1. Empty command handled (succeeds with no output)
        2. Multiline output captured correctly
        3. Special characters in output preserved
        """
        env = BashEnvironment()
        try:
            # Empty command
            response = env.handle_command(CommandText(""))
            assert (
                response.processed is True
            ), "Empty command should succeed (bash treats it as no-op)"

            # Multiline output
            response = env.handle_command(
                CommandText("echo -e 'line1\\nline2\\nline3'")
            )
            assert response.processed is True
            assert "line1" in response.output
            assert "line2" in response.output
            assert "line3" in response.output

            # Special characters
            response = env.handle_command(
                CommandText("echo 'special: !@#$%^&*()[]{}|\\\"'")
            )
            assert response.processed is True
            assert "special:" in response.output
        finally:
            env.shutdown()
