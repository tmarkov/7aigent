"""Tests for declarative environment base class."""

from orchestrator.core_types import CommandText, ScreenSection
from orchestrator.declarative import DeclarativeEnvironment, command


class SimpleEnvironment(DeclarativeEnvironment):
    """Simple test environment"""

    def __init__(self):
        super().__init__()
        self.counter = 0

    @command(
        signature="increment",
        description="Increment the counter by one.",
        example="increment",
    )
    def increment(self, cmd_text: str) -> str:
        self.counter += 1
        return f"Counter: {self.counter}"

    @command(
        signature="reset",
        description="Reset the counter to zero.\nThis is a multi-line description.",
        example="reset",
    )
    def reset(self, cmd_text: str) -> str:
        self.counter = 0
        return "Counter reset"

    def get_state_display(self) -> str:
        return f"Counter: {self.counter}"


class TimerEnvironment(DeclarativeEnvironment):
    """Timer for tracking elapsed time"""

    def __init__(self):
        super().__init__()
        self.running = False

    @command(
        signature="start",
        description="Start the timer from zero or resume after stop.",
        example="start",
    )
    def start(self, cmd_text: str) -> str:
        self.running = True
        return "Timer started"

    @command(
        signature="stop",
        description="Stop the timer and record elapsed time.",
        example="stop",
    )
    def stop(self, cmd_text: str) -> str:
        if not self.running:
            raise ValueError("Timer not running")
        self.running = False
        return "Timer stopped"

    def get_state_display(self) -> str:
        return "Timer: Running" if self.running else "Timer: Stopped"


class DefaultDocstringEnvironment(DeclarativeEnvironment):
    """Default environment using docstring"""

    @command(signature="test", description="Test command", example="test")
    def test(self, cmd_text: str) -> str:
        return "Test executed"


def test_command_decorator_attaches_metadata():
    """Test that @command decorator attaches metadata to methods."""
    env = SimpleEnvironment()

    # Check that metadata is attached
    assert hasattr(env.increment, "_command_metadata")
    metadata = env.increment._command_metadata

    assert metadata["signature"] == "increment"
    assert metadata["description"] == "Increment the counter by one."
    assert metadata["example"] == "increment"


def test_command_discovery():
    """Test that DeclarativeEnvironment discovers decorated commands."""
    env = SimpleEnvironment()

    # Should have discovered both commands
    assert len(env._commands) == 2
    assert "increment" in env._commands
    assert "reset" in env._commands

    # Each command should have method and metadata
    method, metadata = env._commands["increment"]
    assert callable(method)
    assert metadata["signature"] == "increment"


def test_handle_command_routes_correctly():
    """Test that handle_command routes to the correct method."""
    env = SimpleEnvironment()

    # Execute increment command
    response = env.handle_command(CommandText("increment"))
    assert response.success is True
    assert response.output == "Counter: 1"
    assert env.counter == 1

    # Execute reset command
    response = env.handle_command(CommandText("reset"))
    assert response.success is True
    assert response.output == "Counter reset"
    assert env.counter == 0


def test_handle_command_unknown_command():
    """Test that unknown commands return error response."""
    env = SimpleEnvironment()

    response = env.handle_command(CommandText("unknown"))
    assert response.success is False
    assert "Unknown command: unknown" in response.output
    assert "Available: increment, reset" in response.output


def test_handle_command_exception_handling():
    """Test that exceptions from command handlers are caught."""
    env = TimerEnvironment()

    # Try to stop timer that's not running - should raise ValueError
    response = env.handle_command(CommandText("stop"))
    assert response.success is False
    assert "Error: Timer not running" in response.output


def test_command_usage_tracking():
    """Test that command usage is tracked correctly."""
    env = SimpleEnvironment()

    # Initially no commands used
    assert len(env._command_usage) == 0

    # Execute increment
    env.handle_command(CommandText("increment"))
    assert "increment" in env._command_usage
    assert "reset" not in env._command_usage

    # Execute reset
    env.handle_command(CommandText("reset"))
    assert "increment" in env._command_usage
    assert "reset" in env._command_usage


