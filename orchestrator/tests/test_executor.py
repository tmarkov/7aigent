"""Tests for query executor module."""

from pathlib import Path
from tempfile import TemporaryDirectory

from orchestrator.environments.editor.executor import QueryExecutor
from orchestrator.environments.editor.parser import QueryParser


class TestQueryExecutor:
    """Tests for QueryExecutor."""

    def test_search_pattern_basic(self):
        """Test basic pattern search with ripgrep."""
        with TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            # Create test file
            testfile = tmppath / "test.py"
            testfile.write_text("# TODO: fix this\nprint('hello')\n# TODO: review\n")

            parser = QueryParser()
            ast = parser.parse_read_only_peek("read-only-peek /TODO/ in *.py")

            executor = QueryExecutor(tmppath)
            windows = executor.execute(ast, set())

            # Should find 2 matches
            assert len(windows) == 2
            assert all(w.filepath == testfile for w in windows)
            assert windows[0].start_line == 1
            assert windows[1].start_line == 3

    def test_search_line_single(self):
        """Test line-based search for single line."""
        with TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            testfile = tmppath / "test.c"
            testfile.write_text("line1\nline2\nline3\nline4\nline5\n")

            parser = QueryParser()
            ast = parser.parse_read_only_peek("read-only-peek line 3 in test.c")

            executor = QueryExecutor(tmppath)
            windows = executor.execute(ast, set())

            assert len(windows) == 1
            assert windows[0].start_line == 3
            assert windows[0].end_line == 3
            assert windows[0].lines == ["line3"]

    def test_expand_context(self):
        """Test context expansion operation."""
        with TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            testfile = tmppath / "test.py"
            testfile.write_text("\n".join([f"line{i}" for i in range(1, 11)]) + "\n")

            parser = QueryParser()
            ast = parser.parse_read_only_peek(
                "read-only-peek /line5/ in *.py | context 2"
            )

            executor = QueryExecutor(tmppath)
            windows = executor.execute(ast, set())

            assert len(windows) == 1
            assert windows[0].start_line == 3  # 5 - 2
            assert windows[0].end_line == 7  # 5 + 2

    def test_expand_while_indent(self):
        """Test while-indent expansion operation."""
        with TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            testfile = tmppath / "test.py"
            content = (
                "def func():\n    x = 1\n    y = 2\n    return x\n\ndef other():\n"
            )
            testfile.write_text(content)

            parser = QueryParser()
            ast = parser.parse_read_only_peek(
                "read-only-peek /def func/ in *.py | while-indent"
            )

            executor = QueryExecutor(tmppath)
            windows = executor.execute(ast, set())

            assert len(windows) == 1
            assert windows[0].start_line == 1
            # Should expand to include indented lines, stop at blank or unindented
            assert windows[0].end_line == 5  # Includes empty line 5

    def test_filter_operation(self):
        """Test filter operation."""
        with TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            testfile = tmppath / "test.py"
            content = "# TODO: urgent\nprint('hi')\n# TODO: later\n# FIXME\n"
            testfile.write_text(content)

            parser = QueryParser()
            ast = parser.parse_read_only_peek(
                "read-only-peek /TODO/ in *.py | context 1 | filter /urgent/"
            )

            executor = QueryExecutor(tmppath)
            windows = executor.execute(ast, set())

            # Should have 2 windows originally (both TODO lines)
            # After filter, only the one with "urgent" remains
            assert len(windows) == 1
            assert "urgent" in " ".join(windows[0].lines)

    def test_limit_operation(self):
        """Test limit operation."""
        with TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            testfile = tmppath / "test.py"
            content = "\n".join([f"# TODO {i}" for i in range(1, 21)]) + "\n"
            testfile.write_text(content)

            parser = QueryParser()
            ast = parser.parse_read_only_peek("read-only-peek /TODO/ in *.py | limit 5")

            executor = QueryExecutor(tmppath)
            windows = executor.execute(ast, set())

            # Should limit to 5 windows
            assert len(windows) == 5

    def test_pipeline_composition(self):
        """Test multiple operations in pipeline."""
        with TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            testfile = tmppath / "test.py"
            content = "\n".join([f"line{i}" for i in range(1, 21)]) + "\n"
            testfile.write_text(content)

            parser = QueryParser()
            ast = parser.parse_read_only_peek(
                "read-only-peek /line5/ in *.py | context 2 | down 3 | limit 1"
            )

            executor = QueryExecutor(tmppath)
            windows = executor.execute(ast, set())

            # context 2: lines 3-7
            # down 3: lines 3-10
            # limit 1: first window only
            assert len(windows) == 1
            assert windows[0].start_line == 3
            assert windows[0].end_line == 10

    def test_search_lines_glob_multiple_files(self):
        """Test line glob matches multiple files."""
        with TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            # Create multiple test files
            (tmppath / "test1.py").write_text("line1\nline2\nline3\n")
            (tmppath / "test2.py").write_text("a\nb\nc\nd\ne\n")
            (tmppath / "other.txt").write_text("should not match\n")

            parser = QueryParser()
            ast = parser.parse_read_only_peek("read-only-peek line 1-2 in *.py")

            executor = QueryExecutor(tmppath)
            windows = executor.execute(ast, set())

            # Should find 2 windows (one per .py file)
            assert len(windows) == 2
            assert all(w.filepath.suffix == ".py" for w in windows)
            assert all(w.start_line == 1 and w.end_line == 2 for w in windows)

    def test_search_lines_glob_out_of_bounds(self):
        """Test line glob handles files with insufficient lines."""
        with TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            # Create files with different lengths
            (tmppath / "short.py").write_text("line1\nline2\n")  # Only 2 lines
            (tmppath / "long.py").write_text(
                "\n".join([f"line{i}" for i in range(1, 101)]) + "\n"
            )  # 100 lines

            parser = QueryParser()
            ast = parser.parse_read_only_peek("read-only-peek line 50-60 in *.py")

            executor = QueryExecutor(tmppath)
            windows = executor.execute(ast, set())

            # Should only find window from long.py (short.py skipped)
            assert len(windows) == 1
            assert windows[0].filepath.name == "long.py"
            assert windows[0].start_line == 50
            assert windows[0].end_line == 60

    def test_search_lines_glob_no_matches(self):
        """Test line glob with no matching files."""
        with TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            (tmppath / "test.txt").write_text("content\n")

            parser = QueryParser()
            ast = parser.parse_read_only_peek(
                "read-only-peek line 1-10 in *.py"
            )  # No .py files

            executor = QueryExecutor(tmppath)
            windows = executor.execute(ast, set())

            assert len(windows) == 0

    def test_search_lines_glob_recursive(self):
        """Test line glob with recursive pattern."""
        with TemporaryDirectory() as tmpdir:
            tmppath = Path(tmpdir)

            # Create nested structure
            subdir = tmppath / "subdir"
            subdir.mkdir()
            (tmppath / "root.py").write_text("root\nline2\n")
            (subdir / "nested.py").write_text("nested\nline2\n")

            parser = QueryParser()
            ast = parser.parse_read_only_peek("read-only-peek line 1 in **/*.py")

            executor = QueryExecutor(tmppath)
            windows = executor.execute(ast, set())

            # Should find both files
            assert len(windows) == 2
            assert windows[0].lines == ["root"] or windows[0].lines == ["nested"]
            assert windows[1].lines == ["nested"] or windows[1].lines == ["root"]
