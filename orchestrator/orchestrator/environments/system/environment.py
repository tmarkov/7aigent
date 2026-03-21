"""System environment for project context and global information."""

import subprocess
from pathlib import Path

from orchestrator.declarative import DeclarativeEnvironment


class SystemEnvironment(DeclarativeEnvironment):
    """
    System environment for displaying project context.

    Provides:
    - Project directory path
    - AGENTS.md content (if present)
    - Git status (if git repository)
    - File tree (2 levels deep)

    This environment has no commands initially, but may have commands in the
    future for skills, subagents, etc.
    """

    def __init__(self, project_dir: Path) -> None:
        """
        Initialize system environment.

        Args:
            project_dir: Path to the project directory
        """
        super().__init__(project_dir=project_dir)
        self._project_dir = project_dir

    def get_state_display(self) -> str:
        """
        Generate system information screen.

        Shows project directory, AGENTS.md (if exists), git status (if git repo),
        and file tree.

        Returns:
            Formatted string with project context
        """
        lines = []

        # Project directory
        lines.append(f"Project directory: {self._project_dir}")
        lines.append("")

        # AGENTS.md content if present
        agents_md_path = self._project_dir / "AGENTS.md"
        if agents_md_path.exists():
            try:
                agents_content = agents_md_path.read_text(encoding="utf-8")
                lines.append("=== AGENTS.md (Project-specific instructions) ===")
                lines.append(agents_content.strip())
                lines.append("=" * 50)
                lines.append("")
            except Exception as e:
                lines.append(f"[Warning: Could not read AGENTS.md: {e}]")
                lines.append("")

        # Git status if git repository
        git_dir = self._project_dir / ".git"
        if git_dir.exists():
            try:
                result = subprocess.run(
                    ["git", "status", "--short", "--branch"],
                    cwd=str(self._project_dir),
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                if result.returncode == 0:
                    lines.append("=== Git Status ===")
                    lines.append(result.stdout.strip())
                    lines.append("")
            except Exception as e:
                lines.append(f"[Warning: Could not get git status: {e}]")
                lines.append("")

        # File tree (2 levels deep, directories first)
        tree_success = False
        try:
            result = subprocess.run(
                ["tree", "-L", "2", "-a", "--dirsfirst"],
                cwd=str(self._project_dir),
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0:
                lines.append("=== File Tree ===")
                lines.append(result.stdout.strip())
                tree_success = True
        except FileNotFoundError:
            # tree command not available, try fallback
            pass
        except Exception as e:
            lines.append(f"[Warning: Could not run tree: {e}]")

        # Fallback to ls if tree didn't work
        if not tree_success:
            try:
                lines.append("=== Directory Contents ===")
                result = subprocess.run(
                    ["ls", "-la"],
                    cwd=str(self._project_dir),
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                if result.returncode == 0:
                    lines.append(result.stdout.strip())
            except Exception as e:
                lines.append(f"[Warning: Could not list directory: {e}]")

        return "\n".join(lines)
