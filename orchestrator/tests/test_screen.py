"""Tests for screen module."""

from types import MappingProxyType
from unittest.mock import Mock

from orchestrator.core_types import EnvironmentName, ScreenSection
from orchestrator.screen import collect_screen_updates


class TestCollectScreenUpdates:
    """Test collect_screen_updates function."""

    def test_single_environment(self) -> None:
        """Test collecting screen from single environment."""
        mock_env = Mock()
        mock_env.get_screen.return_value = ScreenSection("Ready")

        envs = {EnvironmentName("bash"): mock_env}

        screen = collect_screen_updates(envs)

        assert EnvironmentName("bash") in screen
        assert screen[EnvironmentName("bash")].content == "Ready"
        mock_env.get_screen.assert_called_once()

    def test_multiple_environments(self) -> None:
        """Test collecting screen from multiple environments."""
        bash_env = Mock()
        bash_env.get_screen.return_value = ScreenSection("Bash ready")

        python_env = Mock()
        python_env.get_screen.return_value = ScreenSection("Python ready")

        envs = {
            EnvironmentName("bash"): bash_env,
            EnvironmentName("python"): python_env,
        }

        screen = collect_screen_updates(envs)

        assert len(screen) == 2
        assert screen[EnvironmentName("bash")].content == "Bash ready"
        assert screen[EnvironmentName("python")].content == "Python ready"

    def test_environment_get_screen_exception(self) -> None:
        """Test that environment get_screen() exception is handled."""
        mock_env = Mock()
        mock_env.get_screen.side_effect = RuntimeError("Screen error")

        envs = {EnvironmentName("bash"): mock_env}

        screen = collect_screen_updates(envs)

        # Should contain error message, not raise exception
        assert EnvironmentName("bash") in screen
        section = screen[EnvironmentName("bash")]
        assert "Error getting screen" in section.content
        assert "RuntimeError" in section.content
        assert "Screen error" in section.content

    def test_returns_immutable_mapping(self) -> None:
        """Test that result is an immutable mapping."""
        mock_env = Mock()
        mock_env.get_screen.return_value = ScreenSection("Ready")

        envs = {EnvironmentName("bash"): mock_env}

        screen = collect_screen_updates(envs)

        assert isinstance(screen, MappingProxyType)

    def test_empty_environments(self) -> None:
        """Test collecting screen from no environments."""
        envs = {}

        screen = collect_screen_updates(envs)

        assert len(screen) == 0
        assert isinstance(screen, MappingProxyType)
