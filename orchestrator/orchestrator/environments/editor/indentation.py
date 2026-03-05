"""Indentation analysis for while-indent operation.

This module provides language-agnostic indentation analysis used by the
while-indent pipeline operation to expand code blocks based on indentation level.
"""

import re


class IndentationAnalyzer:
    """Analyzes indentation levels and expands code blocks.

    The while-indent operation expands a window while lines are indented
    deeper than the reference line (first line of window). This works for
    Python, C, JavaScript, Rust, and other languages.

    Key behaviors:
    - Reference indentation: First line of window
    - Include lines: While indent > reference
    - Empty/whitespace-only lines: Treated as indented (don't stop expansion)
    - Smart closing: Auto-include single closing brace/bracket after stopping
    """

    # Pattern for single closing character (}, ], ), >)
    CLOSING_PATTERN = re.compile(r"^\s*[\])}>]\s*$")

    def expand_while_indented(
        self,
        all_lines: list[str],
        start_line: int,
        current_end: int,
        max_lines: int = 200,
    ) -> int:
        """Expand window while indentation > reference.

        Args:
            all_lines: All lines from file (0-indexed)
            start_line: Start line number (1-based)
            current_end: Current end line number (1-based)
            max_lines: Maximum lines to expand (default 200)

        Returns:
            New end line number (1-based)

        Examples:
            Python function:
            >>> lines = [
            ...     "def func():",        # line 1, indent=0
            ...     "    x = 1",          # line 2, indent=4
            ...     "    return x",       # line 3, indent=4
            ...     "",                   # line 4, empty
            ...     "def other():",       # line 5, indent=0
            ... ]
            >>> analyzer = IndentationAnalyzer()
            >>> analyzer.expand_while_indented(lines, 1, 1, 200)
            4

            C function with closing brace:
            >>> lines = [
            ...     "void foo() {",       # line 1, indent=0
            ...     "    int x;",         # line 2, indent=4
            ...     "    return x;",      # line 3, indent=4
            ...     "}",                  # line 4, indent=0 (auto-included)
            ...     "",                   # line 5
            ... ]
            >>> analyzer.expand_while_indented(lines, 1, 1, 200)
            4
        """
        if not all_lines or start_line < 1 or start_line > len(all_lines):
            return current_end

        # Get reference indentation from first line
        first_line = all_lines[start_line - 1]
        ref_indent = self._get_indent_level(first_line)

        new_end = current_end
        max_line_num = min(len(all_lines), start_line + max_lines - 1)

        # Expand downward while indented
        for line_num in range(current_end + 1, max_line_num + 1):
            line = all_lines[line_num - 1]

            # Empty or whitespace-only lines are treated as indented
            if line.strip() == "":
                new_end = line_num
                continue

            # Check indent level
            indent = self._get_indent_level(line)
            if indent > ref_indent:
                new_end = line_num
            else:
                # Indentation decreased - check for smart closing
                if self.CLOSING_PATTERN.match(line):
                    # Auto-include single closing brace/bracket
                    new_end = line_num
                # Stop expansion
                break

        return new_end

    def _get_indent_level(self, line: str) -> int:
        """Count leading whitespace characters.

        Tabs are treated as 4 spaces for consistency.

        Args:
            line: The line to analyze

        Returns:
            Number of spaces of indentation

        Examples:
            >>> analyzer = IndentationAnalyzer()
            >>> analyzer._get_indent_level("    hello")
            4
            >>> analyzer._get_indent_level("\thello")
            4
            >>> analyzer._get_indent_level("\t\thello")
            8
            >>> analyzer._get_indent_level("hello")
            0
        """
        indent = 0
        for char in line:
            if char == " ":
                indent += 1
            elif char == "\t":
                indent += 4  # Tabs = 4 spaces
            else:
                break
        return indent
