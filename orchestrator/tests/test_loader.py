"""Tests for environment loader."""

import tempfile
from pathlib import Path

from orchestrator.core_types import EnvironmentName
from orchestrator.loader import (
    find_environment_class,
    load_all_environments,
    validate_environment_class,
)


def test_load_all_environments_loads_built_ins():
    """Verify built-in environments are loaded."""
    with tempfile.TemporaryDirectory() as tmpdir:
        envs = load_all_environments(Path(tmpdir))

        # Should load built-in environments
        assert EnvironmentName("bash") in envs
        assert EnvironmentName("python") in envs
        assert EnvironmentName("editor") in envs


def test_load_all_environments_with_no_env_dir():
    """Verify loading works when no env/ directory exists."""
    with tempfile.TemporaryDirectory() as tmpdir:
        envs = load_all_environments(Path(tmpdir))

        # Should still load built-ins
        assert EnvironmentName("bash") in envs
        assert len(envs) >= 3


def test_load_all_environments_with_empty_env_dir():
    """Verify loading works with empty env/ directory."""
    with tempfile.TemporaryDirectory() as tmpdir:
        project_dir = Path(tmpdir)
        env_dir = project_dir / "env"
        env_dir.mkdir()

        envs = load_all_environments(project_dir)

        # Should load built-ins
        assert EnvironmentName("bash") in envs


def test_load_all_environments_with_valid_adhoc():
    """Verify ad-hoc environments are loaded."""
    with tempfile.TemporaryDirectory() as tmpdir:
        project_dir = Path(tmpdir)
        env_dir = project_dir / "env"
        env_dir.mkdir()

        # Create simple timer environment
        timer_file = env_dir / "timer.py"
        timer_file.write_text(
            """
from orchestrator.core_types import CommandText, CommandResponse, ScreenSection

class TimerEnvironment:
    def __init__(self):
        self._running = False

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        if cmd.value == "start":
            self._running = True
            return CommandResponse("Started", success=True)
        else:
            return CommandResponse("Unknown", success=False)

    def get_screen(self) -> ScreenSection:
        status = "Running" if self._running else "Stopped"
        return ScreenSection(content=f"Timer: {status}", max_lines=10)

    def shutdown(self) -> None:
        pass
"""
        )

        envs = load_all_environments(project_dir)

        # Should load timer environment
        assert EnvironmentName("timer") in envs
        assert EnvironmentName("bash") in envs


def test_find_environment_class_finds_class():
    """Verify find_environment_class finds environment classes."""
    import orchestrator.environments.bash as bash_module

    env_class = find_environment_class(bash_module)

    assert env_class is not None
    assert env_class.__name__ == "BashEnvironment"


def test_validate_environment_class_accepts_valid():
    """Verify validate_environment_class accepts valid environments."""
    from orchestrator.environments.bash import BashEnvironment

    errors = validate_environment_class(BashEnvironment)

    assert len(errors) == 0


def test_validate_environment_class_rejects_missing_handle_command():
    """Verify validate_environment_class rejects missing handle_command."""

    class BadEnv:
        def get_screen(self):
            pass

        def shutdown(self):
            pass

    errors = validate_environment_class(BadEnv)

    assert len(errors) > 0
    assert any("handle_command" in err for err in errors)


def test_validate_environment_class_rejects_missing_get_screen():
    """Verify validate_environment_class rejects missing get_screen."""

    class BadEnv:
        def handle_command(self, cmd):
            pass

        def shutdown(self):
            pass

    errors = validate_environment_class(BadEnv)

    assert len(errors) > 0
    assert any("get_screen" in err for err in errors)