def test_get_screen_initial_state():
    """Test get_screen before any commands are used (all LONG help)."""
    env = SimpleEnvironment()

    screen = env.get_screen()
    assert isinstance(screen, ScreenSection)

    content = screen.content

    # Should include state
    assert "Counter: 0" in content

    # Should include Commands section
    assert "Commands:" in content

    # Should include LONG help for increment (unused)
    assert "increment" in content
    assert "Increment the counter by one." in content
    assert "Example:" in content
    assert "```simple" in content

    # Should include LONG help for reset (unused)
    assert "reset" in content
    assert "Reset the counter to zero." in content
    assert "This is a multi-line description." in content


def test_get_screen_progressive_disclosure():
    """Test that get_screen shows SHORT help for used commands."""
    env = SimpleEnvironment()

    # Use increment command
    env.handle_command(CommandText("increment"))

    screen = env.get_screen()
    content = screen.content

    # State should be updated
    assert "Counter: 1" in content

    # increment should now show SHORT help (one line)
    # Should be compact - just "  increment - Increment the counter by one."
    assert "increment - Increment the counter by one." in content

    # reset should still show LONG help (unused)
    assert "Reset the counter to zero." in content
    assert "This is a multi-line description." in content
    assert "Example:" in content


def test_get_screen_all_commands_used():
    """Test get_screen when all commands have been used."""
    env = SimpleEnvironment()

    # Use both commands
    env.handle_command(CommandText("increment"))
    env.handle_command(CommandText("reset"))

    screen = env.get_screen()
    content = screen.content

    # Both should show SHORT help
    assert "increment - Increment the counter by one." in content
    assert "reset - Reset the counter to zero." in content

    # Should NOT include examples
    assert "Example:" not in content
    assert "```simple" not in content


def test_get_screen_uses_class_docstring_when_no_get_state_display():
    """Test that get_screen uses class docstring if get_state_display not implemented."""
    env = DefaultDocstringEnvironment()

    screen = env.get_screen()
    content = screen.content

    # Should use docstring as default state
    assert "Default environment using docstring" in content


def test_get_screen_environment_name_in_code_fence():
    """Test that environment name is correctly derived for code fences."""
    env = TimerEnvironment()

    screen = env.get_screen()
    content = screen.content

    # Should use "timer" (from TimerEnvironment)
    assert "```timer" in content


def test_multiple_environments_separate_usage_tracking():
    """Test that different environment instances track usage separately."""
    env1 = SimpleEnvironment()
    env2 = SimpleEnvironment()

    # Use increment on env1 only
    env1.handle_command(CommandText("increment"))

    # env1 should track increment as used
    screen1 = env1.get_screen()
    assert "increment - Increment the counter by one." in screen1.content

    # env2 should still show LONG help for increment
    screen2 = env2.get_screen()
    assert "Example:" in screen2.content
    assert "```simple" in screen2.content


def test_shutdown_default_implementation():
    """Test that default shutdown does nothing."""
    env = SimpleEnvironment()
    env.shutdown()  # Should not raise


def test_multiline_description_formatting():
    """Test that multi-line descriptions are properly indented."""
    env = SimpleEnvironment()

    screen = env.get_screen()
    content = screen.content

    # Multi-line description should be indented
    assert "Reset the counter to zero." in content
    assert "This is a multi-line description." in content


def test_command_sorting():
    """Test that commands are sorted alphabetically in help."""
    env = SimpleEnvironment()

    screen = env.get_screen()
    content = screen.content

    # Find positions of command names in content
    increment_pos = content.find("increment")
    reset_pos = content.find("reset")

    # increment should appear before reset (alphabetically)
    assert increment_pos < reset_pos


def test_empty_command_string():
    """Test handling of empty command string."""
    env = SimpleEnvironment()

    response = env.handle_command(CommandText(""))
    assert response.success is False
    assert "Unknown command:" in response.output
