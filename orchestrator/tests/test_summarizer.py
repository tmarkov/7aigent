"""Tests for AI summarizer module."""

from pathlib import Path
from unittest.mock import patch

from orchestrator.environments.editor.summarizer import Summarizer
from orchestrator.environments.editor.windows import Window


class TestSummarizer:
    """Tests for Summarizer."""

    def test_generate_summary_empty_windows(self):
        """Test generating summary with no windows."""
        summarizer = Summarizer()
        summary, metadata = summarizer.generate_summary([], [])

        assert "No code viewed" in summary
        assert metadata == {}

    @patch("orchestrator.environments.editor.summarizer.request_auxiliary_llm_query")
    def test_generate_summary_with_windows(self, mock_llm):
        """Test generating summary with windows."""
        mock_llm.return_value = "This code defines a function."

        summarizer = Summarizer()
        w = Window(Path("test.py"), 1, 3, ["def foo():", "    return 42", ""], "q1")
        summary, metadata = summarizer.generate_summary([w], ["foo"])

        assert summary == "This code defines a function."
        assert metadata["window_count"] == 1
        mock_llm.assert_called_once()

    @patch("orchestrator.environments.editor.summarizer.request_auxiliary_llm_query")
    def test_generate_summary_llm_error(self, mock_llm):
        """Test summary generation when LLM fails."""
        mock_llm.side_effect = RuntimeError("LLM error")

        summarizer = Summarizer()
        w = Window(Path("test.py"), 1, 2, ["line1", "line2"], "q1")
        summary, metadata = summarizer.generate_summary([w], [])

        assert "Summary generation failed" in summary
        assert "error" in metadata

    def test_infer_focus_empty(self):
        """Test focus inference with no patterns."""
        summarizer = Summarizer()
        focus = summarizer._infer_focus([])

        assert focus == ""

    def test_infer_focus_single_pattern(self):
        """Test focus inference with single pattern."""
        summarizer = Summarizer()
        focus = summarizer._infer_focus(["sops"])

        assert focus == "Focus on: sops"

    def test_infer_focus_multiple_patterns(self):
        """Test focus inference with multiple patterns."""
        summarizer = Summarizer()
        focus = summarizer._infer_focus(["sops", "secrets", "config"])

        assert focus == "Focus on: sops, secrets, config"

    def test_infer_focus_deduplicates(self):
        """Test focus inference deduplicates patterns."""
        summarizer = Summarizer()
        focus = summarizer._infer_focus(["pattern1", "pattern1", "pattern2"])

        assert focus == "Focus on: pattern1, pattern2"

    def test_infer_focus_limits_to_three(self):
        """Test focus inference limits to 3 patterns."""
        summarizer = Summarizer()
        focus = summarizer._infer_focus(["p1", "p2", "p3", "p4", "p5"])

        # Should only include first 3 unique patterns
        assert focus == "Focus on: p1, p2, p3"

    def test_format_windows_single(self):
        """Test formatting single window."""
        summarizer = Summarizer()
        w = Window(Path("test.py"), 1, 3, ["line1", "line2", "line3"], "q1")
        formatted = summarizer._format_windows([w])

        assert "File: test.py" in formatted
        assert "Lines 1-3:" in formatted
        assert "  line1" in formatted
        assert "  line2" in formatted
        assert "  line3" in formatted

    def test_format_windows_multiple_files(self):
        """Test formatting windows from multiple files."""
        summarizer = Summarizer()
        w1 = Window(Path("a.py"), 1, 2, ["lineA1", "lineA2"], "q1")
        w2 = Window(Path("b.py"), 5, 6, ["lineB5", "lineB6"], "q2")
        formatted = summarizer._format_windows([w1, w2])

        assert "File: a.py" in formatted
        assert "File: b.py" in formatted
        assert "lineA1" in formatted
        assert "lineB5" in formatted

    def test_format_windows_multiple_from_same_file(self):
        """Test formatting multiple windows from same file."""
        summarizer = Summarizer()
        w1 = Window(Path("test.py"), 1, 2, ["line1", "line2"], "q1")
        w2 = Window(Path("test.py"), 10, 11, ["line10", "line11"], "q2")
        formatted = summarizer._format_windows([w1, w2])

        # Should group under same file
        file_count = formatted.count("File: test.py")
        assert file_count == 1
        assert "Lines 1-2:" in formatted
        assert "Lines 10-11:" in formatted

    def test_format_windows_sorted_by_line(self):
        """Test that windows are sorted by start line within file."""
        summarizer = Summarizer()
        w1 = Window(Path("test.py"), 10, 11, ["line10", "line11"], "q1")
        w2 = Window(Path("test.py"), 1, 2, ["line1", "line2"], "q2")
        formatted = summarizer._format_windows([w1, w2])

        # Lines 1-2 should appear before Lines 10-11
        pos_1_2 = formatted.index("Lines 1-2:")
        pos_10_11 = formatted.index("Lines 10-11:")
        assert pos_1_2 < pos_10_11
