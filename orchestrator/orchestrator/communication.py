"""Communication module for NDJSON message handling.

This module handles reading commands from stdin and writing responses to stdout
using newline-delimited JSON (NDJSON) format.

Protocol:
    - Agent → Orchestrator: {"env": "bash", "command": "ls -la"}
    - Orchestrator → Agent: {"response": {...}, "screen": {...}}
    - Orchestrator → Agent (error): {"type": "error", "message": "..."}
    - Orchestrator → Agent (auxiliary request): {"type": "auxiliary_llm_request", "request_id": "...", "prompt": "...", "context": "..."}
    - Agent → Orchestrator (auxiliary response): {"type": "auxiliary_llm_response", "request_id": "...", "response": "...", "error": "..."}

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
                "processed": true,
                ... (optional environment-specific fields like exit_code for bash)
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
        ...     CommandResponse(output="hello", processed=True),
        ...     {EnvironmentName("bash"): ScreenSection("Ready", max_lines=50)}
        ... )
        >>> output = sys.stdout.getvalue()
        >>> "hello" in output
        True
        >>> output.endswith('\\n')
        True
    """
    # Build response dict with core fields
    response_dict = {"output": response.output, "processed": response.processed}

    # Add environment-specific fields dynamically
    # Iterate through all non-private, non-method attributes of the dataclass
    for attr_name in dir(response):
        if not attr_name.startswith("_") and attr_name not in ("output", "processed"):
            attr_value = getattr(response, attr_name)
            # Only include data attributes, not methods
            if not callable(attr_value):
                response_dict[attr_name] = attr_value

    message = {
        "response": response_dict,
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


def send_auxiliary_llm_request(
    request_id: str, prompt: str, context: Optional[str] = None
) -> None:
    """
    Send auxiliary LLM request to agent.

    Args:
        request_id: Unique identifier for this request
        prompt: The prompt to send to the LLM
        context: Optional additional context

    Message format:
        {"type": "auxiliary_llm_request", "request_id": "...", "prompt": "...", "context": "..."}
    """
    message = {
        "type": "auxiliary_llm_request",
        "request_id": request_id,
        "prompt": prompt,
    }
    if context is not None:
        message["context"] = context

    json.dump(message, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()


def read_auxiliary_llm_response(request_id: str) -> str:
    """
    Read auxiliary LLM response from stdin.

    Args:
        request_id: The request ID we're waiting for

    Returns:
        The LLM response text

    Raises:
        ParseError: If message is invalid or an error occurred
        RuntimeError: If response is for wrong request_id
    """
    line = sys.stdin.readline()
    if not line:  # EOF
        raise ParseError("Unexpected EOF while waiting for auxiliary LLM response")

    try:
        data = json.loads(line)
    except json.JSONDecodeError as e:
        raise ParseError(f"Invalid JSON: {e}")

    if not isinstance(data, dict):
        raise ParseError(f"Message must be JSON object, got {type(data).__name__}")

    if data.get("type") != "auxiliary_llm_response":
        raise ParseError(
            f"Expected auxiliary_llm_response, got {data.get('type', 'unknown')}"
        )

    if data.get("request_id") != request_id:
        raise RuntimeError(
            f"Response request_id mismatch: expected {request_id}, got {data.get('request_id')}"
        )

    # Check for error in response
    if "error" in data:
        raise ParseError(f"LLM error: {data['error']}")

    # Return the response
    if "response" not in data:
        raise ParseError("Missing 'response' field in auxiliary LLM response")

    return data["response"]
