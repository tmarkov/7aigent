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
        mock_env.get_screen.return_value = ScreenSection("Ready", max_lines=50)

        envs = {EnvironmentName("bash"): mock_env}

        screen = collect_screen_updates(envs)

        assert EnvironmentName("bash") in screen
        assert screen[EnvironmentName("bash")].content == "Ready"
        mock_env.get_screen.assert_called_once()

    def test_multiple_environments(self) -> None:
        """Test collecting screen from multiple environments."""
        bash_env = Mock()
        bash_env.get_screen.return_value = ScreenSection("Bash ready", max_lines=50)

        python_env = Mock()
        python_env.get_screen.return_value = ScreenSection("Python ready", max_lines=30)

        envs = {
            EnvironmentName("bash"): bash_env,
            EnvironmentName("python"): python_env,
        }

        screen = collect_screen_updates(envs)

        assert len(screen) == 2
        assert screen[EnvironmentName("bash")].content == "Bash ready"
        assert screen[EnvironmentName("python")].content == "Python ready"

    def test_truncation_applied(self) -> None:
        """Test that truncation is applied to screen sections."""
        mock_env = Mock()
        # Create content with 5 lines but max_lines=3
        content = "line1\nline2\nline3\nline4\nline5"
        mock_env.get_screen.return_value = ScreenSection(content, max_lines=3)

        envs = {EnvironmentName("bash"): mock_env}

        screen = collect_screen_updates(envs)

        section = screen[EnvironmentName("bash")]
        lines = section.content.split("\n")

        # Should have 3 original lines + 1 truncation message
        assert len(lines) == 4
        assert "line1" in lines[0]
        assert "line2" in lines[1]
        assert "line3" in lines[2]
        assert "truncated" in lines[3].lower()
        assert "2 more lines" in lines[3]

    def test_no_truncation_when_within_limit(self) -> None:
        """Test that content within limit is not truncated."""
        mock_env = Mock()
        content = "line1\nline2"
        mock_env.get_screen.return_value = ScreenSection(content, max_lines=10)

        envs = {EnvironmentName("bash"): mock_env}

        screen = collect_screen_updates(envs)

        # Should be unchanged
        assert screen[EnvironmentName("bash")].content == content

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
        mock_env.get_screen.return_value = ScreenSection("Ready", max_lines=50)

        envs = {EnvironmentName("bash"): mock_env}

        screen = collect_screen_updates(envs)

        assert isinstance(screen, MappingProxyType)

    def test_empty_environments(self) -> None:
        """Test collecting screen from no environments."""
        envs = {}

        screen = collect_screen_updates(envs)

        assert len(screen) == 0
        assert isinstance(screen, MappingProxyType)

    def test_truncation_single_line_message(self) -> None:
        """Test truncation message for single line."""
        mock_env = Mock()
        # 3 lines with max_lines=2
        content = "line1\nline2\nline3"
        mock_env.get_screen.return_value = ScreenSection(content, max_lines=2)

        envs = {EnvironmentName("bash"): mock_env}

        screen = collect_screen_updates(envs)

        section = screen[EnvironmentName("bash")]
        assert "1 more line, truncated" in section.content

    def test_truncation_multiple_lines_message(self) -> None:
        """Test truncation message for multiple lines."""
        mock_env = Mock()
        # 5 lines with max_lines=2
        content = "line1\nline2\nline3\nline4\nline5"
        mock_env.get_screen.return_value = ScreenSection(content, max_lines=2)

        envs = {EnvironmentName("bash"): mock_env}

        screen = collect_screen_updates(envs)

        section = screen[EnvironmentName("bash")]
        assert "3 more lines, truncated" in section.content
