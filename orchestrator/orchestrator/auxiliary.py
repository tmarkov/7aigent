"""Auxiliary LLM query support.

This module provides functionality for environments to request LLM assistance
separate from the main conversation. These queries are routed through the agent
to maintain orchestrator isolation (no API keys or internet access).
"""

import uuid
from typing import Optional

from orchestrator.communication import (
    read_auxiliary_llm_response,
    send_auxiliary_llm_request,
)


def request_auxiliary_llm_query(prompt: str, context: Optional[str] = None) -> str:
    """
    Request an auxiliary LLM query from the agent.

    This allows environments to get AI assistance (summaries, explanations, etc.)
    without having direct LLM access. The orchestrator sends the request to the
    agent, which handles the LLM API call and returns the response.

    Args:
        prompt: The prompt to send to the LLM
        context: Optional additional context to include

    Returns:
        The LLM response text

    Raises:
        ParseError: If the response is invalid or an error occurred
        RuntimeError: If there's a protocol mismatch

    Examples:
        >>> # This would communicate with the agent via stdin/stdout
        >>> response = request_auxiliary_llm_query(
        ...     "Summarize this code",
        ...     "def foo(): return 42"
        ... )
        >>> isinstance(response, str)
        True
    """
    # Generate unique request ID
    request_id = f"aux-{uuid.uuid4().hex[:8]}"

    # Send request to agent
    send_auxiliary_llm_request(request_id, prompt, context)

    # Wait for response
    response = read_auxiliary_llm_response(request_id)

    return response
