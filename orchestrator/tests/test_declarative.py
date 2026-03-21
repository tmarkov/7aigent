"""Tests for declarative environment base class."""

import tempfile
from pathlib import Path

from orchestrator.core_types import CommandText, ScreenSection
from orchestrator.declarative import DeclarativeEnvironment, command


class SimpleEnvironment(DeclarativeEnvironment):
    """Simple test environment"""

    def __init__(self, project_dir: Path = Path(".")) -> None:
        super().__init__(project_dir=project_dir)
        self.counter = 0

    @command(
        signature="increment",
        examples=[("Increment the counter", "increment")],
    )
    def increment(self, cmd_text: str) -> str:
        """Increment the counter by one."""
        self.counter += 1
        return f"Counter: {self.counter}"

    @command(
        signature="reset",
        examples=[("Reset to zero", "reset")],
    )
    def reset(self, cmd_text: str) -> str:
        """Reset the counter to zero.

        This is a multi-line description.
        """
        self.counter = 0
        return "Counter reset"

    def get_state_display(self) -> str:
        return f"Counter: {self.counter}"


class TimerEnvironment(DeclarativeEnvironment):
    """Timer for tracking elapsed time"""

    def __init__(self, project_dir: Path = Path(".")) -> None:
        super().__init__(project_dir=project_dir)
        self.running = False

    @command(
        signature="start",
        examples=[("Start the timer", "start")],
    )
    def start(self, cmd_text: str) -> str:
        """Start the timer from zero or resume after stop."""
        self.running = True
        return "Timer started"

    @command(
        signature="stop",
        examples=[("Stop the timer", "stop")],
    )
    def stop(self, cmd_text: str) -> str:
        """Stop the timer and record elapsed time."""
        if not self.running:
            raise ValueError("Timer not running")
        self.running = False
        return "Timer stopped"

    def get_state_display(self) -> str:
        return "Timer: Running" if self.running else "Timer: Stopped"


class NoCommandEnvironment(DeclarativeEnvironment):
    """Environment with no commands (uses default get_state_display)"""

    def __init__(self, project_dir: Path = Path(".")) -> None:
        super().__init__(project_dir=project_dir)


def test_command_decorator_attaches_metadata():
    """Test that @command decorator attaches metadata to methods."""
    env = SimpleEnvironment()

    # Check that metadata is attached
    assert hasattr(env.increment, "_command_metadata")
    metadata = env.increment._command_metadata

    assert metadata["signature"] == "increment"
    assert metadata["examples"] == [("Increment the counter", "increment")]


def test_command_decorator_examples_optional():
    """Test that examples parameter is optional and defaults to empty list."""

    class MinimalEnv(DeclarativeEnvironment):
        @command(signature="test")
        def test_cmd(self, cmd_text: str) -> str:
            """Test command with no examples."""
            return "ok"

    env = MinimalEnv()
    metadata = env.test_cmd._command_metadata
    assert metadata["examples"] == []


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
    assert response.processed is True
    assert response.output == "Counter: 1"
    assert env.counter == 1

    # Execute reset command
    response = env.handle_command(CommandText("reset"))
    assert response.processed is True
    assert response.output == "Counter reset"
    assert env.counter == 0


def test_handle_command_unknown_command():
    """Test that unknown commands return error response."""
    env = SimpleEnvironment()

    response = env.handle_command(CommandText("unknown"))
    assert response.processed is False
    assert "Unknown command: unknown" in response.output
    assert "Available: increment, reset" in response.output


def test_handle_command_exception_handling():
    """Test that exceptions from command handlers are caught."""
    env = TimerEnvironment()

    # Try to stop timer that's not running - should raise ValueError
    response = env.handle_command(CommandText("stop"))
    assert response.processed is False
    assert "Error: Timer not running" in response.output


def test_get_help_uses_fallback_template():
    """Test that get_help uses declarative_help.md fallback when no env-specific template."""
    with tempfile.TemporaryDirectory() as tmpdir:
        # Use a temp dir that has no env/simple/help.md
        env = SimpleEnvironment(project_dir=Path(tmpdir))

        help_text = env.get_help()

        # Fallback renders {{commands}} from declarative_help.md
        # Commands should appear with their signatures and docstrings
        assert "increment" in help_text
        assert "reset" in help_text


def test_get_help_renders_docstrings():
    """Test that command docstrings appear in get_help output."""
    with tempfile.TemporaryDirectory() as tmpdir:
        env = SimpleEnvironment(project_dir=Path(tmpdir))

        help_text = env.get_help()

        # Docstrings should appear in command sections
        assert "Increment the counter by one." in help_text
        assert "Reset the counter to zero." in help_text
        assert "This is a multi-line description." in help_text


