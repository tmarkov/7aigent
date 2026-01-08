"""Tests for editor environment."""

import tempfile
from pathlib import Path

import pytest

from orchestrator.core_types import CommandText
from orchestrator.environments.editor import EditorEnvironment


@pytest.fixture
def temp_project_dir():
    """Create a temporary project directory for testing."""
    with tempfile.TemporaryDirectory() as tmpdir:
        project_dir = Path(tmpdir)
        yield project_dir


@pytest.fixture
def editor(temp_project_dir):
    """Create an editor environment with a temporary project directory."""
    return EditorEnvironment(temp_project_dir)


@pytest.fixture
def sample_file(temp_project_dir):
    """Create a sample Python file for testing."""
    filepath = temp_project_dir / "sample.py"
    content = """def hello():
    print("Hello")
    return 42

def world():
    print("World")
    return 100

class Foo:
    def __init__(self):
        self.x = 1

    def bar(self):
        return self.x

class Baz:
    pass
"""
    filepath.write_text(content)
    return filepath


def test_initialization(editor):
    """Test editor environment initialization."""
    assert editor is not None
    screen = editor.get_screen()
    # New format shows "Views: (no views)" plus command help
    assert "Views:" in screen.content
    assert "(no views)" in screen.content
    assert "Commands:" in screen.content


def test_view_command_simple(editor, sample_file):
    """Test creating a simple view."""
    response = editor.handle_command(
        CommandText("view sample.py /^def hello/ /^def world/")
    )
    assert response.success
    assert "Added view [1]" in response.output
    assert "1 match" in response.output

    # Check screen shows the view
    screen = editor.get_screen()
    assert "[1] sample.py" in screen.content
    assert "def hello():" in screen.content
    assert "return 42" in screen.content


def test_view_command_with_label(editor, sample_file):
    """Test creating a view with a label."""
    response = editor.handle_command(
        CommandText("view sample.py /^def hello/ /^def world/ my_function")
    )
    assert response.success
    assert "Added view [1]" in response.output

    screen = editor.get_screen()
    assert '"my_function"' in screen.content


def test_view_command_multiple_matches(editor, sample_file):
    """Test view with multiple pattern matches."""
    # Pattern matches both "Foo" and "Baz" classes
    response = editor.handle_command(
        CommandText("view sample.py /^class/ /^class|^def|^$/")
    )
    assert response.success
    assert "matches" in response.output  # Should say "2 matches"

    screen = editor.get_screen()
    assert "(match 1/2)" in screen.content


def test_next_match_command(editor, sample_file):
    """Test navigating between matches."""
    # Create view with multiple matches
    editor.handle_command(CommandText("view sample.py /^def/ /^$/"))

    # First match should be "hello"
    screen = editor.get_screen()
    assert "def hello():" in screen.content

    # Navigate to next match
    response = editor.handle_command(CommandText("next_match 1"))
    assert response.success
    assert "Showing match" in response.output

    screen = editor.get_screen()
    assert "def world():" in screen.content or "def bar():" in screen.content


def test_prev_match_command(editor, sample_file):
    """Test navigating backwards between matches."""
    # Create view
    editor.handle_command(CommandText("view sample.py /^def/ /^$/"))

    # Go to next match first
    editor.handle_command(CommandText("next_match 1"))

    # Then go back
    response = editor.handle_command(CommandText("prev_match 1"))
    assert response.success

    screen = editor.get_screen()
    assert "def hello():" in screen.content


def test_close_command(editor, sample_file):
    """Test closing a view."""
    # Create a view
    editor.handle_command(CommandText("view sample.py /^def hello/ /^def world/"))

    # Close it
    response = editor.handle_command(CommandText("close 1"))
    assert response.success
    assert "Closed view [1]" in response.output

    # Check screen shows no views
    screen = editor.get_screen()
    assert "Views:" in screen.content
    assert "(no views)" in screen.content


