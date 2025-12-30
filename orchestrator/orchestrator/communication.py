"""Communication module for NDJSON message handling.

This module handles reading commands from stdin and writing responses to stdout
using newline-delimited JSON (NDJSON) format.

Protocol:
    - Agent → Orchestrator: {"env": "bash", "command": "ls -la"}
    - Orchestrator → Agent: {"response": {...}, "screen": {...}}
    - Orchestrator → Agent (error): {"type": "error", "message": "..."}

All messages are single-line JSON terminated by newline.
"""

import json
import sys
from dataclasses import dataclass
from typing import Mapping, Optional

from orchestrator.core_types import CommandResponse, EnvironmentName, ScreenSection


@dataclass(frozen=True)
class ParsedMessage:
    """Parsed command message from agent."""

    env: EnvironmentName
    command: str


class ParseError(Exception):
    """Error parsing NDJSON message."""

    pass


def read_message() -> Optional[ParsedMessage]:
    """
    Read one message from stdin.

    Returns:
        Parsed command message, or None on EOF

    Raises:
        ParseError: If message is invalid JSON or missing required fields

    Examples:
        >>> # Simulated stdin with valid message
        >>> import io
        >>> sys.stdin = io.StringIO('{"env": "bash", "command": "ls"}\\n')
        >>> msg = read_message()
        >>> msg.env.value
        'bash'
        >>> msg.command
        'ls'

        >>> # EOF case
        >>> sys.stdin = io.StringIO('')
        >>> read_message() is None
        True
    """
    line = sys.stdin.readline()
    if not line:  # EOF
        return None

    try:
        data = json.loads(line)
    except json.JSONDecodeError as e:
        raise ParseError(f"Invalid JSON: {e}")

    # Validate required fields
    if not isinstance(data, dict):
        raise ParseError(f"Message must be JSON object, got {type(data).__name__}")

    if "env" not in data:
        raise ParseError("Missing required field: env")

    if "command" not in data:
        raise ParseError("Missing required field: command")

    # Parse environment name (validates identifier)
    try:
        env = EnvironmentName(data["env"])
    except ValueError as e:
        raise ParseError(f"Invalid environment name: {e}")

    # Command must be string
    if not isinstance(data["command"], str):
        raise ParseError(
            f"Command must be string, got {type(data['command']).__name__}"
        )

    return ParsedMessage(env=env, command=data["command"])


def send_response(
    response: CommandResponse, screen: Mapping[EnvironmentName, ScreenSection]
) -> None:
    """
    Send response message to stdout.

    Args:
        response: Command execution response
        screen: Current screen state from all environments (immutable mapping)

    Message format:
        {
            "response": {
                "output": "...",
                "success": true
            },
            "screen": {
                "bash": {"content": "...", "max_lines": 50},
                "python": {"content": "...", "max_lines": 50}
            }
        }

    Examples:
        >>> import io
        >>> sys.stdout = io.StringIO()
        >>> send_response(
        ...     CommandResponse(output="hello", success=True),
        ...     {EnvironmentName("bash"): ScreenSection("Ready", max_lines=50)}
        ... )
        >>> output = sys.stdout.getvalue()
        >>> "hello" in output
        True
        >>> output.endswith('\\n')
        True
    """
    message = {
        "response": {"output": response.output, "success": response.success},
        "screen": {
            name.value: {"content": section.content, "max_lines": section.max_lines}
            for name, section in screen.items()
        },
    }

    json.dump(message, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()


def send_error_response(error_msg: str) -> None:
    """
    Send error message to stdout.

    Used for orchestrator-level errors (parse errors, unknown environment, etc.).

    Args:
        error_msg: Error message to send

    Message format:
        {"type": "error", "message": "..."}

    Examples:
        >>> import io
        >>> sys.stdout = io.StringIO()
        >>> send_error_response("Unknown environment: foo")
        >>> output = sys.stdout.getvalue()
        >>> "Unknown environment" in output
        True
    """
    message = {"type": "error", "message": error_msg}
    json.dump(message, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()
