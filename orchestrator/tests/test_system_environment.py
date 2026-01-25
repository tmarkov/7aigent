"""Tests for system environment."""

import tempfile
from pathlib import Path

from orchestrator.environments.system import SystemEnvironment


class TestSystemEnvironment:
    """Test SystemEnvironment implementation."""

    def test_screen_shows_project_directory(self) -> None:
        """Test that screen displays project directory path."""
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            env = SystemEnvironment(project_dir)

            screen = env.get_screen()
            assert f"Project directory: {project_dir}" in screen.content
            assert screen.max_lines == 100

    def test_screen_shows_agents_md_when_present(self) -> None:
        """Test that AGENTS.md content is included when file exists."""
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            agents_md = project_dir / "AGENTS.md"
            agents_md.write_text("# Project Instructions\n\nUse pytest for testing.")

            env = SystemEnvironment(project_dir)
            screen = env.get_screen()

            assert "AGENTS.md" in screen.content
            assert "Project Instructions" in screen.content
            assert "Use pytest for testing" in screen.content

    def test_screen_without_agents_md(self) -> None:
        """Test that screen works when AGENTS.md doesn't exist."""
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            env = SystemEnvironment(project_dir)

            screen = env.get_screen()
            # Should not crash, and should not mention AGENTS.md
            assert "Project directory:" in screen.content
            assert "AGENTS.md" not in screen.content

    def test_screen_shows_git_status_in_git_repo(self) -> None:
        """Test that git status is shown in git repositories."""
        import shutil
        import subprocess

        # Skip test if git not available
        if shutil.which("git") is None:
            import pytest

            pytest.skip("git not available")

        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)

            # Initialize git repo
            subprocess.run(
                ["git", "init"], cwd=str(project_dir), capture_output=True, check=True
            )
            subprocess.run(
                ["git", "config", "user.name", "Test User"],
                cwd=str(project_dir),
                capture_output=True,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.email", "test@example.com"],
                cwd=str(project_dir),
                capture_output=True,
                check=True,
            )

            # Create and commit a file
            test_file = project_dir / "test.txt"
            test_file.write_text("hello")
            subprocess.run(
                ["git", "add", "test.txt"],
                cwd=str(project_dir),
                capture_output=True,
                check=True,
            )
            subprocess.run(
                ["git", "commit", "-m", "Initial commit"],
                cwd=str(project_dir),
                capture_output=True,
                check=True,
            )

            env = SystemEnvironment(project_dir)
            screen = env.get_screen()

            assert "Git Status" in screen.content
            # Should show branch info
            assert "On branch" in screen.content or "##" in screen.content

    def test_screen_without_git_repo(self) -> None:
        """Test that screen works in non-git directories."""
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            env = SystemEnvironment(project_dir)

            screen = env.get_screen()
            # Should not crash
            assert "Project directory:" in screen.content
            # Should not mention git status
            assert "Git Status" not in screen.content or "Warning" in screen.content

    def test_screen_shows_file_tree(self) -> None:
        """Test that file tree is included in screen."""
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)

            # Create some files and directories
            (project_dir / "src").mkdir()
            (project_dir / "src" / "main.py").write_text("print('hello')")
            (project_dir / "README.md").write_text("# Project")
            (project_dir / "tests").mkdir()
            (project_dir / "tests" / "test_main.py").write_text("def test(): pass")

            env = SystemEnvironment(project_dir)
            screen = env.get_screen()

            # Should show file tree section
            assert (
                "File Tree" in screen.content or "Directory Contents" in screen.content
            )
            # Should show created files/directories
            assert "src" in screen.content
            assert "README.md" in screen.content
            assert "tests" in screen.content

    def test_screen_handles_missing_tree_command(self) -> None:
        """Test that screen falls back gracefully if tree command missing."""
        # This test just verifies it doesn't crash
        # The actual fallback depends on system configuration
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            env = SystemEnvironment(project_dir)

            screen = env.get_screen()
            # Should not crash
            assert "Project directory:" in screen.content
            # Should show either tree or ls output
            assert (
                "File Tree" in screen.content or "Directory Contents" in screen.content
            )

    def test_has_no_commands_initially(self) -> None:
        """Test that SystemEnvironment has no commands initially."""
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            env = SystemEnvironment(project_dir)

            # Check that _commands dict is empty
            assert len(env._commands) == 0

            # Screen should not show "Commands:" section since there are none
            screen = env.get_screen()
            # Should still show state, but commands section will be empty
            assert "Project directory:" in screen.content