def test_max_views_limit(editor, sample_file):
    """Test that maximum view limit is enforced."""
    # Create MAX_VIEWS (3) views
    editor.handle_command(CommandText("view sample.py /^def hello/ /^def world/"))
    editor.handle_command(CommandText("view sample.py /^def world/ /^class/"))
    editor.handle_command(CommandText("view sample.py /^class Foo/ /^class Baz/"))

    screen = editor.get_screen()
    assert "[1]" in screen.content
    assert "[2]" in screen.content
    assert "[3]" in screen.content

    # Add a 4th view - should auto-close oldest (view 1)
    editor.handle_command(CommandText("view sample.py /^class Baz/ /^$/"))

    screen = editor.get_screen()
    assert "[1]" not in screen.content  # View 1 should be closed
    assert "[2]" in screen.content
    assert "[3]" in screen.content
    assert "[4]" in screen.content


def test_create_command(editor, temp_project_dir):
    """Test creating a new file."""
    response = editor.handle_command(CommandText("create test.txt\nHello\nWorld\n"))
    assert response.success
    assert "Created test.txt" in response.output

    # Verify file was created
    filepath = temp_project_dir / "test.txt"
    assert filepath.exists()
    content = filepath.read_text()
    assert "Hello" in content
    assert "World" in content


def test_create_command_existing_file(editor, sample_file):
    """Test that creating an existing file fails."""
    response = editor.handle_command(CommandText("create sample.py\nContent\n"))
    assert not response.success
    assert "already exists" in response.output


def test_create_command_with_directory(editor, temp_project_dir):
    """Test creating a file in a subdirectory."""
    response = editor.handle_command(
        CommandText("create subdir/newfile.txt\nContent\n")
    )
    assert response.success

    # Verify file and directory were created
    filepath = temp_project_dir / "subdir" / "newfile.txt"
    assert filepath.exists()


def test_edit_command(editor, sample_file):
    """Test editing a file."""
    # First create a view to see line numbers
    editor.handle_command(CommandText("view sample.py /^def hello/ /^def world/"))

    # Get screen to cache content
    screen = editor.get_screen()
    assert "def hello():" in screen.content

    # Edit line 2 (the print statement)
    response = editor.handle_command(
        CommandText('edit sample.py 2-2\n    print("Modified")')
    )
    assert response.success
    assert "Edited sample.py lines 2-2" in response.output

    # Verify file was modified
    content = sample_file.read_text()
    assert 'print("Modified")' in content
    assert 'print("Hello")' not in content


def test_edit_command_multiple_lines(editor, sample_file):
    """Test editing multiple lines at once."""
    # Create view
    editor.handle_command(CommandText("view sample.py /^def hello/ /^def world/"))
    editor.get_screen()  # Cache content

    # Replace lines 2-3 with new content
    response = editor.handle_command(
        CommandText('edit sample.py 2-3\n    print("Line 1")\n    print("Line 2")')
    )
    assert response.success

    content = sample_file.read_text()
    assert 'print("Line 1")' in content
    assert 'print("Line 2")' in content


def test_edit_command_outside_view(editor, sample_file):
    """Test that editing lines outside a view fails."""
    # Create a view that doesn't include the lines we want to edit
    editor.handle_command(CommandText("view sample.py /^def hello/ /^def world/"))
    editor.get_screen()

    # Try to edit line 10 (which is outside the view)
    response = editor.handle_command(CommandText("edit sample.py 10-10\nNew content"))
    assert not response.success
    assert "not in any view" in response.output


def test_edit_command_file_changed(editor, sample_file):
    """Test that editing fails if file changed since view generation."""
    # Create view and cache content
    editor.handle_command(CommandText("view sample.py /^def hello/ /^def world/"))
    editor.get_screen()

    # Modify file externally
    content = sample_file.read_text()
    sample_file.write_text(content.replace("Hello", "Modified"))

    # Try to edit - should fail because file changed
    response = editor.handle_command(CommandText("edit sample.py 2-2\nNew content"))
    assert not response.success
    assert "has changed" in response.output


def test_search_command(editor, sample_file):
    """Test searching for a pattern."""
    response = editor.handle_command(CommandText('search "def " *.py'))
    assert response.success
    assert "Matches:" in response.output
    assert "sample.py" in response.output
    assert "def hello" in response.output or "def world" in response.output


def test_search_command_no_matches(editor, sample_file):
    """Test search with no matches."""
    response = editor.handle_command(CommandText('search "NONEXISTENT" *.py'))
    assert response.success
    assert "No matches found" in response.output


def test_search_command_invalid_regex(editor, sample_file):
    """Test search with invalid regex."""
    response = editor.handle_command(CommandText('search "[invalid" *.py'))
    assert not response.success
    assert "Invalid regex" in response.output


