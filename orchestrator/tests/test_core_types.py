"""Tests for core type definitions."""

import pytest
from hypothesis import given
from hypothesis import strategies as st

from orchestrator.core_types import (
    CommandResponse,
    CommandText,
    EnvironmentName,
    ScreenSection,
)


class TestEnvironmentName:
    """Tests for EnvironmentName dataclass."""

    # Property-based tests
    @given(st.from_regex(r"[a-zA-Z_][a-zA-Z0-9_]*", fullmatch=True))
    def test_valid_identifiers_accepted(self, identifier: str) -> None:
        """Valid Python identifiers should create valid EnvironmentNames."""
        name = EnvironmentName(identifier)
        assert name.value == identifier

    @given(st.text().filter(lambda s: s and not s.isidentifier()))
    def test_invalid_identifiers_rejected(self, invalid: str) -> None:
        """Invalid Python identifiers should raise ValueError."""
        with pytest.raises(ValueError, match="Invalid environment name"):
            EnvironmentName(invalid)

    # Example-based tests for edge cases
    def test_empty_string_rejected(self) -> None:
        """Empty string is not a valid identifier."""
        with pytest.raises(ValueError, match="Invalid environment name"):
            EnvironmentName("")

    def test_underscore_prefix_allowed(self) -> None:
        """Identifiers can start with underscore."""
        name = EnvironmentName("_private")
        assert name.value == "_private"

    def test_multiple_underscores_allowed(self) -> None:
        """Multiple underscores are valid."""
        name = EnvironmentName("__dunder__")
        assert name.value == "__dunder__"

    def test_digits_not_allowed_at_start(self) -> None:
        """Identifiers cannot start with digits."""
        with pytest.raises(ValueError, match="Invalid environment name"):
            EnvironmentName("123env")

    def test_digits_allowed_after_first_char(self) -> None:
        """Digits are allowed after the first character."""
        name = EnvironmentName("env123")
        assert name.value == "env123"

    def test_hyphen_not_allowed(self) -> None:
        """Hyphens are not valid in identifiers."""
        with pytest.raises(ValueError, match="Invalid environment name"):
            EnvironmentName("my-env")

    def test_space_not_allowed(self) -> None:
        """Spaces are not valid in identifiers."""
        with pytest.raises(ValueError, match="Invalid environment name"):
            EnvironmentName("my env")

    def test_dot_not_allowed(self) -> None:
        """Dots are not valid in identifiers."""
        with pytest.raises(ValueError, match="Invalid environment name"):
            EnvironmentName("my.env")

    def test_common_environment_names(self) -> None:
        """Common environment names should be accepted."""
        valid_names = ["bash", "python", "editor", "gdb", "timer", "my_custom_env"]
        for name_str in valid_names:
            name = EnvironmentName(name_str)
            assert name.value == name_str

    def test_frozen_dataclass(self) -> None:
        """EnvironmentName should be immutable."""
        name = EnvironmentName("bash")
        with pytest.raises(AttributeError):
            name.value = "python"  # type: ignore[misc]

    def test_error_message_includes_value(self) -> None:
        """Error message should include the invalid value."""
        with pytest.raises(ValueError, match="my-env"):
            EnvironmentName("my-env")


class TestCommandText:
    """Tests for CommandText dataclass."""

    # Property-based tests
    @given(st.text())
    def test_any_string_accepted(self, text: str) -> None:
        """Any string should be accepted as command text."""
        cmd = CommandText(text)
        assert cmd.value == text

    # Example-based tests
    def test_empty_command(self) -> None:
        """Empty string is a valid command."""
        cmd = CommandText("")
        assert cmd.value == ""

    def test_simple_command(self) -> None:
        """Simple shell command."""
        cmd = CommandText("ls -la")
        assert cmd.value == "ls -la"

    def test_multiline_command(self) -> None:
        """Multiline commands are supported."""
        cmd = CommandText("def foo():\n    return 42")
        assert cmd.value == "def foo():\n    return 42"

    def test_unicode_command(self) -> None:
        """Unicode characters in commands."""
        cmd = CommandText("echo 'こんにちは'")
        assert cmd.value == "echo 'こんにちは'"

    def test_special_characters(self) -> None:
        """Commands can contain special characters."""
        cmd = CommandText("grep -E '^[0-9]+$' file.txt | sort | uniq")
        assert cmd.value == "grep -E '^[0-9]+$' file.txt | sort | uniq"

    def test_frozen_dataclass(self) -> None:
        """CommandText should be immutable."""
        cmd = CommandText("ls")
        with pytest.raises(AttributeError):
            cmd.value = "pwd"  # type: ignore[misc]


