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
    """Verify ad-hoc environments are loaded from directory-based structure."""
    with tempfile.TemporaryDirectory() as tmpdir:
        project_dir = Path(tmpdir)
        env_dir = project_dir / "env"

        # Create timer environment in directory structure
        timer_dir = env_dir / "timer"
        timer_dir.mkdir(parents=True)
        timer_file = timer_dir / "environment.py"
        timer_file.write_text(
            """
from pathlib import Path
from orchestrator.core_types import CommandText, CommandResponse, ScreenSection

class TimerEnvironment:
    def __init__(self, project_dir: Path = Path(".")) -> None:
        self._running = False

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        if cmd.value == "start":
            self._running = True
            return CommandResponse("Started", processed=True)
        else:
            return CommandResponse("Unknown", processed=False)

    def get_screen(self) -> ScreenSection:
        status = "Running" if self._running else "Stopped"
        return ScreenSection(content=f"Timer: {status}")

    def shutdown(self) -> None:
        pass
"""
        )

        envs = load_all_environments(project_dir)

        # Should load timer environment
        assert EnvironmentName("timer") in envs
        assert EnvironmentName("bash") in envs


def test_load_all_environments_override_only_dir():
    """Verify that dirs with only help.md (no environment.py) are skipped as env loads."""
    with tempfile.TemporaryDirectory() as tmpdir:
        project_dir = Path(tmpdir)
        env_dir = project_dir / "env"

        # Create override-only directory (just a help.md, no environment.py)
        editor_override = env_dir / "editor"
        editor_override.mkdir(parents=True)
        (editor_override / "help.md").write_text(
            "Custom editor help override.", encoding="utf-8"
        )

        envs = load_all_environments(project_dir)

        # Built-in editor should still be present
        assert EnvironmentName("editor") in envs
        # No extra "editor" env added (still just one)
        editor_count = sum(1 for k in envs if k.value == "editor")
        assert editor_count == 1


def test_load_all_environments_project_override_applied():
    """Verify that project help.md override is visible via get_screen()."""
    with tempfile.TemporaryDirectory() as tmpdir:
        project_dir = Path(tmpdir)
        env_dir = project_dir / "env"

        # Create help.md override for bash
        bash_override = env_dir / "bash"
        bash_override.mkdir(parents=True)
        (bash_override / "help.md").write_text(
            "Custom bash help for this project.", encoding="utf-8"
        )

        envs = load_all_environments(project_dir)
        bash_env = envs[EnvironmentName("bash")]

        # The screen should include the custom help content
        screen = bash_env.get_screen()
        assert "Custom bash help for this project." in screen.content


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


def test_validate_environment_class_requires_project_dir():
    """Verify validate_environment_class rejects envs without project_dir constructor param."""
    from orchestrator.core_types import CommandResponse, CommandText, ScreenSection

    class NoProjectDirEnv:
        def __init__(self) -> None:  # missing project_dir
            pass

        def handle_command(self, cmd: CommandText) -> CommandResponse:
            return CommandResponse("ok", processed=True)

        def get_screen(self) -> ScreenSection:
            return ScreenSection(content="ok")

        def shutdown(self) -> None:
            pass

    errors = validate_environment_class(NoProjectDirEnv)

    assert len(errors) > 0
    assert any("project_dir" in err for err in errors)


def test_load_all_environments_skips_flat_py_files():
    """Verify that flat .py files in env/ are not loaded (only subdirs with environment.py)."""
    with tempfile.TemporaryDirectory() as tmpdir:
        project_dir = Path(tmpdir)
        env_dir = project_dir / "env"
        env_dir.mkdir()

        # Create a flat .py file (old format — should be ignored)
        flat_file = env_dir / "legacy.py"
        flat_file.write_text(
            """
# This flat format is no longer supported
"""
        )

        envs = load_all_environments(project_dir)

        # legacy should NOT be loaded
        assert EnvironmentName("legacy") not in envs
        # built-ins still loaded
        assert EnvironmentName("bash") in envs