def test_view_nonexistent_file(editor):
    """Test viewing a file that doesn't exist."""
    response = editor.handle_command(CommandText("view nonexistent.py /^def/ /^$/"))
    assert not response.success
    assert "File not found" in response.output


def test_view_patterns_not_found(editor, sample_file):
    """Test view when patterns don't match anything."""
    response = editor.handle_command(
        CommandText("view sample.py /NONEXISTENT1/ /NONEXISTENT2/")
    )
    assert response.success  # View is created
    assert "patterns not found" in response.output

    # First screen generation shows broken view
    screen = editor.get_screen()
    assert "BROKEN" in screen.content

    # Second screen generation removes the broken view
    screen = editor.get_screen()
    assert "Views:" in screen.content
    assert "(no views)" in screen.content


def test_view_end_pattern_not_found_within_limit(editor, temp_project_dir):
    """Test view when end pattern is not found within search limit."""
    # Create a file with many lines
    filepath = temp_project_dir / "large.py"
    lines = ["def start():\n"] + ["    pass\n"] * 1500
    filepath.write_text("".join(lines))

    # View with end pattern that won't be found
    editor.handle_command(CommandText("view large.py /^def start/ /WILL_NOT_BE_FOUND/"))

    screen = editor.get_screen()
    assert "TRUNCATED" in screen.content
    assert "end pattern not found" in screen.content


def test_binary_file_detection(editor, temp_project_dir):
    """Test that binary files are rejected."""
    # Create a binary file
    binary_file = temp_project_dir / "binary.bin"
    binary_file.write_bytes(b"\x00\x01\x02\x03")

    response = editor.handle_command(CommandText("view binary.bin /^/ /$/"))
    assert not response.success
    assert "binary" in response.output.lower()


def test_line_truncation(editor, temp_project_dir):
    """Test that long lines are truncated in display."""
    # Create a file with a very long line
    filepath = temp_project_dir / "long.py"
    long_line = "x = " + "a" * 300
    filepath.write_text(f"def foo():\n    {long_line}\n")

    editor.handle_command(CommandText("view long.py /^def foo/ /^$/"))

    screen = editor.get_screen()
    # Line should be truncated with "..."
    assert "..." in screen.content


def test_invalid_commands(editor):
    """Test handling of invalid commands."""
    # Invalid view command
    response = editor.handle_command(CommandText("view invalid"))
    assert not response.success

    # Invalid close command
    response = editor.handle_command(CommandText("close invalid"))
    assert not response.success

    # Unknown command
    response = editor.handle_command(CommandText("unknown_command"))
    assert not response.success
    assert "Unknown command" in response.output


def test_close_nonexistent_view(editor):
    """Test closing a view that doesn't exist."""
    response = editor.handle_command(CommandText("close 999"))
    assert not response.success
    assert "not found" in response.output


def test_next_match_nonexistent_view(editor):
    """Test next_match on nonexistent view."""
    response = editor.handle_command(CommandText("next_match 999"))
    assert not response.success
    assert "not found" in response.output


def test_multiple_views_display(editor, sample_file):
    """Test that multiple views are displayed correctly."""
    # Create two views
    editor.handle_command(CommandText("view sample.py /^def hello/ /^def world/"))
    editor.handle_command(CommandText("view sample.py /^class Foo/ /^class Baz/"))

    screen = editor.get_screen()
    # Both views should be visible
    assert "[1] sample.py" in screen.content
    assert "[2] sample.py" in screen.content
    assert "def hello" in screen.content
    assert "class Foo" in screen.content


def test_shutdown(editor):
    """Test shutdown method (should not raise)."""
    editor.shutdown()  # Should complete without error


# Help System Tests (Progressive Disclosure)


def test_initial_screen_shows_long_help_for_all_commands(editor):
    """Test that initial screen shows LONG help for all commands (not yet used)."""
    screen = editor.get_screen()
    content = screen.content

    # Should show Commands section
    assert "Commands:" in content

    # Should show LONG help for view (includes example)
    assert "view <file> /<start>/ /<end>/ [label]" in content
    assert "View a section of a file using regex patterns" in content
    assert "Example:" in content
    assert "```editor" in content

    # Should show LONG help for edit (includes example)
    assert "edit <file> <start>-<end>" in content
    assert "Replace lines with new content" in content

    # Should show LONG help for search (includes example)
    assert 'search "<pattern>" <glob>' in content
    assert "Find all occurrences" in content

    # Should show LONG help for create (includes example)
    assert "create <file>" in content
    assert "Create a new file" in content


