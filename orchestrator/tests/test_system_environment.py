"""Tests for system environment."""

import tempfile
from pathlib import Path

from orchestrator.core_types import CommandText
from orchestrator.environments.system import SystemEnvironment

from . import timeout


class TestSystemEnvironment:
    """Test SystemEnvironment implementation."""

    @timeout(10)
    def test_screen_shows_project_directory(self) -> None:
        """Requirement: Screen must display the project directory path.

        The agent needs to know which directory it is working in so it can
        construct correct file paths and navigate the project.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            env = SystemEnvironment(project_dir)

            screen = env.get_screen()
            assert f"Project directory: {project_dir}" in screen.content

    @timeout(10)
    def test_screen_shows_agents_md_when_present(self) -> None:
        """Requirement: Screen must include AGENTS.md content when the file exists.

        AGENTS.md provides project-specific instructions that the agent must follow.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            agents_md = project_dir / "AGENTS.md"
            agents_md.write_text("# Project Instructions\n\nUse pytest for testing.")

            env = SystemEnvironment(project_dir)
            screen = env.get_screen()

            assert "AGENTS.md" in screen.content
            assert "Project Instructions" in screen.content
            assert "Use pytest for testing" in screen.content

    @timeout(10)
    def test_screen_without_agents_md(self) -> None:
        """Requirement: Screen must not mention AGENTS.md when the file does not exist.

        Most projects will not have an AGENTS.md; showing a missing-file reference
        would be confusing and misleading to the agent.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            env = SystemEnvironment(project_dir)

            screen = env.get_screen()
            assert "Project directory:" in screen.content
            assert "AGENTS.md" not in screen.content

    @timeout(10)
    def test_screen_shows_git_status_in_git_repo(self) -> None:
        """Requirement: Screen must show git status when the project is a git repository.

        The agent needs repository state (current branch, staged/unstaged changes)
        to understand the project context before making edits.
        """
        import shutil
        import subprocess

        if shutil.which("git") is None:
            import pytest

            pytest.skip("git not available")

        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)

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
            assert "On branch" in screen.content or "##" in screen.content

    @timeout(10)
    def test_screen_excludes_git_status_in_non_git_directory(self) -> None:
        """Requirement: Screen must not show git status for non-git directories.

        Not all projects use git; showing a git section in a non-git directory
        would be incorrect and confusing to the agent.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            env = SystemEnvironment(project_dir)

            screen = env.get_screen()
            assert "Project directory:" in screen.content
            assert "Git Status" not in screen.content

    @timeout(10)
    def test_screen_shows_file_tree(self) -> None:
        """Requirement: Screen must show the project file tree.

        The agent needs to know what files exist to navigate and edit the project.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)

            (project_dir / "src").mkdir()
            (project_dir / "src" / "main.py").write_text("print('hello')")
            (project_dir / "README.md").write_text("# Project")
            (project_dir / "tests").mkdir()
            (project_dir / "tests" / "test_main.py").write_text("def test(): pass")

            env = SystemEnvironment(project_dir)
            screen = env.get_screen()

            assert (
                "File Tree" in screen.content or "Directory Contents" in screen.content
            )
            assert "src" in screen.content
            assert "README.md" in screen.content
            assert "tests" in screen.content

    @timeout(10)
    def test_screen_shows_directory_contents_when_tree_unavailable(self) -> None:
        """Requirement: Screen must show directory contents even when the tree command is absent.

        The environment must fall back to a directory listing so the agent always
        has file-system visibility regardless of which tools are installed.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            (project_dir / "main.py").write_text("print('hello')")
            (project_dir / "README.md").write_text("# Project")

            env = SystemEnvironment(project_dir)
            screen = env.get_screen()

            assert "Project directory:" in screen.content
            assert (
                "File Tree" in screen.content or "Directory Contents" in screen.content
            )
            assert "main.py" in screen.content
            assert "README.md" in screen.content

    @timeout(10)
    def test_system_environment_accepts_no_commands(self) -> None:
        """Requirement: SystemEnvironment must reject all commands — it is read-only context.

        The system environment exposes no agent-controllable commands; all content
        is derived automatically from the project directory on each screen refresh.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            project_dir = Path(tmpdir)
            env = SystemEnvironment(project_dir)

            response = env.handle_command(CommandText("anything"))
            assert (
                response.processed is False
            ), "System environment must reject all commands"

            screen = env.get_screen()
            assert "Project directory:" in screen.content
