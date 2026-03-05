"""Query parser for editor environment.

This module parses view and peek commands into AST structures that can be
executed by the QueryExecutor.

Command syntax:
    view <label> <matcher> in <glob> | <operations>
    peek <matcher> in <glob> | <operations>

Matchers:
    Pattern: /regex/ in <glob>
    Line: line N in <file> or line N-M in <file> (peek only)

Operations:
    context N, up N, down N
    until /pattern/, up-until /pattern/, until-blank
    while-indent
    filter /pattern/, exclude /pattern/
    limit N
"""

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


# Matcher classes
@dataclass
class Matcher:
    """Base class for matchers."""

    pass


@dataclass
class PatternMatcher(Matcher):
    """Pattern-based matcher using regex."""

    pattern: str  # Regex pattern
    glob: str  # File glob pattern


@dataclass
class LineMatcher(Matcher):
    """Line-based matcher (peek only)."""

    start_line: int  # 1-based
    end_line: int  # 1-based, inclusive
    filepath: Path  # Specific file


# Operation classes
class Operation:
    """Base class for pipeline operations."""

    pass


@dataclass
class ContextOp(Operation):
    """Expand N lines up and down."""

    n: int
    type: str = "context"


@dataclass
class UpOp(Operation):
    """Expand N lines upward."""

    n: int
    type: str = "up"


@dataclass
class DownOp(Operation):
    """Expand N lines downward."""

    n: int
    type: str = "down"


@dataclass
class UntilOp(Operation):
    """Expand down until pattern matches."""

    pattern: str
    type: str = "until"


@dataclass
class UpUntilOp(Operation):
    """Expand up until pattern matches."""

    pattern: str
    type: str = "up-until"


@dataclass
class UntilBlankOp(Operation):
    """Expand down until blank line."""

    type: str = "until-blank"


@dataclass
class WhileIndentOp(Operation):
    """Expand while indented."""

    type: str = "while-indent"


@dataclass
class FilterOp(Operation):
    """Keep only windows containing pattern."""

    pattern: str
    type: str = "filter"


@dataclass
class ExcludeOp(Operation):
    """Remove windows containing pattern."""

    pattern: str
    type: str = "exclude"


@dataclass
class LimitOp(Operation):
    """Keep only first N windows."""

    n: int
    type: str = "limit"


@dataclass
class QueryAST:
    """Parsed query AST."""

    is_view: bool  # True for view, False for peek
    label: Optional[str]  # Only for view commands
    matcher: Matcher
    operations: list[Operation]


class ParseError(Exception):
    """Raised when query parsing fails."""

    pass


