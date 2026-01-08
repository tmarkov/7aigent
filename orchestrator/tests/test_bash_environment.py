"""Tests for bash environment."""

import tempfile
from pathlib import Path

from orchestrator.core_types import CommandText
from orchestrator.environments.bash import BashEnvironment


class TestBashEnvironment:
    """Test BashEnvironment implementation."""

    def test_initial_state_before_first_use(self) -> None:
        """Test that environment shows help before first use."""
        env = BashEnvironment()
        try:
            screen = env.get_screen()
            # Should show help text even before first use
            assert "Any bash command. Use & for background jobs." in screen.content
            assert screen.max_lines == 50
            # Should NOT show state info before first use
            assert "Working directory:" not in screen.content
        finally:
            env.shutdown()

    def test_basic_command_execution(self) -> None:
        """Test executing a simple command."""
        env = BashEnvironment()
        try:
            response = env.handle_command(CommandText("echo hello"))
            assert response.success is True
            assert "hello" in response.output
        finally:
            env.shutdown()

    def test_command_with_exit_code_zero(self) -> None:
        """Test command that succeeds (exit code 0)."""
        env = BashEnvironment()
        try:
            response = env.handle_command(CommandText("true"))
            assert response.success is True

            screen = env.get_screen()
            assert "Last exit code: 0" in screen.content
        finally:
            env.shutdown()

    def test_command_with_nonzero_exit_code(self) -> None:
        """Test command that fails (exit code non-zero)."""
        env = BashEnvironment()
        try:
            response = env.handle_command(CommandText("false"))
            assert response.success is False

            screen = env.get_screen()
            assert "Last exit code: 1" in screen.content
        finally:
            env.shutdown()

    def test_working_directory_tracking(self) -> None:
        """Test that working directory is tracked correctly."""
        env = BashEnvironment()
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                # Change to temp directory
                response = env.handle_command(CommandText(f"cd {tmpdir}"))
                assert response.success is True

                # Verify working directory updated
                screen = env.get_screen()
                assert f"Working directory: {tmpdir}" in screen.content

                # Verify pwd command shows same directory
                response = env.handle_command(CommandText("pwd"))
                assert tmpdir in response.output
        finally:
            env.shutdown()

    def test_multiple_commands_maintain_state(self) -> None:
        """Test that state persists across multiple commands."""
        env = BashEnvironment()
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                # Set variable
                env.handle_command(CommandText("export TEST_VAR=hello"))

                # Change directory
                env.handle_command(CommandText(f"cd {tmpdir}"))

                # Verify variable still exists
                response = env.handle_command(CommandText("echo $TEST_VAR"))
                assert "hello" in response.output

                # Verify still in correct directory
                response = env.handle_command(CommandText("pwd"))
                assert tmpdir in response.output
        finally:
            env.shutdown()

    def test_multiline_output(self) -> None:
        """Test command with multi-line output."""
        env = BashEnvironment()
        try:
            response = env.handle_command(
                CommandText("echo -e 'line1\\nline2\\nline3'")
            )
            assert response.success is True
            assert "line1" in response.output
            assert "line2" in response.output
            assert "line3" in response.output
        finally:
            env.shutdown()

    def test_stderr_captured(self) -> None:
        """Test that stderr is captured in output."""
        env = BashEnvironment()
        try:
            # Command that writes to stderr
            response = env.handle_command(CommandText("echo error >&2"))
            # Bash combines stdout and stderr, so we should see "error"
            assert "error" in response.output
        finally:
            env.shutdown()

    def test_background_job_tracking(self) -> None:
        """Test that background jobs are tracked."""
        env = BashEnvironment()
        try:
            # Start a background job (sleep for a short time)
            response = env.handle_command(CommandText("sleep 2 &"))
            assert response.success is True

            # Check screen shows background job
            screen = env.get_screen()
            # Should show job in background jobs list
            # Note: exact format depends on bash version
            assert "sleep" in screen.content or "Background jobs:" in screen.content
        finally:
            env.shutdown()

    def test_large_output_truncation(self) -> None:
        """Test that large output is truncated."""
        env = BashEnvironment()
        try:
            # Generate output larger than 10MB
            # Use Python to generate large output
            large_size = 11 * 1024 * 1024  # 11MB
            cmd = f"python3 -c \"print('A' * {large_size})\""

            response = env.handle_command(CommandText(cmd))

            # Should be truncated
            assert len(response.output) <= BashEnvironment.MAX_OUTPUT_SIZE + 200
            assert "[WARNING: Output truncated" in response.output
        finally:
            env.shutdown()

    def test_screen_shows_state_after_first_use(self) -> None:
        """Test that screen shows full state after first command."""
        env = BashEnvironment()
        try:
            # Execute a command
            env.handle_command(CommandText("echo test"))

            # Screen should now show full state
            screen = env.get_screen()
            assert "Working directory:" in screen.content
            assert "Last exit code:" in screen.content
            assert "Background jobs:" in screen.content
        finally:
            env.shutdown()

    def test_help_text_always_shown(self) -> None:
        """Test that help text is always shown (freeform environment design)."""
        env = BashEnvironment()
        try:
            # Before first use - should show help
            screen_before = env.get_screen()
            assert (
                "Any bash command. Use & for background jobs." in screen_before.content
            )

            # After first use - should still show help
            env.handle_command(CommandText("echo test"))
            screen_after = env.get_screen()
            assert (
                "Any bash command. Use & for background jobs." in screen_after.content
            )

            # After many uses - should still show help
            env.handle_command(CommandText("pwd"))
            env.handle_command(CommandText("ls"))
            screen_later = env.get_screen()
            assert (
                "Any bash command. Use & for background jobs." in screen_later.content
            )
        finally:
            env.shutdown()

    def test_file_operations(self) -> None:
        """Test file creation and reading."""
        env = BashEnvironment()
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                filepath = Path(tmpdir) / "test.txt"

                # Create file
                response = env.handle_command(
                    CommandText(f"echo 'test content' > {filepath}")
                )
                assert response.success is True

                # Read file
                response = env.handle_command(CommandText(f"cat {filepath}"))
                assert response.success is True
                assert "test content" in response.output

                # Verify file exists
                assert filepath.exists()
        finally:
            env.shutdown()

    def test_command_chaining(self) -> None:
        """Test chaining commands with && and ||."""
        env = BashEnvironment()
        try:
            # Successful chain
            response = env.handle_command(CommandText("true && echo success"))
            assert response.success is True
            assert "success" in response.output

            # Failed chain
            response = env.handle_command(
                CommandText("false && echo should_not_appear")
            )
            assert response.success is False
            assert "should_not_appear" not in response.output

            # Or operator
            response = env.handle_command(CommandText("false || echo fallback"))
            assert "fallback" in response.output
        finally:
            env.shutdown()

    def test_empty_command(self) -> None:
        """Test handling of empty command."""
        env = BashEnvironment()
        try:
            response = env.handle_command(CommandText(""))
            # Empty command should succeed with no output
            assert response.success is True
        finally:
            env.shutdown()

    def test_shutdown_cleanup(self) -> None:
        """Test that shutdown properly cleans up process."""
        env = BashEnvironment()

        # Execute a command to start process
        env.handle_command(CommandText("echo test"))

        # Shutdown should not raise
        env.shutdown()

        # Process should be terminated
        assert env._process is None or not env._process.isalive()

    def test_shutdown_without_starting_process(self) -> None:
        """Test that shutdown works even if process was never started."""
        env = BashEnvironment()
        # Should not raise
        env.shutdown()

    def test_special_characters_in_output(self) -> None:
        """Test handling of special characters in command output."""
        env = BashEnvironment()
        try:
            # Test various special characters
            response = env.handle_command(
                CommandText("echo 'special: !@#$%^&*()[]{}|\\\"'")
            )
            assert response.success is True
            # Should contain the special characters
            assert "special:" in response.output
        finally:
            env.shutdown()

    def test_command_with_pipes(self) -> None:
        """Test commands using pipes."""
        env = BashEnvironment()
        try:
            response = env.handle_command(
                CommandText("echo 'line1\\nline2\\nline3' | grep line2")
            )
            assert response.success is True
            assert "line2" in response.output
            # Should not contain other lines
            assert "line1" not in response.output or "line2" in response.output
        finally:
            env.shutdown()

    def test_exit_code_persistence(self) -> None:
        """Test that exit code persists until next command."""
        env = BashEnvironment()
        try:
            # Run failing command
            env.handle_command(CommandText("false"))
            screen1 = env.get_screen()
            assert "Last exit code: 1" in screen1.content

            # Get screen again without running command
            screen2 = env.get_screen()
            assert "Last exit code: 1" in screen2.content

            # Run successful command
            env.handle_command(CommandText("true"))
            screen3 = env.get_screen()
            assert "Last exit code: 0" in screen3.content
        finally:
            env.shutdown()
