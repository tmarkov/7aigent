"""Tests for InteractiveEnvironment base class."""

import sys

from orchestrator.core_types import CommandText, ScreenSection
from orchestrator.interactive import InteractiveEnvironment


class SimplePythonInteractive(InteractiveEnvironment):
    """Minimal interactive environment for testing using Python REPL."""

    def __init__(self):
        super().__init__(prompt_marker="<<<TEST>>>", name="test-python")
        self.last_command = None

    def _get_spawn_command(self) -> tuple[str, list[str]]:
        """Spawn Python REPL."""
        return sys.executable, ["-u", "-q"]

    def _initialize_process(self) -> None:
        """Set up custom prompt in Python."""
        # Wait for default prompt
        self._process.expect_exact(">>> ")
        # Set custom prompt
        self._process.send(f'import sys; sys.ps1 = "{self._prompt_marker}"\n')
        self._process.expect_exact(self._prompt_marker)

    def _update_state_after_command(self, command: str) -> None:
        """Track last command."""
        self.last_command = command

    def get_state_display(self) -> str:
        """Return current state."""
        if self.last_command:
            return f"Last command: {self.last_command}\n\nTest Python environment."
        return "No commands executed yet.\n\nTest Python environment."


def test_interactive_environment_basic():
    """Test that InteractiveEnvironment can be imported and instantiated."""
    env = SimplePythonInteractive()
    assert env._name == "test-python"
    assert env._prompt_marker == "<<<TEST>>>"
    assert not env._used


def test_interactive_environment_command_execution():
    """Test basic command execution."""
    env = SimplePythonInteractive()

    # Execute a simple Python command
    response = env.handle_command(CommandText("1 + 1"))

    assert response.processed
    assert "2" in response.output
    assert env._used
    assert env.last_command == "1 + 1"

    # Clean up
    env.shutdown()


def test_interactive_environment_screen():
    """Test screen display."""
    env = SimplePythonInteractive()

    # Initial screen
    screen = env.get_screen()
    assert isinstance(screen, ScreenSection)
    assert "No commands executed" in screen.content

    # After command
    env.handle_command(CommandText("x = 42"))
    screen = env.get_screen()
    assert "Last command: x = 42" in screen.content

    # Clean up
    env.shutdown()


def test_interactive_environment_shutdown():
    """Test shutdown handling."""
    env = SimplePythonInteractive()

    # Start process
    env.handle_command(CommandText("1 + 1"))
    assert env._process is not None

    # Shutdown
    env.shutdown()
    assert env._process is None