class QueryParser:
    """Parser for view and peek query commands."""

    # Command patterns
    VIEW_PATTERN = re.compile(r"^view\s+(\w+)\s+(.+)$")
    PEEK_PATTERN = re.compile(r"^peek\s+(.+)$")

    # Matcher patterns
    PATTERN_MATCHER = re.compile(r"^/(.+?)/\s+in\s+(.+?)(?:\s+\||$)")
    LINE_MATCHER = re.compile(r"^line\s+(\d+)(?:-(\d+))?\s+in\s+(.+?)(?:\s+\||$)")

    # Operation patterns
    CONTEXT_OP = re.compile(r"^\s*context\s+(\d+)\s*$")
    UP_OP = re.compile(r"^\s*up\s+(\d+)\s*$")
    DOWN_OP = re.compile(r"^\s*down\s+(\d+)\s*$")
    UNTIL_OP = re.compile(r"^\s*(?:down-)?until\s+/(.+?)/\s*$")
    UP_UNTIL_OP = re.compile(r"^\s*up-until\s+/(.+?)/\s*$")
    UNTIL_BLANK_OP = re.compile(r"^\s*until-blank\s*$")
    WHILE_INDENT_OP = re.compile(r"^\s*while-indent\s*$")
    FILTER_OP = re.compile(r"^\s*filter\s+/(.+?)/\s*$")
    EXCLUDE_OP = re.compile(r"^\s*exclude\s+/(.+?)/\s*$")
    LIMIT_OP = re.compile(r"^\s*limit\s+(\d+)\s*$")

    def parse_view(self, cmd: str) -> QueryAST:
        """Parse view command.

        Args:
            cmd: View command string (e.g., "view secrets /sops/ in *.nix | context 5")

        Returns:
            QueryAST with is_view=True and label set

        Raises:
            ParseError: If command syntax is invalid

        Examples:
            >>> parser = QueryParser()
            >>> ast = parser.parse_view("view secrets /pattern/ in **/*.py")
            >>> ast.label
            'secrets'
            >>> ast.is_view
            True
        """
        # Extract command and label
        match = self.VIEW_PATTERN.match(cmd.strip())
        if not match:
            raise ParseError(
                "Invalid view syntax. Expected: view <label> <matcher> in <glob> | <operations>"
            )

        label = match.group(1)
        rest = match.group(2)

        # Parse matcher and operations
        matcher, operations = self._parse_matcher_and_operations(rest, allow_line=False)

        return QueryAST(
            is_view=True, label=label, matcher=matcher, operations=operations
        )

    def parse_peek(self, cmd: str) -> QueryAST:
        """Parse peek command.

        Args:
            cmd: Peek command string (e.g., "peek line 155 in file.c | context 10")

        Returns:
            QueryAST with is_view=False and label=None

        Raises:
            ParseError: If command syntax is invalid

        Examples:
            >>> parser = QueryParser()
            >>> ast = parser.parse_peek("peek /TODO/ in **/*.py | limit 10")
            >>> ast.is_view
            False
            >>> ast.label is None
            True
        """
        # Extract command
        match = self.PEEK_PATTERN.match(cmd.strip())
        if not match:
            raise ParseError(
                "Invalid peek syntax. Expected: peek <matcher> in <glob> | <operations>"
            )

        rest = match.group(1)

        # Parse matcher and operations (line matchers allowed in peek)
        matcher, operations = self._parse_matcher_and_operations(rest, allow_line=True)

        return QueryAST(
            is_view=False, label=None, matcher=matcher, operations=operations
        )

    def _parse_matcher_and_operations(
        self, text: str, allow_line: bool
    ) -> tuple[Matcher, list[Operation]]:
        """Parse matcher and pipeline operations.

        Args:
            text: Text after command (e.g., "/pattern/ in *.py | context 5")
            allow_line: Whether to allow line matchers

        Returns:
            Tuple of (matcher, operations list)

        Raises:
            ParseError: If syntax is invalid
        """
        # Try to match pattern matcher first (handles | inside /pattern/)
        match = self.PATTERN_MATCHER.match(text)
        if match:
            # Extract matched portion as matcher_text
            matcher_text = match.group(0)
            # Rest is operations (if any)
            operations_text = text[len(matcher_text) :].strip()
            # Remove leading pipe from operations
            if operations_text.startswith("|"):
                operations_text = operations_text[1:].strip()

            matcher = self._parse_matcher(matcher_text, allow_line)
            operations = (
                self._parse_operations(operations_text) if operations_text else []
            )
            return matcher, operations

        # Try line matcher if allowed
        if allow_line:
            match = self.LINE_MATCHER.match(text)
            if match:
                # Extract matched portion
                matcher_text = match.group(0)
                # Rest is operations
                operations_text = text[len(matcher_text) :].strip()
                # Remove leading pipe
                if operations_text.startswith("|"):
                    operations_text = operations_text[1:].strip()

                matcher = self._parse_matcher(matcher_text, allow_line)
                operations = (
                    self._parse_operations(operations_text) if operations_text else []
                )
                return matcher, operations

        # No matcher matched - try old split logic for better error message
        if "|" in text:
            matcher_text, operations_text = text.split("|", 1)
            matcher_text = matcher_text.strip()
        else:
            matcher_text = text.strip()

        # This will raise ParseError with appropriate message
        matcher = self._parse_matcher(matcher_text, allow_line)
        return matcher, []

    def _parse_matcher(self, text: str, allow_line: bool) -> Matcher:
        """Parse matcher (pattern or line).

        Args:
            text: Matcher text (e.g., "/pattern/ in *.py" or "line 155 in file.c")
            allow_line: Whether line matchers are allowed

        Returns:
            Matcher instance

        Raises:
            ParseError: If matcher syntax is invalid
        """
        # Try pattern matcher
        match = self.PATTERN_MATCHER.match(text)
        if match:
            pattern = match.group(1)
            glob = match.group(2).strip()
            return PatternMatcher(pattern=pattern, glob=glob)

        # Try line matcher (if allowed)
        if allow_line:
            match = self.LINE_MATCHER.match(text)
            if match:
                start_line = int(match.group(1))
                end_line_str = match.group(2)
                end_line = int(end_line_str) if end_line_str else start_line
                filepath_str = match.group(3).strip()
                return LineMatcher(
                    start_line=start_line,
                    end_line=end_line,
                    filepath=Path(filepath_str),
                )

        # No match
        if allow_line:
            raise ParseError(
                f"Invalid matcher: {text}\n"
                "Expected: /pattern/ in <glob> or line N in <file> or line N-M in <file>"
            )
        else:
            raise ParseError(
                f"Invalid matcher: {text}\n"
                "Expected: /pattern/ in <glob>\n"
                "(Line matchers only allowed in peek commands)"
            )

    def _parse_operations(self, text: str) -> list[Operation]:
        """Parse pipeline operations.

        Args:
            text: Operations text (e.g., "context 5 | limit 10")

        Returns:
            List of Operation instances

        Raises:
            ParseError: If operation syntax is invalid
        """
        operations = []

        # Smart split by | (avoiding splits inside /.../ patterns)
        parts = self._split_operations(text)

        for part in parts:
            part = part.strip()
            if not part:
                continue

            op = self._parse_single_operation(part)
            operations.append(op)

        return operations

    def _split_operations(self, text: str) -> list[str]:
        """Split operations by | while preserving | inside /.../ patterns.

        Args:
            text: Operations text

        Returns:
            List of operation strings

        Examples:
            >>> parser = QueryParser()
            >>> parser._split_operations("context 5 | limit 10")
            ['context 5', 'limit 10']
            >>> parser._split_operations("filter /a|b/ | limit 5")
            ['filter /a|b/', 'limit 5']
        """
        parts = []
        current = []
        in_pattern = False

        for char in text:
            if char == "/" and (not current or current[-1] != "\\"):
                # Toggle pattern state (unless escaped)
                in_pattern = not in_pattern
                current.append(char)
            elif char == "|" and not in_pattern:
                # Pipe outside pattern - split here
                parts.append("".join(current))
                current = []
            else:
                current.append(char)

        # Add last part
        if current:
            parts.append("".join(current))

        return parts

    def _parse_single_operation(self, text: str) -> Operation:
        """Parse a single operation.

        Args:
            text: Operation text (e.g., "context 5")

        Returns:
            Operation instance

        Raises:
            ParseError: If operation syntax is invalid
        """
        # Try each operation pattern
        match = self.CONTEXT_OP.match(text)
        if match:
            return ContextOp(n=int(match.group(1)))

        match = self.UP_OP.match(text)
        if match:
            return UpOp(n=int(match.group(1)))

        match = self.DOWN_OP.match(text)
        if match:
            return DownOp(n=int(match.group(1)))

        match = self.UNTIL_OP.match(text)
        if match:
            return UntilOp(pattern=match.group(1))

        match = self.UP_UNTIL_OP.match(text)
        if match:
            return UpUntilOp(pattern=match.group(1))

        match = self.UNTIL_BLANK_OP.match(text)
        if match:
            return UntilBlankOp()

        match = self.WHILE_INDENT_OP.match(text)
        if match:
            return WhileIndentOp()

        match = self.FILTER_OP.match(text)
        if match:
            return FilterOp(pattern=match.group(1))

        match = self.EXCLUDE_OP.match(text)
        if match:
            return ExcludeOp(pattern=match.group(1))

        match = self.LIMIT_OP.match(text)
        if match:
            return LimitOp(n=int(match.group(1)))

        # No match
        raise ParseError(
            f"Unknown operation: {text}\n"
            "Valid operations: context N, up N, down N, until /pattern/, up-until /pattern/, "
            "until-blank, while-indent, filter /pattern/, exclude /pattern/, limit N"
        )