class TestCommandResponse:
    """Tests for CommandResponse dataclass."""

    # Property-based tests
    @given(st.text(), st.booleans())
    def test_any_output_and_status(self, output: str, success: bool) -> None:
        """Any output string and success boolean should be accepted."""
        response = CommandResponse(output, success)
        assert response.output == output
        assert response.processed == success

    # Example-based tests
    def test_successful_response(self) -> None:
        """Successful command response."""
        response = CommandResponse("total 48\ndrwxr-xr-x...", True)
        assert response.output == "total 48\ndrwxr-xr-x..."
        assert response.processed is True

    def test_failed_response(self) -> None:
        """Failed command response."""
        response = CommandResponse("Error: file not found", False)
        assert response.output == "Error: file not found"
        assert response.processed is False

    def test_empty_output(self) -> None:
        """Empty output is valid."""
        response = CommandResponse("", True)
        assert response.output == ""
        assert response.processed is True

    def test_multiline_output(self) -> None:
        """Multiline output."""
        output = "line 1\nline 2\nline 3"
        response = CommandResponse(output, True)
        assert response.output == output

    def test_mutable_dataclass_allows_adding_fields(self) -> None:
        """CommandResponse should be mutable to allow adding environment-specific fields."""
        response = CommandResponse("output", True)
        # Should be able to add new fields (e.g., exit_code for bash)
        response.exit_code = 0
        assert response.exit_code == 0


class TestScreenSection:
    """Tests for ScreenSection dataclass."""

    # Property-based tests
    @given(st.text())
    def test_any_content_accepted(self, content: str) -> None:
        """Any content should be accepted."""
        section = ScreenSection(content)
        assert section.content == content

    # Example-based tests
    def test_simple_screen_section(self) -> None:
        """Simple screen section."""
        section = ScreenSection("Working directory: /home/user\nLast exit code: 0")
        assert section.content == "Working directory: /home/user\nLast exit code: 0"

    def test_empty_content(self) -> None:
        """Empty content is valid."""
        section = ScreenSection("")
        assert section.content == ""

    def test_multiline_content(self) -> None:
        """Multiline content."""
        content = (
            "Views:\n  [1] src/main.py:1-20\n     1  import sys\n     2  def main():"
        )
        section = ScreenSection(content)
        assert section.content == content

    def test_frozen_dataclass(self) -> None:
        """ScreenSection should be immutable."""
        section = ScreenSection("content")
        with pytest.raises(AttributeError):
            section.content = "new content"  # type: ignore[misc]


class TestDataclassImmutability:
    """Cross-cutting tests for immutability of all dataclasses."""

    def test_frozen_types_are_immutable(self) -> None:
        """Some core type dataclasses should be frozen (immutable)."""
        env_name = EnvironmentName("bash")
        cmd_text = CommandText("ls")
        screen_section = ScreenSection("content")

        # Try to modify each - all should raise AttributeError
        with pytest.raises(AttributeError):
            env_name.value = "python"  # type: ignore[misc]

        with pytest.raises(AttributeError):
            cmd_text.value = "pwd"  # type: ignore[misc]

        with pytest.raises(AttributeError):
            screen_section.content = "new"  # type: ignore[misc]

    def test_command_response_is_mutable(self) -> None:
        """CommandResponse should be mutable to allow adding environment-specific fields."""
        cmd_response = CommandResponse("output", True)

        # Should be able to add new fields
        cmd_response.exit_code = 0
        assert cmd_response.exit_code == 0

    def test_dataclass_equality(self) -> None:
        """Dataclasses with same values should be equal."""
        assert EnvironmentName("bash") == EnvironmentName("bash")
        assert CommandText("ls") == CommandText("ls")
        assert CommandResponse("out", True) == CommandResponse("out", True)
        assert ScreenSection("c") == ScreenSection("c")

    def test_dataclass_inequality(self) -> None:
        """Dataclasses with different values should not be equal."""
        assert EnvironmentName("bash") != EnvironmentName("python")
        assert CommandText("ls") != CommandText("pwd")
        assert CommandResponse("out", True) != CommandResponse("out", False)
        assert ScreenSection("c") != ScreenSection("d")

    def test_frozen_dataclasses_are_hashable(self) -> None:
        """Frozen dataclasses should be hashable."""
        # Should be able to use in sets and as dict keys
        env_names = {EnvironmentName("bash"), EnvironmentName("python")}
        assert len(env_names) == 2

        cmd_dict = {CommandText("ls"): "list", CommandText("pwd"): "print dir"}
        assert len(cmd_dict) == 2

        # CommandResponse is not frozen, so not hashable
        # (needed to allow adding environment-specific fields like exit_code)

        screen_set = {ScreenSection("a"), ScreenSection("b")}
        assert len(screen_set) == 2