def test_get_help_renders_examples():
    """Test that examples appear in get_help output with correct format."""
    with tempfile.TemporaryDirectory() as tmpdir:
        env = TimerEnvironment(project_dir=Path(tmpdir))

        help_text = env.get_help()

        # Examples section should appear
        assert "Examples:" in help_text
        # Example descriptions should appear
        assert "Start the timer" in help_text
        # Environment tags should wrap the command text
        assert "<timer>" in help_text
        assert "</timer>" in help_text


def test_get_help_uses_project_override():
    """Test that project_dir/env/{name}/help.md overrides built-in template."""
    with tempfile.TemporaryDirectory() as tmpdir:
        project_dir = Path(tmpdir)

        # Create project override
        override_dir = project_dir / "env" / "simple"
        override_dir.mkdir(parents=True)
        override_help = override_dir / "help.md"
        override_help.write_text(
            "Custom help for simple environment.", encoding="utf-8"
        )

        env = SimpleEnvironment(project_dir=project_dir)

        help_text = env.get_help()

        # Should use project override
        assert "Custom help for simple environment." in help_text
        # Should NOT include the generated commands section (template has no {{commands}})
        assert "### increment" not in help_text


def test_get_help_project_override_with_commands_placeholder():
    """Test that {{commands}} in project override is substituted."""
    with tempfile.TemporaryDirectory() as tmpdir:
        project_dir = Path(tmpdir)

        # Create project override with {{commands}} placeholder
        override_dir = project_dir / "env" / "simple"
        override_dir.mkdir(parents=True)
        override_help = override_dir / "help.md"
        override_help.write_text(
            "Custom header\n\n{{commands}}\n\nCustom footer.", encoding="utf-8"
        )

        env = SimpleEnvironment(project_dir=project_dir)

        help_text = env.get_help()

        assert "Custom header" in help_text
        assert "Custom footer." in help_text
        # Commands should be injected
        assert "increment" in help_text


def test_get_screen_initial_state():
    """Test get_screen combines state and help text."""
    with tempfile.TemporaryDirectory() as tmpdir:
        env = SimpleEnvironment(project_dir=Path(tmpdir))

        screen = env.get_screen()
        assert isinstance(screen, ScreenSection)

        content = screen.content

        # Should include state from get_state_display()
        assert "Counter: 0" in content

        # Should include command help via get_help()
        assert "increment" in content
        assert "reset" in content
        assert "Increment the counter by one." in content


def test_get_screen_no_state_shows_only_help():
    """Test get_screen with empty state shows only help."""
    with tempfile.TemporaryDirectory() as tmpdir:
        # NoCommandEnvironment.get_state_display() returns ""
        env = NoCommandEnvironment(project_dir=Path(tmpdir))

        screen = env.get_screen()

        # Empty state environment — content should be just the help template
        # (which is the rendered empty commands since no @command decorators)
        assert isinstance(screen, ScreenSection)


def test_get_screen_combines_state_and_help():
    """Test that get_screen includes both state and help text."""
    with tempfile.TemporaryDirectory() as tmpdir:
        env = SimpleEnvironment(project_dir=Path(tmpdir))

        env.handle_command(CommandText("increment"))

        screen = env.get_screen()
        content = screen.content

        # State should be updated
        assert "Counter: 1" in content

        # Help should still be included
        assert "increment" in content
        assert "reset" in content


def test_get_screen_environment_name_in_examples():
    """Test that environment name is correctly derived for example tags."""
    with tempfile.TemporaryDirectory() as tmpdir:
        env = TimerEnvironment(project_dir=Path(tmpdir))

        screen = env.get_screen()
        content = screen.content

        # Should use "timer" (from TimerEnvironment → timer)
        assert "<timer>" in content


def test_shutdown_default_implementation():
    """Test that default shutdown does nothing."""
    env = SimpleEnvironment()
    env.shutdown()  # Should not raise


def test_command_sorting():
    """Test that commands are sorted alphabetically in help."""
    with tempfile.TemporaryDirectory() as tmpdir:
        env = SimpleEnvironment(project_dir=Path(tmpdir))

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
    assert response.processed is False
    assert "Unknown command:" in response.output


def test_render_commands_format():
    """Test that _render_commands produces correct markdown format."""
    with tempfile.TemporaryDirectory() as tmpdir:
        env = SimpleEnvironment(project_dir=Path(tmpdir))

        rendered = env._render_commands()

        # Should have ### headers for commands
        assert "### increment" in rendered
        assert "### reset" in rendered

        # Docstrings should appear
        assert "Increment the counter by one." in rendered

        # Examples with tags
        assert "<simple>" in rendered
        assert "</simple>" in rendered


def test_env_name_derivation():
    """Test that env name is correctly derived from class name."""
    env = SimpleEnvironment()
    assert env._env_name() == "simple"

    env2 = TimerEnvironment()
    assert env2._env_name() == "timer"
