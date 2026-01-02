"""Editor environment implementation."""

import glob as glob_module
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from orchestrator.core_types import CommandResponse, CommandText, ScreenSection


@dataclass
class View:
    """
    A view of a file section defined by regex patterns.

    Attributes:
        view_id: Unique identifier for this view
        filepath: Path to the file being viewed
        start_pattern: Regex pattern for start boundary
        end_pattern: Regex pattern for end boundary
        current_match_index: Which match to display (0-based)
        label: Optional semantic label for the view
    """

    view_id: int
    filepath: Path
    start_pattern: str
    end_pattern: str
    current_match_index: int = 0
    label: Optional[str] = None


@dataclass
class ViewContent:
    """
    Cached content from a view's last generation.

    Used for edit verification to ensure file hasn't changed
    since the view was displayed.

    Attributes:
        view_id: Which view this content belongs to
        filepath: Path to the file
        start_line: First line number in the view (1-based)
        end_line: Last line number in the view (1-based)
        lines: The actual content lines
    """

    view_id: int
    filepath: Path
    start_line: int
    end_line: int
    lines: list[str]


@dataclass
class PatternMatch:
    """
    A match of start and end patterns in a file.

    Attributes:
        start_line: Line number where start pattern matched (1-based)
        end_line: Line number where end pattern matched (1-based)
        lines: Content lines between patterns (inclusive)
        truncated: Whether end pattern was not found within limit
    """

    start_line: int
    end_line: int
    lines: list[str]
    truncated: bool = False


