"""Tests for communication module."""

import io
import json
import sys

import pytest

from orchestrator.communication import (
    ParsedMessage,
    ParseError,
    read_auxiliary_llm_response,
    read_message,
    send_auxiliary_llm_request,
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

        response = CommandResponse(output="hello", processed=True)
        screen = {EnvironmentName("bash"): ScreenSection("Ready", max_lines=50)}

        send_response(response, screen)

        output = sys.stdout.getvalue()
        assert output.endswith("\n")

        # Parse JSON
        data = json.loads(output)
        assert data["response"]["output"] == "hello"
        assert data["response"]["processed"] is True
        assert "bash" in data["screen"]
        assert data["screen"]["bash"]["content"] == "Ready"
        assert data["screen"]["bash"]["max_lines"] == 50

    def test_failed_response(self) -> None:
        """Test sending a failed response."""
        sys.stdout = io.StringIO()

        response = CommandResponse(output="Error: file not found", processed=False)
        screen = {EnvironmentName("bash"): ScreenSection("Ready", max_lines=50)}

        send_response(response, screen)

        output = sys.stdout.getvalue()
        data = json.loads(output)
        assert data["response"]["processed"] is False
        assert "Error" in data["response"]["output"]

    def test_multiple_environments_in_screen(self) -> None:
        """Test screen with multiple environments."""
        sys.stdout = io.StringIO()

        response = CommandResponse(output="done", processed=True)
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


class TestAuxiliaryLlmProtocol:
    """Test auxiliary LLM request/response protocol."""

    def test_send_auxiliary_request(self) -> None:
        """Test sending an auxiliary LLM request."""
        sys.stdout = io.StringIO()

        send_auxiliary_llm_request("req-123", "Summarize this code", "def foo(): pass")

        output = sys.stdout.getvalue()
        assert output.endswith("\n")

        # Parse JSON
        data = json.loads(output)
        assert data["type"] == "auxiliary_llm_request"
        assert data["request_id"] == "req-123"
        assert data["prompt"] == "Summarize this code"
        assert data["context"] == "def foo(): pass"

    def test_send_auxiliary_request_without_context(self) -> None:
        """Test sending an auxiliary LLM request without context."""
        sys.stdout = io.StringIO()

        send_auxiliary_llm_request("req-456", "What is this?")

        output = sys.stdout.getvalue()
        data = json.loads(output)
        assert data["type"] == "auxiliary_llm_request"
        assert data["request_id"] == "req-456"
        assert data["prompt"] == "What is this?"
        assert "context" not in data

    def test_read_auxiliary_response(self) -> None:
        """Test reading a successful auxiliary LLM response."""
        sys.stdin = io.StringIO(
            '{"type": "auxiliary_llm_response", "request_id": "req-123", "response": "This is a summary"}\n'
        )

        response = read_auxiliary_llm_response("req-123")

        assert response == "This is a summary"

    def test_read_auxiliary_response_with_error(self) -> None:
        """Test reading an auxiliary LLM response with error."""
        sys.stdin = io.StringIO(
            '{"type": "auxiliary_llm_response", "request_id": "req-123", "error": "LLM timeout"}\n'
        )

        with pytest.raises(ParseError, match="LLM error: LLM timeout"):
            read_auxiliary_llm_response("req-123")

    def test_read_auxiliary_response_wrong_type(self) -> None:
        """Test that reading wrong message type raises error."""
        sys.stdin = io.StringIO('{"type": "error", "message": "something"}\n')

        with pytest.raises(ParseError, match="Expected auxiliary_llm_response"):
            read_auxiliary_llm_response("req-123")

    def test_read_auxiliary_response_wrong_request_id(self) -> None:
        """Test that mismatched request_id raises error."""
        sys.stdin = io.StringIO(
            '{"type": "auxiliary_llm_response", "request_id": "req-456", "response": "text"}\n'
        )

        with pytest.raises(RuntimeError, match="request_id mismatch"):
            read_auxiliary_llm_response("req-123")

    def test_read_auxiliary_response_missing_response_field(self) -> None:
        """Test that missing response field raises error."""
        sys.stdin = io.StringIO(
            '{"type": "auxiliary_llm_response", "request_id": "req-123"}\n'
        )

        with pytest.raises(ParseError, match="Missing 'response' field"):
            read_auxiliary_llm_response("req-123")

    def test_read_auxiliary_response_eof(self) -> None:
        """Test that EOF while waiting raises error."""
        sys.stdin = io.StringIO("")

        with pytest.raises(ParseError, match="Unexpected EOF"):
            read_auxiliary_llm_response("req-123")
