"""Tests for executor module."""

from unittest.mock import Mock

from orchestrator.core_types import CommandResponse, CommandText, EnvironmentName
from orchestrator.executor import execute_command


class TestExecuteCommand:
    """Test execute_command function."""

    def test_successful_command(self) -> None:
        """Test executing a command successfully."""
        # Create mock environment
        mock_env = Mock()
        mock_env.handle_command.return_value = CommandResponse(
            output="result", processed=True
        )

        envs = {EnvironmentName("bash"): mock_env}

        response = execute_command(EnvironmentName("bash"), "echo hello", envs)

        assert response.processed is True
        assert response.output == "result"

        # Verify environment was called with correct command
        mock_env.handle_command.assert_called_once()
        call_args = mock_env.handle_command.call_args[0]
        assert isinstance(call_args[0], CommandText)
        assert call_args[0].value == "echo hello"

    def test_failed_command(self) -> None:
        """Test executing a command that fails."""
        mock_env = Mock()
        mock_env.handle_command.return_value = CommandResponse(
            output="error", processed=False
        )

        envs = {EnvironmentName("bash"): mock_env}

        response = execute_command(EnvironmentName("bash"), "false", envs)

        assert response.processed is False
        assert response.output == "error"

    def test_unknown_environment(self) -> None:
        """Test executing command in unknown environment returns failed response."""
        envs = {EnvironmentName("bash"): Mock()}

        response = execute_command(EnvironmentName("python"), "print('hello')", envs)

        # Should return failed response with helpful error message
        assert response.processed is False
        assert "Unknown environment: 'python'" in response.output
        assert "Available environments" in response.output

    def test_unknown_environment_shows_available(self) -> None:
        """Test that error message lists available environments."""
        envs = {
            EnvironmentName("bash"): Mock(),
            EnvironmentName("python"): Mock(),
        }

        response = execute_command(EnvironmentName("editor"), "view foo.py", envs)

        # Should list all available environments in error message
        assert response.processed is False
        assert "Available environments" in response.output
        assert "bash" in response.output
        assert "python" in response.output

    def test_environment_exception_caught(self) -> None:
        """Test that exceptions from environment are caught."""
        mock_env = Mock()
        mock_env.handle_command.side_effect = RuntimeError("Something went wrong")

        envs = {EnvironmentName("bash"): mock_env}

        response = execute_command(EnvironmentName("bash"), "ls", envs)

        # Should return failed response, not raise exception
        assert response.processed is False
        assert "Internal error" in response.output
        assert "RuntimeError" in response.output
        assert "Something went wrong" in response.output

    def test_empty_command(self) -> None:
        """Test executing empty command."""
        mock_env = Mock()
        mock_env.handle_command.return_value = CommandResponse(
            output="", processed=True
        )

        envs = {EnvironmentName("bash"): mock_env}

        response = execute_command(EnvironmentName("bash"), "", envs)

        assert response.processed is True

        # Verify environment received empty command
        call_args = mock_env.handle_command.call_args[0]
        assert call_args[0].value == ""