class EditorEnvironment:
    """
    Editor environment for viewing and editing files with pattern-based views.

    Provides pattern-based file viewing and line-based editing operations.
    Maintains persistent views of code sections that update automatically
    when files change.

    Design:
        - Views use regex patterns for boundaries, not fixed line numbers
        - Always re-reads files on every screen generation (no caching)
        - Views persist across commands until explicitly closed
        - Maximum 3 views, auto-close oldest when adding 4th
        - Edit verification ensures file hasn't changed since view generation
        - Pattern search with 1000 line limit to prevent pathological cases

    State maintained:
        - List of views (id, filepath, patterns, match index, label)
        - Cached content from last screen generation (for edit verification)
        - Next view ID counter

    Limitations:
        - Binary files not supported
        - Maximum 1000 lines per view
        - Maximum 3 concurrent views
        - Edit only allowed on lines visible in a view
    """

    # Maximum number of concurrent views
    MAX_VIEWS = 3
    # Maximum lines to search for end pattern
    MAX_SEARCH_LINES = 1000
    # Maximum line length before truncation
    MAX_LINE_LENGTH = 200

    def __init__(self, project_dir: Path) -> None:
        """
        Initialize editor environment.

        Args:
            project_dir: Root directory for file operations
        """
        self._project_dir = project_dir
        self._used = False
        self._views: list[View] = []
        self._next_view_id = 1
        self._cached_content: dict[int, ViewContent] = {}

    def _is_binary_file(self, filepath: Path) -> bool:
        """
        Check if a file is binary (not text).

        Args:
            filepath: Path to check

        Returns:
            True if file appears to be binary
        """
        try:
            with filepath.open("rb") as f:
                # Read first 8KB to check for null bytes
                chunk = f.read(8192)
                return b"\x00" in chunk
        except Exception:
            return False

    def _read_file_lines(self, filepath: Path) -> Optional[list[str]]:
        """
        Read file lines for processing.

        Args:
            filepath: Path to read

        Returns:
            List of lines (with newlines stripped), or None on error
        """
        try:
            # Check if binary
            if self._is_binary_file(filepath):
                return None

            with filepath.open("r", encoding="utf-8", errors="replace") as f:
                return [line.rstrip("\n\r") for line in f]
        except Exception:
            return None

    def _find_pattern_matches(
        self, filepath: Path, start_pattern: str, end_pattern: str
    ) -> list[PatternMatch]:
        """
        Find all matches of start/end pattern pairs in a file.

        Args:
            filepath: File to search
            start_pattern: Regex for start boundary
            end_pattern: Regex for end boundary

        Returns:
            List of pattern matches (may be empty)
        """
        lines = self._read_file_lines(filepath)
        if lines is None:
            return []

        matches: list[PatternMatch] = []

        # Compile patterns
        try:
            start_re = re.compile(start_pattern)
            end_re = re.compile(end_pattern)
        except re.error:
            # Invalid regex
            return []

        # Find all start pattern matches
        i = 0
        while i < len(lines):
            if start_re.search(lines[i]):
                start_line = i + 1  # Convert to 1-based

                # Search for end pattern within MAX_SEARCH_LINES
                end_line = None
                truncated = False

                for j in range(i + 1, min(i + 1 + self.MAX_SEARCH_LINES, len(lines))):
                    if end_re.search(lines[j]):
                        end_line = j + 1  # Convert to 1-based
                        break

                if end_line is None:
                    # End pattern not found within limit
                    # Truncate at MAX_SEARCH_LINES or end of file
                    end_line = min(start_line + self.MAX_SEARCH_LINES - 1, len(lines))
                    truncated = True

                # Extract content (convert back to 0-based for slicing)
                content_lines = lines[start_line - 1 : end_line]

                matches.append(
                    PatternMatch(
                        start_line=start_line,
                        end_line=end_line,
                        lines=content_lines,
                        truncated=truncated,
                    )
                )

                # Move past this match
                i = end_line  # Continue search from after this match
            else:
                i += 1

        return matches

    def _generate_view_content(self, view: View) -> Optional[tuple[PatternMatch, int]]:
        """
        Generate content for a view by finding pattern matches.

        Args:
            view: The view to generate content for

        Returns:
            Tuple of (match, total_matches) or None if file error or no matches
        """
        # Resolve filepath relative to project_dir
        filepath = self._project_dir / view.filepath

        if not filepath.exists():
            return None

        # Find all matches
        matches = self._find_pattern_matches(
            filepath, view.start_pattern, view.end_pattern
        )

        if not matches:
            return None

        # Get the requested match (or wrap around)
        match_index = view.current_match_index % len(matches)
        return (matches[match_index], len(matches))

    def _format_view_for_screen(
        self, view: View, match: PatternMatch, total_matches: int
    ) -> list[str]:
        """
        Format a view for display on screen.

        Args:
            view: The view being displayed
            match: The pattern match to display
            total_matches: Total number of matches found

        Returns:
            List of formatted lines for screen display
        """
        lines = []

        # Header: [id] filepath /pattern/ to /pattern/ (match N/M) [label]
        match_info = f"(match {view.current_match_index + 1}/{total_matches})"
        label_info = f' "{view.label}"' if view.label else ""
        header = f"[{view.view_id}] {view.filepath} /{view.start_pattern}/ to /{view.end_pattern}/ {match_info}{label_info}"
        lines.append(header)

        # Content with line numbers
        for i, line in enumerate(match.lines):
            line_num = match.start_line + i
            # Truncate long lines
            if len(line) > self.MAX_LINE_LENGTH:
                line = line[: self.MAX_LINE_LENGTH] + "..."
            lines.append(f"{line_num:6d}  {line}")

        # Add truncation notice if needed
        if match.truncated:
            lines.append(
                f"       [TRUNCATED: end pattern not found within {self.MAX_SEARCH_LINES} lines]"
            )

        return lines

    def _parse_view_command(self, cmd: str) -> Optional[dict]:
        """
        Parse a view command.

        Format: view <filepath> /<start_pattern>/ /<end_pattern>/ [<label>]

        Args:
            cmd: Command string

        Returns:
            Dict with filepath, start_pattern, end_pattern, label or None if invalid
        """
        # Match: view <filepath> /<pattern>/ /<pattern>/ [label]
        # Patterns are between / delimiters
        match = re.match(r"view\s+(\S+)\s+/(.+?)/\s+/(.+?)/(?:\s+(.+))?$", cmd.strip())
        if not match:
            return None

        filepath, start_pattern, end_pattern, label = match.groups()

        return {
            "filepath": filepath,
            "start_pattern": start_pattern,
            "end_pattern": end_pattern,
            "label": label,
        }

    def _parse_edit_command(self, cmd_lines: list[str]) -> Optional[dict]:
        """
        Parse an edit command.

        Format:
            edit <filepath> <start_line>-<end_line>
            <new content lines...>

        Args:
            cmd_lines: Command split into lines

        Returns:
            Dict with filepath, start_line, end_line, new_content or None if invalid
        """
        if not cmd_lines:
            return None

        # First line: edit <filepath> <start>-<end>
        match = re.match(r"edit\s+(\S+)\s+(\d+)-(\d+)$", cmd_lines[0].strip())
        if not match:
            return None

        filepath, start_str, end_str = match.groups()
        start_line = int(start_str)
        end_line = int(end_str)

        # Remaining lines are new content
        new_content = cmd_lines[1:]

        return {
            "filepath": filepath,
            "start_line": start_line,
            "end_line": end_line,
            "new_content": new_content,
        }

    def _parse_create_command(self, cmd_lines: list[str]) -> Optional[dict]:
        """
        Parse a create command.

        Format:
            create <filepath>
            <initial content lines...>

        Args:
            cmd_lines: Command split into lines

        Returns:
            Dict with filepath, content or None if invalid
        """
        if not cmd_lines:
            return None

        # First line: create <filepath>
        match = re.match(r"create\s+(\S+)$", cmd_lines[0].strip())
        if not match:
            return None

        filepath = match.group(1)

        # Remaining lines are content
        content = cmd_lines[1:]

        return {"filepath": filepath, "content": content}

    def _parse_search_command(self, cmd: str) -> Optional[dict]:
        """
        Parse a search command.

        Format: search "<pattern>" <glob>

        Args:
            cmd: Command string

        Returns:
            Dict with pattern, glob or None if invalid
        """
        # Match: search "pattern" glob
        match = re.match(r'search\s+"(.+?)"\s+(\S+)$', cmd.strip())
        if not match:
            return None

        pattern, glob_pattern = match.groups()

        return {"pattern": pattern, "glob": glob_pattern}

    def _handle_view(self, cmd: str) -> CommandResponse:
        """Handle view command."""
        parsed = self._parse_view_command(cmd)
        if not parsed:
            return CommandResponse(
                output="Invalid view command. Format: view <filepath> /<start_pattern>/ /<end_pattern>/ [<label>]",
                success=False,
            )

        filepath = Path(parsed["filepath"])
        start_pattern = parsed["start_pattern"]
        end_pattern = parsed["end_pattern"]
        label = parsed["label"]

        # Check if file exists
        full_path = self._project_dir / filepath
        if not full_path.exists():
            return CommandResponse(output=f"File not found: {filepath}", success=False)

        # Check if binary
        if self._is_binary_file(full_path):
            return CommandResponse(
                output=f"Cannot view binary file: {filepath}", success=False
            )

        # Auto-close oldest view if at maximum
        if len(self._views) >= self.MAX_VIEWS:
            oldest_view = self._views.pop(0)
            # Remove cached content for closed view
            self._cached_content.pop(oldest_view.view_id, None)

        # Create new view
        view = View(
            view_id=self._next_view_id,
            filepath=filepath,
            start_pattern=start_pattern,
            end_pattern=end_pattern,
            current_match_index=0,
            label=label,
        )
        self._views.append(view)
        self._next_view_id += 1
        self._used = True

        # Try to generate content to verify patterns match
        result = self._generate_view_content(view)
        if result is None:
            return CommandResponse(
                output=f"Added view [{view.view_id}] {filepath} /{start_pattern}/ to /{end_pattern}/ (patterns not found)",
                success=True,
            )

        _, total_matches = result
        return CommandResponse(
            output=f"Added view [{view.view_id}] {filepath} /{start_pattern}/ to /{end_pattern}/ ({total_matches} match{'es' if total_matches != 1 else ''})",
            success=True,
        )

    def _handle_next_match(self, view_id: int) -> CommandResponse:
        """Handle next_match command."""
        # Find view
        view = next((v for v in self._views if v.view_id == view_id), None)
        if not view:
            return CommandResponse(output=f"View [{view_id}] not found", success=False)

        # Generate content to get total matches
        result = self._generate_view_content(view)
        if result is None:
            return CommandResponse(
                output=f"View [{view_id}] has no matches", success=False
            )

        _, total_matches = result

        # Increment match index (wraps around)
        view.current_match_index = (view.current_match_index + 1) % total_matches

        return CommandResponse(
            output=f"Showing match {view.current_match_index + 1}/{total_matches}",
            success=True,
        )

    def _handle_prev_match(self, view_id: int) -> CommandResponse:
        """Handle prev_match command."""
        # Find view
        view = next((v for v in self._views if v.view_id == view_id), None)
        if not view:
            return CommandResponse(output=f"View [{view_id}] not found", success=False)

        # Generate content to get total matches
        result = self._generate_view_content(view)
        if result is None:
            return CommandResponse(
                output=f"View [{view_id}] has no matches", success=False
            )

        _, total_matches = result

        # Decrement match index (wraps around)
        view.current_match_index = (view.current_match_index - 1) % total_matches

        return CommandResponse(
            output=f"Showing match {view.current_match_index + 1}/{total_matches}",
            success=True,
        )

    def _handle_close(self, view_id: int) -> CommandResponse:
        """Handle close command."""
        # Find and remove view
        view = next((v for v in self._views if v.view_id == view_id), None)
        if not view:
            return CommandResponse(output=f"View [{view_id}] not found", success=False)

        self._views.remove(view)
        self._cached_content.pop(view_id, None)

        return CommandResponse(output=f"Closed view [{view_id}]", success=True)

    def _handle_edit(self, cmd_lines: list[str]) -> CommandResponse:
        """Handle edit command."""
        parsed = self._parse_edit_command(cmd_lines)
        if not parsed:
            return CommandResponse(
                output="Invalid edit command. Format: edit <filepath> <start_line>-<end_line>\\n<new content>",
                success=False,
            )

        filepath = Path(parsed["filepath"])
        start_line = parsed["start_line"]
        end_line = parsed["end_line"]
        new_content = parsed["new_content"]

        # Find which view contains these line numbers
        view_content = None
        for cached in self._cached_content.values():
            if (
                cached.filepath == filepath
                and cached.start_line <= start_line
                and cached.end_line >= end_line
            ):
                view_content = cached
                break

        if view_content is None:
            return CommandResponse(
                output=f"Can only edit lines visible in a view. Lines {start_line}-{end_line} not in any view of {filepath}",
                success=False,
            )

        # Read current file content
        full_path = self._project_dir / filepath
        lines = self._read_file_lines(full_path)
        if lines is None:
            return CommandResponse(
                output=f"Cannot read file: {filepath}", success=False
            )

        # Verify cached content matches current file
        # Extract the lines that should match the cached content
        cached_start_idx = view_content.start_line - 1
        cached_end_idx = view_content.end_line
        current_cached_section = lines[cached_start_idx:cached_end_idx]

        if current_cached_section != view_content.lines:
            return CommandResponse(
                output=f"File {filepath} has changed since view was generated. Cannot safely edit. Please refresh view.",
                success=False,
            )

        # Perform edit: replace lines [start_line, end_line] (inclusive) with new content
        # Convert to 0-based indices
        start_idx = start_line - 1
        end_idx = end_line  # Inclusive end, so this is the index after the last line to replace

        # Replace the lines
        new_lines = lines[:start_idx] + new_content + lines[end_idx:]

        # Write back to file
        try:
            full_path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
        except Exception as e:
            return CommandResponse(
                output=f"Error writing file {filepath}: {e}", success=False
            )

        return CommandResponse(
            output=f"Edited {filepath} lines {start_line}-{end_line}", success=True
        )

    def _handle_create(self, cmd_lines: list[str]) -> CommandResponse:
        """Handle create command."""
        parsed = self._parse_create_command(cmd_lines)
        if not parsed:
            return CommandResponse(
                output="Invalid create command. Format: create <filepath>\\n<content>",
                success=False,
            )

        filepath = Path(parsed["filepath"])
        content = parsed["content"]

        # Check if file already exists
        full_path = self._project_dir / filepath
        if full_path.exists():
            return CommandResponse(
                output=f"File already exists: {filepath}", success=False
            )

        # Create parent directories if needed
        try:
            full_path.parent.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            return CommandResponse(
                output=f"Error creating directory for {filepath}: {e}", success=False
            )

        # Write file
        try:
            full_path.write_text("\n".join(content) + "\n", encoding="utf-8")
        except Exception as e:
            return CommandResponse(
                output=f"Error creating file {filepath}: {e}", success=False
            )

        return CommandResponse(output=f"Created {filepath}", success=True)

    def _handle_search(self, cmd: str) -> CommandResponse:
        """Handle search command."""
        parsed = self._parse_search_command(cmd)
        if not parsed:
            return CommandResponse(
                output='Invalid search command. Format: search "<pattern>" <glob>',
                success=False,
            )

        pattern = parsed["pattern"]
        glob_pattern = parsed["glob"]

        # Compile regex
        try:
            regex = re.compile(pattern)
        except re.error as e:
            return CommandResponse(output=f"Invalid regex pattern: {e}", success=False)

        # Find matching files
        try:
            filepaths = glob_module.glob(
                str(self._project_dir / glob_pattern), recursive=True
            )
        except Exception as e:
            return CommandResponse(output=f"Error in glob pattern: {e}", success=False)

        # Search in each file
        matches = []
        for filepath_str in filepaths:
            filepath = Path(filepath_str)

            # Skip directories
            if not filepath.is_file():
                continue

            # Skip binary files
            if self._is_binary_file(filepath):
                continue

            # Read and search
            lines = self._read_file_lines(filepath)
            if lines is None:
                continue

            for line_num, line in enumerate(lines, start=1):
                if regex.search(line):
                    # Make path relative to project_dir
                    rel_path = filepath.relative_to(self._project_dir)
                    # Truncate long lines
                    display_line = line
                    if len(display_line) > self.MAX_LINE_LENGTH:
                        display_line = display_line[: self.MAX_LINE_LENGTH] + "..."
                    matches.append(f"{rel_path}:{line_num}: {display_line}")

        if not matches:
            return CommandResponse(output="No matches found", success=True)

        output = "Matches:\n" + "\n".join(matches)
        return CommandResponse(output=output, success=True)

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        """
        Execute an editor command.

        Args:
            cmd: The command to execute

        Returns:
            Response with command output and success status

        Supported commands:
            view <filepath> /<start_pattern>/ /<end_pattern>/ [<label>]
            edit <filepath> <start_line>-<end_line>
            <new content on subsequent lines>
            create <filepath>
            <initial content on subsequent lines>
            close <view_id>
            next_match <view_id>
            prev_match <view_id>
            search "<pattern>" <glob>
        """
        # Split into lines for multi-line commands
        cmd_lines = cmd.value.split("\n")
        first_line = cmd_lines[0].strip()

        # Parse command type
        if first_line.startswith("view "):
            return self._handle_view(first_line)
        elif first_line.startswith("edit "):
            return self._handle_edit(cmd_lines)
        elif first_line.startswith("create "):
            return self._handle_create(cmd_lines)
        elif first_line.startswith("close "):
            # Parse: close <view_id>
            match = re.match(r"close\s+(\d+)$", first_line)
            if not match:
                return CommandResponse(
                    output="Invalid close command. Format: close <view_id>",
                    success=False,
                )
            view_id = int(match.group(1))
            return self._handle_close(view_id)
        elif first_line.startswith("next_match "):
            # Parse: next_match <view_id>
            match = re.match(r"next_match\s+(\d+)$", first_line)
            if not match:
                return CommandResponse(
                    output="Invalid next_match command. Format: next_match <view_id>",
                    success=False,
                )
            view_id = int(match.group(1))
            return self._handle_next_match(view_id)
        elif first_line.startswith("prev_match "):
            # Parse: prev_match <view_id>
            match = re.match(r"prev_match\s+(\d+)$", first_line)
            if not match:
                return CommandResponse(
                    output="Invalid prev_match command. Format: prev_match <view_id>",
                    success=False,
                )
            view_id = int(match.group(1))
            return self._handle_prev_match(view_id)
        elif first_line.startswith("search "):
            return self._handle_search(first_line)
        else:
            return CommandResponse(
                output=f"Unknown command: {first_line}",
                success=False,
            )

    def get_screen(self) -> ScreenSection:
        """
        Get current editor environment state.

        Returns:
            Screen section showing all active views with their content

        Format before first use:
            Editor (no views)

        Format with views:
            Views:
              [1] src/main.py /^def main/ to /^if __name__/ (match 1/1)
                 45  def main():
                 46      parser = argparse.ArgumentParser()
                 ...
        """
        if not self._used or not self._views:
            return ScreenSection(content="Editor (no views)", max_lines=50)

        # Clear cached content from previous generation
        self._cached_content.clear()

        # Generate view content and format for screen
        screen_lines = ["Views:"]

        for view in self._views:
            result = self._generate_view_content(view)

            if result is None:
                # Patterns not found or file error - mark as broken and remove
                screen_lines.append(
                    f"  [{view.view_id}] {view.filepath} [BROKEN: patterns not found]"
                )
                # We'll remove broken views after iteration
                continue

            match, total_matches = result

            # Cache this view's content for edit verification
            self._cached_content[view.view_id] = ViewContent(
                view_id=view.view_id,
                filepath=view.filepath,
                start_line=match.start_line,
                end_line=match.end_line,
                lines=match.lines.copy(),
            )

            # Format view for display
            view_lines = self._format_view_for_screen(view, match, total_matches)
            for line in view_lines:
                screen_lines.append(f"  {line}")

            # Add blank line between views
            screen_lines.append("")

        # Remove broken views (those that returned None)
        self._views = [
            v for v in self._views if self._generate_view_content(v) is not None
        ]

        content = "\n".join(screen_lines)
        return ScreenSection(content=content, max_lines=50)

    def shutdown(self) -> None:
        """Clean up editor environment (no resources to release)."""
        pass
