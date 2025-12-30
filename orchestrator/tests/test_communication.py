"""Tests for communication module."""

import io
import json
import sys

import pytest

from orchestrator.communication import (
    ParsedMessage,
    ParseError,
    read_message,
    send_error_response,
    send_response,
)
from orchestrator.core_types import CommandResponse, EnvironmentName, ScreenSection


class TestReadMessage:
    """Test read_message function."""

    def test_valid_message(self) -> None:
        """Test reading a valid command message."""
        sys.stdin = io.StringIO('{"env": "bash", "command": "ls -la"}\n')

        msg = read_message()

        assert msg is not None
        assert msg.env == EnvironmentName("bash")
        assert msg.command == "ls -la"

    def test_eof(self) -> None:
        """Test that EOF returns None."""
        sys.stdin = io.StringIO("")

        msg = read_message()

        assert msg is None

    def test_invalid_json(self) -> None:
        """Test that invalid JSON raises ParseError."""
        sys.stdin = io.StringIO("{invalid json}\n")

        with pytest.raises(ParseError, match="Invalid JSON"):
            read_message()

    def test_non_object(self) -> None:
        """Test that non-object JSON raises ParseError."""
        sys.stdin = io.StringIO('"string"\n')

        with pytest.raises(ParseError, match="must be JSON object"):
            read_message()

    def test_missing_env_field(self) -> None:
        """Test that missing env field raises ParseError."""
        sys.stdin = io.StringIO('{"command": "ls"}\n')

        with pytest.raises(ParseError, match="Missing required field: env"):
            read_message()

    def test_missing_command_field(self) -> None:
        """Test that missing command field raises ParseError."""
        sys.stdin = io.StringIO('{"env": "bash"}\n')

        with pytest.raises(ParseError, match="Missing required field: command"):
            read_message()

    def test_invalid_environment_name(self) -> None:
        """Test that invalid environment name raises ParseError."""
        sys.stdin = io.StringIO('{"env": "my-env", "command": "ls"}\n')

        with pytest.raises(ParseError, match="Invalid environment name"):
            read_message()

    def test_command_not_string(self) -> None:
        """Test that non-string command raises ParseError."""
        sys.stdin = io.StringIO('{"env": "bash", "command": 123}\n')

        with pytest.raises(ParseError, match="Command must be string"):
            read_message()

    def test_empty_command(self) -> None:
        """Test that empty command is valid."""
        sys.stdin = io.StringIO('{"env": "bash", "command": ""}\n')

        msg = read_message()

        assert msg is not None
        assert msg.command == ""

    def test_multiline_command_in_json_string(self) -> None:
        """Test command with embedded newlines (escaped in JSON)."""
        sys.stdin = io.StringIO(
            '{"env": "bash", "command": "echo \\"line1\\nline2\\""}\n'
        )

        msg = read_message()

        assert msg is not None
        assert "line1\nline2" in msg.command


class TestSendResponse:
    """Test send_response function."""

    def test_basic_response(self) -> None:
        """Test sending a basic response."""
        sys.stdout = io.StringIO()

        response = CommandResponse(output="hello", success=True)
        screen = {EnvironmentName("bash"): ScreenSection("Ready", max_lines=50)}

        send_response(response, screen)

        output = sys.stdout.getvalue()
        assert output.endswith("\n")

        # Parse JSON
        data = json.loads(output)
        assert data["response"]["output"] == "hello"
        assert data["response"]["success"] is True
        assert "bash" in data["screen"]
        assert data["screen"]["bash"]["content"] == "Ready"
        assert data["screen"]["bash"]["max_lines"] == 50

    def test_failed_response(self) -> None:
        """Test sending a failed response."""
        sys.stdout = io.StringIO()

        response = CommandResponse(output="Error: file not found", success=False)
        screen = {EnvironmentName("bash"): ScreenSection("Ready", max_lines=50)}

        send_response(response, screen)

        output = sys.stdout.getvalue()
        data = json.loads(output)
        assert data["response"]["success"] is False
        assert "Error" in data["response"]["output"]

    def test_multiple_environments_in_screen(self) -> None:
        """Test screen with multiple environments."""
        sys.stdout = io.StringIO()

        response = CommandResponse(output="done", success=True)
        screen = {
            EnvironmentName("bash"): ScreenSection("Bash ready", max_lines=50),
            EnvironmentName("python"): ScreenSection("Python ready", max_lines=30),
        }

        send_response(response, screen)

        output = sys.stdout.getvalue()
        data = json.loads(output)
        assert "bash" in data["screen"]
        assert "python" in data["screen"]
        assert data["screen"]["bash"]["max_lines"] == 50
        assert data["screen"]["python"]["max_lines"] == 30


class TestSendErrorResponse:
    """Test send_error_response function."""

    def test_error_response(self) -> None:
        """Test sending an error response."""
        sys.stdout = io.StringIO()

        send_error_response("Unknown environment: foo")

        output = sys.stdout.getvalue()
        assert output.endswith("\n")

        # Parse JSON
        data = json.loads(output)
        assert data["type"] == "error"
        assert "Unknown environment" in data["message"]


class TestParsedMessage:
    """Test ParsedMessage dataclass."""

    def test_immutable(self) -> None:
        """Test that ParsedMessage is immutable."""
        msg = ParsedMessage(env=EnvironmentName("bash"), command="ls")

        with pytest.raises(AttributeError):
            msg.env = EnvironmentName("python")  # type: ignore

        with pytest.raises(AttributeError):
            msg.command = "pwd"  # type: ignore
