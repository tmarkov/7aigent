"""Query pipeline executor for editor environment.

This module executes parsed queries by:
1. Running the matcher (pattern via ripgrep, or line-based)
2. Applying pipeline operations sequentially
3. Returning windows

Uses ripgrep as the search backend for fast pattern matching.
"""

import glob
import re
import subprocess
from pathlib import Path
from typing import Optional

from orchestrator.environments.editor.indentation import IndentationAnalyzer
from orchestrator.environments.editor.parser import (
    ContextOp,
    DownOp,
    ExcludeOp,
    FilterOp,
    LimitOp,
    LineMatcher,
    PatternMatcher,
    QueryAST,
    UntilBlankOp,
    UntilOp,
    UpOp,
    UpUntilOp,
    WhileIndentOp,
)
from orchestrator.environments.editor.windows import Window

# Limits
MAX_MATCHES_PER_FILE = 50
MAX_FILES = 100
MAX_WINDOW_LINES = 200


class QueryExecutor:
    """Executes query pipelines and returns windows."""

    def __init__(self, project_dir: Path):
        """Initialize executor.

        Args:
            project_dir: Project directory for file operations
        """
        self._project_dir = project_dir
        self._indent_analyzer = IndentationAnalyzer()

    def execute(self, ast: QueryAST, excluded_files: set[Path]) -> list[Window]:
        """Execute query pipeline.

        Args:
            ast: Parsed query AST
            excluded_files: Files to exclude from search

        Returns:
            List of windows

        Examples:
            >>> from orchestrator.environments.editor.parser import QueryParser
            >>> parser = QueryParser()
            >>> ast = parser.parse_peek("peek /TODO/ in **/*.py | limit 5")
            >>> executor = QueryExecutor(Path("."))
            >>> windows = executor.execute(ast, set())
            >>> isinstance(windows, list)
            True
        """
        # Phase 1: Find matching files
        if isinstance(ast.matcher, PatternMatcher):
            matching_files = self._find_matching_files(ast.matcher.glob, excluded_files)
        elif isinstance(ast.matcher, LineMatcher):
            if ast.matcher.glob:
                matching_files = self._find_matching_files(
                    ast.matcher.glob, excluded_files
                )
            elif ast.matcher.filepath:
                # Single file - no glob expansion needed
                matching_files = [ast.matcher.filepath]
            else:
                return []  # Neither glob nor filepath set - invalid
        else:
            return []

        # Phase 2: Apply matcher to each file
        windows = []
        for filepath in matching_files:
            if isinstance(ast.matcher, PatternMatcher):
                windows.extend(
                    self._apply_pattern_to_file(
                        filepath, ast.matcher.pattern, ast.label or "peek"
                    )
                )
            elif isinstance(ast.matcher, LineMatcher):
                window = self._extract_lines_from_file(
                    filepath,
                    ast.matcher.start_line,
                    ast.matcher.end_line,
                    ast.label or "peek",
                )
                if window:
                    windows.append(window)

        # Phase 3: Apply operations sequentially
        for op in ast.operations:
            if isinstance(op, ContextOp):
                windows = self._expand_context(windows, op.n)
            elif isinstance(op, UpOp):
                windows = self._expand_up(windows, op.n)
            elif isinstance(op, DownOp):
                windows = self._expand_down(windows, op.n)
            elif isinstance(op, UntilOp):
                windows = self._expand_until(windows, op.pattern)
            elif isinstance(op, UpUntilOp):
                windows = self._expand_up_until(windows, op.pattern)
            elif isinstance(op, UntilBlankOp):
                windows = self._expand_until_blank(windows)
            elif isinstance(op, WhileIndentOp):
                windows = self._expand_while_indent(windows)
            elif isinstance(op, FilterOp):
                windows = self._filter(windows, op.pattern)
            elif isinstance(op, ExcludeOp):
                windows = self._exclude(windows, op.pattern)
            elif isinstance(op, LimitOp):
                windows = self._limit(windows, op.n)

        return windows

    def _find_matching_files(
        self, glob_pattern: str, excluded: set[Path]
    ) -> list[Path]:
        """Find files matching glob pattern.

        Args:
            glob_pattern: Glob pattern for files (or exact path)
            excluded: Excluded file paths

        Returns:
            List of matching file paths
        """
        # Expand glob pattern relative to project dir
        pattern = str(self._project_dir / glob_pattern)
        try:
            matched_files = glob.glob(pattern, recursive=True)
        except (OSError, ValueError):
            return []

        # Enforce file limit and filter excluded
        result = []
        for filepath_str in matched_files:
            filepath = Path(filepath_str)

            # Resolve relative to project dir
            if not filepath.is_absolute():
                filepath = self._project_dir / filepath

            # Skip excluded files
            if filepath in excluded:
                continue

            result.append(filepath)

            if len(result) >= MAX_FILES:
                break

        return result

    def _apply_pattern_to_file(
        self, filepath: Path, regex_pattern: str, label: str
    ) -> list[Window]:
        """Apply regex pattern to a single file.

        Args:
            filepath: File to search
            regex_pattern: Regex pattern to search for
            label: Query label

        Returns:
            List of windows (one per match)
        """
        cmd = [
            "rg",
            "--line-number",
            "--no-heading",
            "--max-count",
            str(MAX_MATCHES_PER_FILE),
            regex_pattern,
            str(filepath),
        ]

        try:
            result = subprocess.run(
                cmd,
                cwd=self._project_dir,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return []

        # ripgrep returns 0 on matches, 1 on no matches, 2+ on error
        if result.returncode >= 2:
            return []

        windows = []
        for line in result.stdout.split("\n"):
            if not line:
                continue

            # Parse ripgrep output: line_num:content
            parts = line.split(":", 1)
            if len(parts) < 2:
                continue

            line_num_str, content = parts
            try:
                line_num = int(line_num_str)
            except ValueError:
                continue

            windows.append(
                Window(
                    filepath=filepath,
                    start_line=line_num,
                    end_line=line_num,
                    lines=[content],
                    label=label,
                )
            )

        return windows

    def _extract_lines_from_file(
        self, filepath: Path, start_line: int, end_line: int, label: str
    ) -> Optional[Window]:
        """Extract line range from a single file.

        Args:
            filepath: Path to file (relative or absolute)
            start_line: Start line (1-based)
            end_line: End line (1-based, inclusive)
            label: Query label

        Returns:
            Window with extracted lines, or None if file can't be read or lines out of bounds
        """
        # Resolve to absolute path
        if not filepath.is_absolute():
            filepath = self._project_dir / filepath

        try:
            with open(filepath, "r", encoding="utf-8", errors="replace") as f:
                all_lines = f.readlines()

            # Extract specified range (convert to 0-based)
            start_idx = start_line - 1
            end_idx = end_line  # Inclusive, so no -1

            # Check if start is valid (within file bounds)
            if start_idx < 0 or start_idx >= len(all_lines):
                return None

            # Clamp end to file length
            end_idx = min(end_idx, len(all_lines))
            actual_end_line = end_idx  # This is the actual 1-based end line

            lines = [line.rstrip("\n") for line in all_lines[start_idx:end_idx]]

            return Window(
                filepath=filepath,
                start_line=start_line,
                end_line=actual_end_line,  # Use clamped value
                lines=lines,
                label=label,
            )
        except (OSError, IOError):
            return None

    def _expand_context(self, windows: list[Window], n: int) -> list[Window]:
        """Expand windows N lines up and down.

        Args:
            windows: Input windows
            n: Number of lines to expand in each direction

        Returns:
            Expanded windows
        """
        result = []
        for window in windows:
            new_start = max(1, window.start_line - n)
            new_end = window.end_line + n

            # Enforce max window size
            if new_end - new_start + 1 > MAX_WINDOW_LINES:
                new_end = new_start + MAX_WINDOW_LINES - 1

            lines = self._read_lines(window.filepath, new_start, new_end)
            result.append(
                Window(
                    filepath=window.filepath,
                    start_line=new_start,
                    end_line=new_end,
                    lines=lines,
                    label=window.label,
                )
            )
        return result

    def _expand_up(self, windows: list[Window], n: int) -> list[Window]:
        """Expand windows N lines upward.

        Args:
            windows: Input windows
            n: Number of lines to expand

        Returns:
            Expanded windows
        """
        result = []
        for window in windows:
            new_start = max(1, window.start_line - n)
            new_end = window.end_line

            # Enforce max window size
            if new_end - new_start + 1 > MAX_WINDOW_LINES:
                new_start = new_end - MAX_WINDOW_LINES + 1

            lines = self._read_lines(window.filepath, new_start, new_end)
            result.append(
                Window(
                    filepath=window.filepath,
                    start_line=new_start,
                    end_line=new_end,
                    lines=lines,
                    label=window.label,
                )
            )
        return result

    def _expand_down(self, windows: list[Window], n: int) -> list[Window]:
        """Expand windows N lines downward.

        Args:
            windows: Input windows
            n: Number of lines to expand

        Returns:
            Expanded windows
        """
        result = []
        for window in windows:
            new_start = window.start_line
            new_end = window.end_line + n

            # Enforce max window size
            if new_end - new_start + 1 > MAX_WINDOW_LINES:
                new_end = new_start + MAX_WINDOW_LINES - 1

            lines = self._read_lines(window.filepath, new_start, new_end)
            result.append(
                Window(
                    filepath=window.filepath,
                    start_line=new_start,
                    end_line=new_end,
                    lines=lines,
                    label=window.label,
                )
            )
        return result

    def _expand_until(self, windows: list[Window], pattern: str) -> list[Window]:
        """Expand windows down until pattern matches.

        Args:
            windows: Input windows
            pattern: Regex pattern to match

        Returns:
            Expanded windows
        """
        result = []
        pattern_re = re.compile(pattern)

        for window in windows:
            all_lines = self._read_all_lines(window.filepath)
            if not all_lines:
                result.append(window)
                continue

            new_end = window.end_line
            max_end = min(len(all_lines), window.end_line + MAX_WINDOW_LINES)

            # Search for pattern
            for line_num in range(window.end_line + 1, max_end + 1):
                line = all_lines[line_num - 1]
                if pattern_re.search(line):
                    # Stop before match line (match NOT included)
                    new_end = line_num - 1
                    break
                new_end = line_num

            lines = self._read_lines(window.filepath, window.start_line, new_end)
            result.append(
                Window(
                    filepath=window.filepath,
                    start_line=window.start_line,
                    end_line=new_end,
                    lines=lines,
                    label=window.label,
                )
            )
        return result

    def _expand_up_until(self, windows: list[Window], pattern: str) -> list[Window]:
        """Expand windows up until pattern matches.

        Args:
            windows: Input windows
            pattern: Regex pattern to match

        Returns:
            Expanded windows
        """
        result = []
        pattern_re = re.compile(pattern)

        for window in windows:
            all_lines = self._read_all_lines(window.filepath)
            if not all_lines:
                result.append(window)
                continue

            new_start = window.start_line
            min_start = max(1, window.start_line - MAX_WINDOW_LINES)

            # Search upward for pattern
            for line_num in range(window.start_line - 1, min_start - 1, -1):
                line = all_lines[line_num - 1]
                if pattern_re.search(line):
                    # Include match line (becomes new window start)
                    new_start = line_num
                    break

            lines = self._read_lines(window.filepath, new_start, window.end_line)
            result.append(
                Window(
                    filepath=window.filepath,
                    start_line=new_start,
                    end_line=window.end_line,
                    lines=lines,
                    label=window.label,
                )
            )
        return result

    def _expand_until_blank(self, windows: list[Window]) -> list[Window]:
        """Expand windows down until blank line.

        Args:
            windows: Input windows

        Returns:
            Expanded windows
        """
        result = []

        for window in windows:
            all_lines = self._read_all_lines(window.filepath)
            if not all_lines:
                result.append(window)
                continue

            new_end = window.end_line
            max_end = min(len(all_lines), window.end_line + MAX_WINDOW_LINES)

            # Search for blank line
            for line_num in range(window.end_line + 1, max_end + 1):
                line = all_lines[line_num - 1]
                if line.strip() == "":
                    # Stop before blank line (blank NOT included)
                    new_end = line_num - 1
                    break
                new_end = line_num

            lines = self._read_lines(window.filepath, window.start_line, new_end)
            result.append(
                Window(
                    filepath=window.filepath,
                    start_line=window.start_line,
                    end_line=new_end,
                    lines=lines,
                    label=window.label,
                )
            )
        return result

    def _expand_while_indent(self, windows: list[Window]) -> list[Window]:
        """Expand windows while indented.

        Args:
            windows: Input windows

        Returns:
            Expanded windows
        """
        result = []

        for window in windows:
            all_lines = self._read_all_lines(window.filepath)
            if not all_lines:
                result.append(window)
                continue

            new_end = self._indent_analyzer.expand_while_indented(
                all_lines, window.start_line, window.end_line, MAX_WINDOW_LINES
            )

            lines = self._read_lines(window.filepath, window.start_line, new_end)
            result.append(
                Window(
                    filepath=window.filepath,
                    start_line=window.start_line,
                    end_line=new_end,
                    lines=lines,
                    label=window.label,
                )
            )
        return result

    def _filter(self, windows: list[Window], pattern: str) -> list[Window]:
        """Keep only windows containing pattern.

        Args:
            windows: Input windows
            pattern: Regex pattern

        Returns:
            Filtered windows
        """
        pattern_re = re.compile(pattern)
        result = []

        for window in windows:
            # Check if any line matches pattern
            if any(pattern_re.search(line) for line in window.lines):
                result.append(window)

        return result

    def _exclude(self, windows: list[Window], pattern: str) -> list[Window]:
        """Remove windows containing pattern.

        Args:
            windows: Input windows
            pattern: Regex pattern

        Returns:
            Filtered windows
        """
        pattern_re = re.compile(pattern)
        result = []

        for window in windows:
            # Check if any line matches pattern
            if not any(pattern_re.search(line) for line in window.lines):
                result.append(window)

        return result

    def _limit(self, windows: list[Window], n: int) -> list[Window]:
        """Keep only first N windows.

        Args:
            windows: Input windows
            n: Number to keep

        Returns:
            Limited windows
        """
        return windows[:n]

    def _read_all_lines(self, filepath: Path) -> list[str]:
        """Read all lines from file.

        Args:
            filepath: Path to file

        Returns:
            List of lines (with newlines stripped)
        """
        try:
            with open(filepath, "r", encoding="utf-8", errors="replace") as f:
                return [line.rstrip("\n") for line in f.readlines()]
        except (OSError, IOError):
            return []

    def _read_lines(self, filepath: Path, start_line: int, end_line: int) -> list[str]:
        """Read specific lines from file.

        Args:
            filepath: Path to file
            start_line: Start line (1-based)
            end_line: End line (1-based, inclusive)

        Returns:
            List of lines
        """
        all_lines = self._read_all_lines(filepath)
        if not all_lines:
            return []

        # Convert to 0-based indexing
        start_idx = start_line - 1
        end_idx = end_line

        # Clamp to file bounds
        start_idx = max(0, start_idx)
        end_idx = min(len(all_lines), end_idx)

        return all_lines[start_idx:end_idx]
