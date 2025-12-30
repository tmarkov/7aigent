"""Tests for minimal orchestrator modules."""

from orchestrator.communication import read_message, send_error_response, send_response
from orchestrator.executor import execute_command
from orchestrator.screen import collect_screen_updates


def test_imports():
    """Verify all minimal orchestrator modules can be imported."""
    # This test will fail until modules are created
    assert read_message is not None
    assert send_response is not None
    assert send_error_response is not None
    assert execute_command is not None
    assert collect_screen_updates is not None
