"""Tests for window management module."""

from pathlib import Path
from tempfile import NamedTemporaryFile

from orchestrator.environments.editor.windows import View, Window, WindowManager


class TestWindowManager:
    """Tests for WindowManager."""

    def test_merge_no_windows(self):
        """Test merging with no windows."""
        mgr = WindowManager()
        views = mgr.merge_overlapping([])
        assert views == []

    def test_merge_single_window(self):
        """Test merging with single window."""
        mgr = WindowManager()
        w = Window(
            Path("a.py"), 1, 5, ["line1", "line2", "line3", "line4", "line5"], "q1"
        )
        views = mgr.merge_overlapping([w])

        assert len(views) == 1
        assert views[0].filepath == Path("a.py")
        assert views[0].start_line == 1
        assert views[0].end_line == 5
        assert views[0].labels == ["q1"]

    def test_merge_overlapping_windows(self):
        """Test merging overlapping windows."""
        mgr = WindowManager()
        w1 = Window(Path("a.py"), 1, 5, ["l1", "l2", "l3", "l4", "l5"], "q1")
        w2 = Window(Path("a.py"), 4, 8, ["l4", "l5", "l6", "l7", "l8"], "q2")

        with NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
            f.write("\n".join([f"line{i}" for i in range(1, 10)]))
            f.flush()
            filepath = Path(f.name)

        w1.filepath = filepath
        w2.filepath = filepath

        views = mgr.merge_overlapping([w1, w2])

        assert len(views) == 1
        assert views[0].start_line == 1
        assert views[0].end_line == 8
        assert set(views[0].labels) == {"q1", "q2"}

        filepath.unlink()

    def test_merge_adjacent_windows(self):
        """Test merging adjacent windows (within 1 line)."""
        mgr = WindowManager()

        with NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
            f.write("\n".join([f"line{i}" for i in range(1, 12)]))
            f.flush()
            filepath = Path(f.name)

        w1 = Window(filepath, 1, 5, ["l1", "l2", "l3", "l4", "l5"], "q1")
        w2 = Window(filepath, 6, 10, ["l6", "l7", "l8", "l9", "l10"], "q2")

        views = mgr.merge_overlapping([w1, w2])

        assert len(views) == 1
        assert views[0].start_line == 1
        assert views[0].end_line == 10

        filepath.unlink()

    def test_merge_windows_with_gap(self):
        """Test merging windows with gap (more than 1 line)."""
        mgr = WindowManager()

        with NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
            f.write("\n".join([f"line{i}" for i in range(1, 15)]))
            f.flush()
            filepath = Path(f.name)

        w1 = Window(filepath, 1, 5, ["l1", "l2", "l3", "l4", "l5"], "q1")
        w2 = Window(filepath, 8, 12, ["l8", "l9", "l10", "l11", "l12"], "q2")

        views = mgr.merge_overlapping([w1, w2])

        # Should have 2 separate views (gap of 2 lines)
        assert len(views) == 2
        assert views[0].start_line == 1
        assert views[0].end_line == 5
        assert views[1].start_line == 8
        assert views[1].end_line == 12

        filepath.unlink()

    def test_merge_multiple_files(self):
        """Test merging windows from multiple files."""
        mgr = WindowManager()

        with NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f1:
            f1.write("\n".join([f"line{i}" for i in range(1, 10)]))
            f1.flush()
            filepath1 = Path(f1.name)

        with NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f2:
            f2.write("\n".join([f"line{i}" for i in range(1, 10)]))
            f2.flush()
            filepath2 = Path(f2.name)

        w1 = Window(filepath1, 1, 3, ["l1", "l2", "l3"], "q1")
        w2 = Window(filepath2, 5, 7, ["l5", "l6", "l7"], "q2")
        w3 = Window(filepath1, 5, 7, ["l5", "l6", "l7"], "q3")

        views = mgr.merge_overlapping([w1, w2, w3])

        # Should have 3 views: 2 from file1, 1 from file2
        assert len(views) == 3

        filepath1.unlink()
        filepath2.unlink()

    def test_merge_preserves_all_labels(self):
        """Test that merging preserves all contributing labels."""
        mgr = WindowManager()

        with NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
            f.write("\n".join([f"line{i}" for i in range(1, 15)]))
            f.flush()
            filepath = Path(f.name)

        w1 = Window(filepath, 1, 5, ["l1", "l2", "l3", "l4", "l5"], "query1")
        w2 = Window(filepath, 4, 8, ["l4", "l5", "l6", "l7", "l8"], "query2")
        w3 = Window(filepath, 7, 10, ["l7", "l8", "l9", "l10"], "query3")

        views = mgr.merge_overlapping([w1, w2, w3])

        assert len(views) == 1
        assert set(views[0].labels) == {"query1", "query2", "query3"}

        filepath.unlink()

    def test_merge_unsorted_windows(self):
        """Test merging with unsorted windows (should handle automatically)."""
        mgr = WindowManager()

        with NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
            f.write("\n".join([f"line{i}" for i in range(1, 20)]))
            f.flush()
            filepath = Path(f.name)

        # Create windows out of order
        w1 = Window(filepath, 10, 12, ["l10", "l11", "l12"], "q1")
        w2 = Window(filepath, 1, 3, ["l1", "l2", "l3"], "q2")
        w3 = Window(filepath, 5, 7, ["l5", "l6", "l7"], "q3")

        views = mgr.merge_overlapping([w1, w2, w3])

        # Should handle and sort correctly
        assert len(views) == 3
        assert views[0].start_line == 1
        assert views[1].start_line == 5
        assert views[2].start_line == 10

        filepath.unlink()

    def test_format_for_screen_empty(self):
        """Test formatting with no views."""
        mgr = WindowManager()
        output = mgr.format_for_screen([], total_queries=0)

        assert "no matches" in output
        assert "0/3000" in output

    def test_format_for_screen_single_view(self):
        """Test formatting with single view."""
        mgr = WindowManager()

        with NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
            f.write("def foo():\n    return 42\n")
            f.flush()
            filepath = Path(f.name)

        view = View(filepath, 1, 2, ["def foo():", "    return 42"], ["test"])
        output = mgr.format_for_screen([view], total_queries=1)

        assert str(filepath) in output
        assert "lines 1-2" in output
        assert "[test]" in output
        assert "def foo():" in output
        assert "return 42" in output
        assert "1 queries, 2/3000 lines" in output

        filepath.unlink()

    def test_format_for_screen_multiple_views(self):
        """Test formatting with multiple views."""
        mgr = WindowManager()

        with NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
            f.write("\n".join([f"line{i}" for i in range(1, 20)]))
            f.flush()
            filepath = Path(f.name)

        v1 = View(filepath, 1, 3, [f"line{i}" for i in range(1, 4)], ["q1"])
        v2 = View(filepath, 10, 12, [f"line{i}" for i in range(10, 13)], ["q2"])

        output = mgr.format_for_screen([v1, v2], total_queries=2)

        assert "lines 1-3" in output
        assert "lines 10-12" in output
        assert "[q1]" in output
        assert "[q2]" in output
        assert "2 queries, 6/3000 lines" in output

        filepath.unlink()

    def test_format_for_screen_merged_labels(self):
        """Test formatting with merged view (multiple labels)."""
        mgr = WindowManager()

        with NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
            f.write("\n".join([f"line{i}" for i in range(1, 10)]))
            f.flush()
            filepath = Path(f.name)

        view = View(
            filepath, 1, 5, [f"line{i}" for i in range(1, 6)], ["q1", "q2", "q3"]
        )
        output = mgr.format_for_screen([view], total_queries=3)

        assert "[q1, q2, q3]" in output

        filepath.unlink()

    def test_format_for_screen_line_truncation(self):
        """Test that very long lines are truncated."""
        mgr = WindowManager()

        with NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
            long_line = "x" * 500
            f.write(f"{long_line}\nshort\n")
            f.flush()
            filepath = Path(f.name)

        view = View(filepath, 1, 2, ["x" * 500, "short"], ["test"])
        output = mgr.format_for_screen([view], total_queries=1)

        # Line should be truncated (full line is under 500 chars)
        lines = output.split("\n")
        long_line_output = [line for line in lines if "xxxx" in line][0]
        # Total line length should be much less than original 500+ chars
        assert len(long_line_output) < 300  # Allow some buffer for line numbers

        filepath.unlink()

    def test_calculate_total_lines(self):
        """Test calculating total lines."""
        mgr = WindowManager()

        v1 = View(Path("a.py"), 1, 5, ["l1", "l2", "l3", "l4", "l5"], ["q1"])
        v2 = View(
            Path("b.py"), 10, 15, ["l10", "l11", "l12", "l13", "l14", "l15"], ["q2"]
        )

        total = mgr.calculate_total_lines([v1, v2])
        assert total == 11  # 5 + 6

    def test_window_line_count(self):
        """Test Window.line_count property."""
        w = Window(
            Path("a.py"), 10, 15, ["l10", "l11", "l12", "l13", "l14", "l15"], "q1"
        )
        assert w.line_count == 6

    def test_view_line_count(self):
        """Test View.line_count property."""
        v = View(Path("a.py"), 1, 5, ["l1", "l2", "l3", "l4", "l5"], ["q1"])
        assert v.line_count == 5

    def test_read_lines_nonexistent_file(self):
        """Test reading lines from nonexistent file."""
        mgr = WindowManager()
        lines = mgr._read_lines(Path("/nonexistent/file.py"), 1, 5)

        assert len(lines) == 1
        assert "Error reading" in lines[0]

    def test_merge_same_label_multiple_times(self):
        """Test that same label appearing multiple times is deduplicated."""
        mgr = WindowManager()

        with NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
            f.write("\n".join([f"line{i}" for i in range(1, 15)]))
            f.flush()
            filepath = Path(f.name)

        w1 = Window(filepath, 1, 5, ["l1", "l2", "l3", "l4", "l5"], "same")
        w2 = Window(filepath, 4, 8, ["l4", "l5", "l6", "l7", "l8"], "same")

        views = mgr.merge_overlapping([w1, w2])

        assert len(views) == 1
        # Label should appear only once
        assert views[0].labels == ["same"]

        filepath.unlink()
