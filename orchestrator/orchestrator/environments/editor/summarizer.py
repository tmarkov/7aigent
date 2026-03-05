"""AI summary generation for editor environment.

This module generates AI summaries of code windows using the auxiliary LLM
query protocol. Summaries are generated per <editor> tag, covering all windows
opened within that tag.
"""

from orchestrator.auxiliary import request_auxiliary_llm_query
from orchestrator.environments.editor.windows import Window


class Summarizer:
    """Generates AI summaries for code windows."""

    def generate_summary(
        self, windows: list[Window], patterns: list[str]
    ) -> tuple[str, dict]:
        """Generate AI summary for windows.

        Args:
            windows: List of windows to summarize
            patterns: List of query patterns for focus inference

        Returns:
            Tuple of (summary text, metadata dict)

        Examples:
            >>> summarizer = Summarizer()
            >>> windows = []
            >>> summary, metadata = summarizer.generate_summary(windows, [])
            >>> "No code viewed" in summary
            True
        """
        if not windows:
            return ("No code viewed.", {})

        # Build prompt
        focus = self._infer_focus(patterns)
        context = self._format_windows(windows)

        prompt = f"""Summarize these code sections in 2-3 sentences.
{focus}

{context}

Format: Clear sentences explaining what this code does."""

        # Request auxiliary LLM via orchestrator.auxiliary
        try:
            response = request_auxiliary_llm_query(prompt)
        except Exception as e:
            return (f"Summary generation failed: {e}", {"error": str(e)})

        return (response, {"window_count": len(windows)})

    def _infer_focus(self, patterns: list[str]) -> str:
        """Infer focus from query patterns.

        Args:
            patterns: List of regex patterns from queries

        Returns:
            Focus string for prompt, or empty if no patterns

        Examples:
            >>> summarizer = Summarizer()
            >>> summarizer._infer_focus([])
            ''
            >>> summarizer._infer_focus(['sops', 'secrets'])
            'Focus on: sops, secrets'
            >>> summarizer._infer_focus(['pattern1', 'pattern1', 'pattern2'])
            'Focus on: pattern1, pattern2'
        """
        if not patterns:
            return ""

        # Get unique patterns (preserve order, take first 3)
        seen = set()
        unique = []
        for p in patterns:
            if p not in seen:
                seen.add(p)
                unique.append(p)
                if len(unique) >= 3:
                    break

        return f"Focus on: {', '.join(unique)}"

    def _format_windows(self, windows: list[Window]) -> str:
        """Format windows for LLM context.

        Args:
            windows: List of windows to format

        Returns:
            Formatted string with file paths and line contents

        Examples:
            >>> from pathlib import Path
            >>> summarizer = Summarizer()
            >>> w = Window(Path("test.py"), 1, 3, ["line1", "line2", "line3"], "q1")
            >>> output = summarizer._format_windows([w])
            >>> "File: test.py" in output
            True
            >>> "Lines 1-3:" in output
            True
            >>> "line1" in output
            True
        """
        lines = []

        # Group by filepath
        by_file = {}
        for w in windows:
            if w.filepath not in by_file:
                by_file[w.filepath] = []
            by_file[w.filepath].append(w)

        # Format each file's windows
        for filepath in sorted(by_file.keys(), key=str):
            file_windows = sorted(by_file[filepath], key=lambda w: w.start_line)
            lines.append(f"File: {filepath}")

            for w in file_windows:
                lines.append(f"Lines {w.start_line}-{w.end_line}:")
                for line in w.lines:
                    lines.append(f"  {line}")

            lines.append("")  # Blank line between files

        return "\n".join(lines)