def test_progressive_disclosure_after_using_view(editor, sample_file):
    """Test that view command shows SHORT help after being used."""
    # Use view command
    editor.handle_command(
        CommandText(f"view {sample_file.name} /^def hello/ /^def world/")
    )

    screen = editor.get_screen()
    content = screen.content

    # view should now show SHORT help (one line, no example)
    assert "view <file> /<start>/ /<end>/ [label] - View" in content

    # But since we haven't used edit yet, it should still show LONG help
    assert "edit <file> <start>-<end>" in content
    assert "Replace lines with new content" in content
    assert "Example:" in content


def test_progressive_disclosure_multiple_commands(editor, sample_file):
    """Test progressive disclosure with multiple commands used."""
    # Use view
    editor.handle_command(
        CommandText(f"view {sample_file.name} /^def hello/ /^def world/")
    )

    # Use search
    editor.handle_command(CommandText('search "print" *.py'))

    screen = editor.get_screen()
    content = screen.content

    # view and search should show SHORT help
    assert "view <file> /<start>/ /<end>/ [label] - View" in content
    assert 'search "<pattern>" <glob> - Find' in content

    # edit and create should still show LONG help (not used yet)
    assert "edit <file> <start>-<end>" in content
    assert "Replace lines with new content" in content
    assert "Example:" in content

    assert "create <file>" in content
    assert "Create a new file" in content


def test_progressive_disclosure_all_commands_used(
    editor, temp_project_dir, sample_file
):
    """Test that all commands show SHORT help after being used."""
    # Use all commands
    editor.handle_command(
        CommandText(f"view {sample_file.name} /^def hello/ /^def world/")
    )
    editor.handle_command(CommandText('search "print" *.py'))

    # Create a file to test create
    editor.handle_command(CommandText("create new.py\n# New file"))

    # Edit the sample file
    editor.handle_command(CommandText(f"edit {sample_file.name} 1-2\n# Edited"))

    # Use close, next_match, prev_match
    editor.handle_command(CommandText("close 1"))
    # Create another view to test next_match/prev_match
    editor.handle_command(
        CommandText(f"view {sample_file.name} /^class/ /^$/ test_label")
    )
    editor.handle_command(CommandText("next_match 2"))
    editor.handle_command(CommandText("prev_match 2"))

    screen = editor.get_screen()
    content = screen.content

    # All commands should now show SHORT help (no examples)
    assert "view <file> /<start>/ /<end>/ [label] - View" in content
    assert 'search "<pattern>" <glob> - Find' in content
    assert "create <file> - Create" in content
    assert "edit <file> <start>-<end> - Replace" in content
    assert "close <id> - Close" in content
    assert "next_match <id> - Show next" in content
    assert "prev_match <id> - Show previous" in content

    # Should NOT include any examples
    assert "Example:" not in content
    assert "```editor" not in content


def test_screen_includes_state_and_commands(editor, sample_file):
    """Test that screen includes both state (views) and commands."""
    # Create a view
    editor.handle_command(
        CommandText(f"view {sample_file.name} /^def hello/ /^def world/")
    )

    screen = editor.get_screen()
    content = screen.content

    # Should include Views section
    assert "Views:" in content
    assert f"[1] {sample_file.name}" in content

    # Should include Commands section
    assert "Commands:" in content
    assert "view" in content
    assert "edit" in content


def test_help_text_updates_per_command_not_per_environment(editor, sample_file):
    """Test that help is tracked per-command, not all-or-nothing."""
    # Use only the view command
    editor.handle_command(
        CommandText(f"view {sample_file.name} /^def hello/ /^def world/")
    )

    screen = editor.get_screen()
    content = screen.content

    # view should be SHORT
    lines_with_view = [line for line in content.split("\n") if "view <file>" in line]
    assert len(lines_with_view) == 1  # Only one line for view command
    assert "view <file> /<start>/ /<end>/ [label] - View" in content

    # edit should still be LONG (multiple lines with example)
    assert "edit <file> <start>-<end>" in content
    assert "Replace lines with new content" in content
    assert "Example:" in content
