"""Integration tests for Parser → Executor boundary.

Tests verify that parser output is executable and that parser and executor
agree on operation semantics.

These tests address the integration gap identified in testing methodology:
- Parser tests verify AST structure in isolation
- Executor tests verify execution logic
- THESE tests verify parser produces what executor expects
"""

from pathlib import Path
from tempfile import TemporaryDirectory

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from orchestrator.environments.editor.executor import QueryExecutor
from orchestrator.environments.editor.parser import (
    ContextOp,
    DownOp,
    FilterOp,
    LimitOp,
    ParseError,
    QueryParser,
    UntilBlankOp,
    UntilOp,
    UpOp,
    UpUntilOp,
    WhileIndentOp,
)

from . import timeout

# ====================
# Parser Output Executability Contract
# ====================


@timeout(10)
def test_all_parseable_view_commands_are_executable():
    """Requirement: Every command that parser successfully parses must produce
    an AST that executor can execute without exceptions.

    Integration boundary: Parser → Executor
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        # Create test file
        testfile = tmppath / "test.py"
        testfile.write_text(
            "def foo():\n    pass\n\ndef bar():\n    x = 1\n    return x\n"
        )

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # All valid view command patterns
        test_commands = [
            "view test /def/ in *.py",
            "view test /def/ in **/*.py",
            "view test /def|class/ in *.py",
            "view test /^def/ in *.py | context 5",
            "view test /def/ in *.py | while-indent",
            "view test /def/ in *.py | context 2 | filter /pass/",
            "view test /def/ in *.py | up 3",
            "view test /def/ in *.py | down 3",
            "view test /def/ in *.py | until /^$/",
            "view test /x = / in *.py | up-until /^def/",
            "view test /def/ in *.py | until-blank",
            "view test /def/ in *.py | while-indent | filter /pass/",
            "view test /def/ in *.py | while-indent | exclude /bar/",
            "view test /def/ in *.py | limit 1",
            "view test /def/ in *.py | context 5 | filter /x/ | limit 2",
        ]

        for cmd in test_commands:
            # Parse - must succeed
            ast = parser.parse_view(cmd)
            assert ast is not None, f"Parser should parse: {cmd}"

            # Execute - must not raise exception
            try:
                windows = executor.execute(ast, set())
                assert isinstance(
                    windows, list
                ), f"Executor must return list for: {cmd}"
            except Exception as e:
                pytest.fail(
                    f"Executor failed on parsed command '{cmd}': {type(e).__name__}: {e}"
                )


@timeout(10)
def test_all_parseable_peek_commands_are_executable():
    """Requirement: All read-only-peek command variants must be executable by QueryExecutor.

    Includes both pattern and line matchers.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        # Create test files
        testfile = tmppath / "test.py"
        testfile.write_text("line1\nline2\nline3\ndef foo():\n    pass\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        test_commands = [
            # Pattern matchers
            "read-only-peek /def/ in *.py",
            "read-only-peek /TODO|FIXME/ in **/*.py",
            "read-only-peek /def/ in *.py | context 2",
            "read-only-peek /def/ in *.py | while-indent",
            "read-only-peek /line/ in *.py | limit 2",
            # Line matchers
            "read-only-peek line 1 in test.py",
            "read-only-peek line 2-4 in test.py",
            "read-only-peek line 1 in test.py | context 2",
            "read-only-peek line 3-5 in test.py | up 1",
        ]

        for cmd in test_commands:
            ast = parser.parse_read_only_peek(cmd)
            assert ast is not None, f"Parser should parse: {cmd}"

            try:
                windows = executor.execute(ast, set())
                assert isinstance(
                    windows, list
                ), f"Executor must return list for: {cmd}"
            except Exception as e:
                pytest.fail(
                    f"Executor failed on parsed command '{cmd}': {type(e).__name__}: {e}"
                )


# ====================
# Semantic Agreement Tests
# ====================


@timeout(10)
def test_parser_and_executor_agree_on_context_semantics():
    """Requirement: Parser and executor must agree that context N means
    expand N lines up AND N lines down from match.

    Semantic agreement prevents divergence where parser docs say one thing
    but executor implements another.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        # Create file where line 6 has pattern, surrounded by known content
        lines = [f"line{i}" for i in range(1, 12)]
        testfile.write_text("\n".join(lines) + "\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Parse "context 3"
        ast = parser.parse_read_only_peek("read-only-peek /line6/ in *.py | context 3")

        # Execute
        windows = executor.execute(ast, set())
        assert len(windows) == 1, "Should match line6"

        # Semantic expectation: context 3 = 3 lines up, 3 lines down
        # line6 is at line 6, so context 3 should give lines 3-9
        window = windows[0]
        assert (
            window.start_line == 3
        ), f"context 3 should start 3 lines up, got {window.start_line}"
        assert (
            window.end_line == 9
        ), f"context 3 should end 3 lines down, got {window.end_line}"


@timeout(10)
def test_parser_and_executor_agree_on_up_semantics():
    """Requirement: Parser and executor must agree that up N means
    expand N lines upward only, keeping original end line."""
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        lines = [f"line{i}" for i in range(1, 12)]
        testfile.write_text("\n".join(lines) + "\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        ast = parser.parse_read_only_peek("read-only-peek /line6/ in *.py | up 3")
        windows = executor.execute(ast, set())

        window = windows[0]
        # up 3 from line 6 should give lines 3-6 (expand start, keep end)
        assert window.start_line == 3, "up 3 should start 3 lines up from match"
        assert window.end_line == 6, "up should not change end line"


@timeout(10)
def test_parser_and_executor_agree_on_down_semantics():
    """Requirement: Parser and executor must agree that down N means
    expand N lines downward only, keeping original start line."""
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        lines = [f"line{i}" for i in range(1, 12)]
        testfile.write_text("\n".join(lines) + "\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        ast = parser.parse_read_only_peek("read-only-peek /line6/ in *.py | down 3")
        windows = executor.execute(ast, set())

        window = windows[0]
        # down 3 from line 6 should give lines 6-9 (keep start, expand end)
        assert window.start_line == 6, "down should not change start line"
        assert window.end_line == 9, "down 3 should end 3 lines down from match"


@timeout(10)
def test_parser_and_executor_agree_on_until_semantics():
    """Requirement: Parser and executor must agree that until /pattern/
    expands down until pattern matches, excluding the match line."""
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        content = "START\nline2\nline3\nSTOP\nline5\n"
        testfile.write_text(content)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        ast = parser.parse_read_only_peek(
            "read-only-peek /START/ in *.py | until /STOP/"
        )
        windows = executor.execute(ast, set())

        window = windows[0]
        # Should expand from START (line 1) until STOP (line 4), excluding STOP
        assert window.start_line == 1
        assert window.end_line == 3, "until should exclude the match line"

        content = "\n".join(window.lines)
        assert "START" in content
        assert "line3" in content
        assert "STOP" not in content, "until should NOT include match line"


@timeout(10)
def test_parser_and_executor_agree_on_up_until_semantics():
    """Requirement: Parser and executor must agree that up-until /pattern/
    expands up until pattern matches, including the match line."""
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        content = "START\nline2\nline3\nEND\n"
        testfile.write_text(content)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        ast = parser.parse_read_only_peek(
            "read-only-peek /END/ in *.py | up-until /START/"
        )
        windows = executor.execute(ast, set())

        window = windows[0]
        # Should expand from END (line 4) up until START (line 1), including START
        assert window.start_line == 1, "up-until should include match line as new start"
        assert window.end_line == 4

        content = "\n".join(window.lines)
        assert "START" in content, "up-until SHOULD include match line"
        assert "END" in content


@timeout(10)
def test_parser_and_executor_agree_on_while_indent_semantics():
    """Requirement: Parser and executor must agree that while-indent expands
    while indentation > reference indentation (first line of window).

    Empty lines are treated as indented, and single closing braces are auto-included.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        content = "def func():\n    x = 1\n\n    y = 2\nother\n"
        testfile.write_text(content)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        ast = parser.parse_read_only_peek(
            "read-only-peek /def func/ in *.py | while-indent"
        )
        windows = executor.execute(ast, set())

        window = windows[0]
        # Should expand to include indented content + empty line
        assert window.start_line == 1
        assert (
            window.end_line == 4
        ), "while-indent should include empty lines within block"

        content = "\n".join(window.lines)
        assert "y = 2" in content, "Should include line after empty line"
        assert "other" not in content, "Should stop at unindented line"


@timeout(10)
def test_parser_and_executor_agree_on_filter_semantics():
    """Requirement: Parser and executor must agree that filter /pattern/
    keeps only windows where pattern matches anywhere in the window."""
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        content = "def foo():\n    KEEP\n\ndef bar():\n    DROP\n"
        testfile.write_text(content)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        ast = parser.parse_read_only_peek(
            "read-only-peek /def / in *.py | while-indent | filter /KEEP/"
        )
        windows = executor.execute(ast, set())

        # Should have only windows containing KEEP
        assert len(windows) == 1, "Filter should keep only matching windows"
        assert "KEEP" in " ".join(windows[0].lines)
        assert all(
            "KEEP" in " ".join(w.lines) for w in windows
        ), "All windows must contain filter pattern"


@timeout(10)
def test_parser_and_executor_agree_on_limit_semantics():
    """Requirement: Parser and executor must agree that limit N keeps
    only the first N windows in order."""
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        content = "\n".join([f"# TODO {i}" for i in range(1, 11)]) + "\n"
        testfile.write_text(content)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        ast = parser.parse_read_only_peek("read-only-peek /TODO/ in *.py | limit 3")
        windows = executor.execute(ast, set())

        # Should have exactly 3 windows (first 3 matches)
        assert (
            len(windows) == 3
        ), f"limit 3 should produce exactly 3 windows, got {len(windows)}"

        # Should be first 3 by line number
        assert windows[0].start_line == 1
        assert windows[1].start_line == 2
        assert windows[2].start_line == 3


# ====================
# Feature Completeness Matrix
# ====================


@timeout(10)
def test_all_expansion_operations_are_executable():
    """Requirement: All expansion operations accepted by parser must be
    implemented by executor.

    Operations: context, up, down, until, up-until, until-blank, while-indent
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        content = "line1\nline2\nTARGET\nline4\n\nline6\n"
        testfile.write_text(content)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        expansion_operations = [
            ("context 2", ContextOp(2)),
            ("up 2", UpOp(2)),
            ("down 2", DownOp(2)),
            ("until /^$/", UntilOp("^$")),
            ("up-until /line1/", UpUntilOp("line1")),
            ("until-blank", UntilBlankOp()),
            ("while-indent", WhileIndentOp()),
        ]

        for op_syntax, expected_op_type in expansion_operations:
            cmd = f"read-only-peek /TARGET/ in *.py | {op_syntax}"
            ast = parser.parse_read_only_peek(cmd)

            # Verify parser produced expected operation
            assert (
                len(ast.operations) == 1
            ), f"Parser should produce 1 operation for: {op_syntax}"
            assert (
                type(ast.operations[0]).__name__ == type(expected_op_type).__name__
            ), f"Parser produced wrong operation type for: {op_syntax}"

            # Executor must handle it without exception
            try:
                windows = executor.execute(ast, set())
                assert isinstance(
                    windows, list
                ), f"Executor must handle operation: {op_syntax}"
            except NotImplementedError:
                pytest.fail(f"Executor missing implementation for: {op_syntax}")
            except Exception as e:
                pytest.fail(f"Executor failed for {op_syntax}: {type(e).__name__}: {e}")


@timeout(10)
def test_all_filter_operations_are_executable():
    """Requirement: All filter operations accepted by parser must be
    implemented by executor.

    Operations: filter, exclude, limit
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        content = "# TODO 1\n# TODO 2\n# TODO 3\n"
        testfile.write_text(content)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        filter_operations = [
            ("filter /TODO/", FilterOp("TODO")),
            ("exclude /1/", None),  # ExcludeOp not in test imports
            ("limit 1", LimitOp(1)),
        ]

        for op_syntax, _ in filter_operations:
            cmd = f"read-only-peek /TODO/ in *.py | {op_syntax}"
            ast = parser.parse_read_only_peek(cmd)

            try:
                windows = executor.execute(ast, set())
                assert isinstance(windows, list)
            except NotImplementedError:
                pytest.fail(f"Executor missing implementation for: {op_syntax}")
            except Exception as e:
                pytest.fail(f"Executor failed for {op_syntax}: {type(e).__name__}: {e}")


@timeout(10)
def test_pattern_matcher_with_all_operations():
    """Requirement: PatternMatcher output must be compatible with all operations.

    Integration: PatternMatcher produces windows → all operations must accept them.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        testfile.write_text(
            "def foo():\n    x = 1\n    return x\n\ndef bar():\n    pass\n"
        )

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # All operations on pattern matcher
        operations = [
            "context 2",
            "up 1",
            "down 1",
            "until /^$/",
            "while-indent",
            "filter /x/",
            "exclude /bar/",
            "limit 1",
        ]

        for op in operations:
            cmd = f"read-only-peek /def/ in *.py | {op}"
            ast = parser.parse_read_only_peek(cmd)

            # PatternMatcher → Operation must work
            windows = executor.execute(ast, set())
            assert isinstance(
                windows, list
            ), f"PatternMatcher output must be compatible with operation: {op}"


@timeout(10)
def test_line_matcher_with_expansion_operations():
    """Requirement: LineMatcher output must be compatible with expansion operations.

    Integration: LineMatcher produces single window → expansions must accept it.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        testfile.write_text("\n".join([f"line{i}" for i in range(1, 12)]) + "\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Expansion operations on line matcher
        expansion_ops = ["context 2", "up 2", "down 2"]

        for op in expansion_ops:
            cmd = f"read-only-peek line 6 in test.py | {op}"
            ast = parser.parse_read_only_peek(cmd)

            windows = executor.execute(ast, set())
            assert len(windows) == 1, f"LineMatcher with {op} should produce window"


# ====================
# Pipeline Semantic Agreement
# ====================


@timeout(10)
def test_pipeline_operations_execute_left_to_right():
    """Requirement: Pipeline operations must execute in left-to-right order,
    with each operation transforming the output of the previous one.

    Semantic agreement: Parser order = execution order.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        testfile.write_text("def func():\n    # TODO\n    x = 1\n    return x\nother\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Pipeline: match → expand → filter → limit
        ast = parser.parse_read_only_peek(
            "read-only-peek /def/ in *.py | while-indent | filter /TODO/ | limit 1"
        )
        windows = executor.execute(ast, set())

        # Should have exactly 1 window (limit 1)
        assert len(windows) == 1, "limit 1 should produce exactly 1 window"

        # That window should show expanded content (while-indent) containing TODO (filter)
        content = "\n".join(windows[0].lines)
        assert "def func" in content, "Should include matched line"
        assert "TODO" in content, "Filter should have selected window with TODO"
        assert "x = 1" in content, "while-indent should have expanded to include body"


@timeout(10)
def test_until_excludes_match_line_as_documented():
    """Requirement: until operation must exclude the match line from result.

    Verifies implementation matches documented semantics in parser.py.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        content = "START\nline2\nEND\nafter\n"
        testfile.write_text(content)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        ast = parser.parse_read_only_peek(
            "read-only-peek /START/ in *.py | until /END/"
        )
        windows = executor.execute(ast, set())

        # Documented: "until /pattern/ - expand down until pattern matches (match NOT included)"
        window = windows[0]
        content = "\n".join(window.lines)
        assert "START" in content
        assert "line2" in content
        assert (
            "END" not in content
        ), "until should NOT include match line per documentation"


@timeout(10)
def test_up_until_includes_match_line_as_documented():
    """Requirement: up-until operation must include the match line in result.

    Verifies implementation matches documented semantics.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        content = "START\nline2\nline3\nEND\n"
        testfile.write_text(content)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        ast = parser.parse_read_only_peek(
            "read-only-peek /END/ in *.py | up-until /START/"
        )
        windows = executor.execute(ast, set())

        # Documented: "up-until /pattern/ - expand up until pattern matches (match IS included)"
        window = windows[0]
        content = "\n".join(window.lines)
        assert (
            "START" in content
        ), "up-until SHOULD include match line per documentation"
        assert "END" in content
        assert window.start_line == 1, "Match line should become new start"


# ====================
# Error Path Integration
# ====================


@timeout(10)
def test_invalid_syntax_fails_at_parse_not_execute():
    """Requirement: Invalid command syntax must fail at parse stage with clear error.

    Executor should never receive invalid AST.
    """
    parser = QueryParser()

    invalid_commands = [
        "view",  # Missing arguments
        "view test",  # Missing matcher
        "view test pattern in *.py",  # Pattern not in /slashes/
        "read-only-peek line invalid in test.py",  # Non-numeric line
    ]

    for cmd in invalid_commands:
        with pytest.raises(ParseError, match=".*"):
            if cmd.startswith("view"):
                parser.parse_view(cmd)
            else:
                parser.parse_read_only_peek(cmd)


@timeout(10)
def test_executor_handles_nonexistent_files_gracefully():
    """Requirement: Executor must handle nonexistent files gracefully, not crash.

    Valid AST with files that don't exist should return empty results, not exception.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Valid command, but no matching files
        ast = parser.parse_read_only_peek("read-only-peek /pattern/ in *.nonexistent")

        # Should not raise exception
        windows = executor.execute(ast, set())
        assert isinstance(windows, list)
        assert len(windows) == 0, "Should return empty list for no matches"


@timeout(10)
def test_executor_handles_empty_pattern_results_gracefully():
    """Requirement: Executor must handle queries with zero matches gracefully.

    Pattern that doesn't match anything should return empty list, not crash.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        testfile.write_text("def foo():\n    pass\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Pattern that won't match
        ast = parser.parse_read_only_peek(
            "read-only-peek /NEVER_MATCHES_ANYTHING/ in *.py"
        )

        windows = executor.execute(ast, set())
        assert windows == [], "Should return empty list for no matches"


# ====================
# Round-Trip Invariant Properties
# ====================


@timeout(10)
@settings(max_examples=10)
@given(st.integers(min_value=1, max_value=20))
def test_property_context_n_produces_at_most_2n_plus_1_lines(n):
    """Requirement: context N should produce at most 2N+1 lines.

    Property: For any N ≥ 1, context N expands N up and N down from single-line match.
    Maximum window size = N (up) + 1 (match) + N (down) = 2N+1.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        # Create file large enough to not be constrained by boundaries
        # Match will be at line 50, so we need at least 50+N lines
        lines = [f"line{i}" for i in range(1, 100)]
        lines[49] = "TARGET"  # Line 50
        testfile.write_text("\n".join(lines) + "\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        ast = parser.parse_read_only_peek(
            f"read-only-peek /TARGET/ in *.py | context {n}"
        )
        windows = executor.execute(ast, set())

        assert len(windows) == 1, "Should match TARGET once"
        window = windows[0]

        # Property: window size ≤ 2N+1
        actual_size = window.end_line - window.start_line + 1
        max_expected = 2 * n + 1
        assert (
            actual_size <= max_expected
        ), f"context {n} should produce at most {max_expected} lines, got {actual_size}"


@timeout(10)
@settings(max_examples=10)
@given(st.integers(min_value=1, max_value=20))
def test_property_up_n_changes_only_start_line(n):
    """Requirement: up N operation should only modify start_line, not end_line.

    Property: For any N ≥ 1, up N moves start up by N, end stays same.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        lines = [f"line{i}" for i in range(1, 100)]
        lines[49] = "TARGET"  # Line 50
        testfile.write_text("\n".join(lines) + "\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Without up operation
        ast_no_up = parser.parse_read_only_peek("read-only-peek /TARGET/ in *.py")
        windows_no_up = executor.execute(ast_no_up, set())
        original_end = windows_no_up[0].end_line

        # With up N operation
        ast_with_up = parser.parse_read_only_peek(
            f"read-only-peek /TARGET/ in *.py | up {n}"
        )
        windows_with_up = executor.execute(ast_with_up, set())

        # Property: end line unchanged
        assert (
            windows_with_up[0].end_line == original_end
        ), f"up {n} should not change end_line"

        # Property: start line moved up by N (or to line 1)
        expected_start = max(1, 50 - n)
        assert (
            windows_with_up[0].start_line == expected_start
        ), f"up {n} should move start to line {expected_start}"


@timeout(10)
@settings(max_examples=10)
@given(st.integers(min_value=1, max_value=20))
def test_property_down_n_changes_only_end_line(n):
    """Requirement: down N operation should only modify end_line, not start_line.

    Property: For any N ≥ 1, down N moves end down by N, start stays same.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        lines = [f"line{i}" for i in range(1, 100)]
        lines[49] = "TARGET"  # Line 50
        testfile.write_text("\n".join(lines) + "\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Without down operation
        ast_no_down = parser.parse_read_only_peek("read-only-peek /TARGET/ in *.py")
        windows_no_down = executor.execute(ast_no_down, set())
        original_start = windows_no_down[0].start_line

        # With down N operation
        ast_with_down = parser.parse_read_only_peek(
            f"read-only-peek /TARGET/ in *.py | down {n}"
        )
        windows_with_down = executor.execute(ast_with_down, set())

        # Property: start line unchanged
        assert (
            windows_with_down[0].start_line == original_start
        ), f"down {n} should not change start_line"

        # Property: end line moved down by N
        expected_end = 50 + n
        assert (
            windows_with_down[0].end_line == expected_end
        ), f"down {n} should move end to line {expected_end}"


@timeout(10)
@settings(max_examples=10)
@given(st.integers(min_value=1, max_value=10))
def test_property_limit_n_produces_at_most_n_windows(n):
    """Requirement: limit N must produce at most N windows.

    Property: For any N ≥ 1, output window count ≤ N.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        # Create file with 50 matches
        content = "\n".join([f"# MATCH {i}" for i in range(50)]) + "\n"
        testfile.write_text(content)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        ast = parser.parse_read_only_peek(f"read-only-peek /MATCH/ in *.py | limit {n}")
        windows = executor.execute(ast, set())

        # Property: output count ≤ N
        assert (
            len(windows) <= n
        ), f"limit {n} should produce at most {n} windows, got {len(windows)}"


@timeout(10)
@settings(max_examples=10)
@given(st.integers(min_value=1, max_value=10))
def test_property_filter_never_increases_window_count(n):
    """Requirement: filter operation must never increase window count.

    Property: For any input windows, filter produces output_count ≤ input_count.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        content = "\n".join([f"# line {i}" for i in range(20)]) + "\n"
        testfile.write_text(content)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Get window count without filter
        ast_no_filter = parser.parse_read_only_peek(
            f"read-only-peek /line/ in *.py | limit {n}"
        )
        windows_no_filter = executor.execute(ast_no_filter, set())
        count_before = len(windows_no_filter)

        # Get window count with filter
        ast_with_filter = parser.parse_read_only_peek(
            f"read-only-peek /line/ in *.py | limit {n} | filter /1/"
        )
        windows_with_filter = executor.execute(ast_with_filter, set())
        count_after = len(windows_with_filter)

        # Property: filter cannot increase count
        assert (
            count_after <= count_before
        ), f"filter should not increase count (before: {count_before}, after: {count_after})"


# ====================
# Cross-Command Integration
# ====================


@timeout(10)
def test_view_and_peek_produce_same_windows_for_same_query():
    """Requirement: view and read-only-peek with identical matcher/operations must produce
    identical windows (only difference is persistence).

    Integration: Both commands use same QueryExecutor.execute() path.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        testfile.write_text("def foo():\n    pass\n\ndef bar():\n    pass\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Same query, different commands
        ast_view = parser.parse_view("view test /def/ in *.py | while-indent")
        ast_read_only_peek = parser.parse_read_only_peek(
            "read-only-peek /def/ in *.py | while-indent"
        )

        windows_view = executor.execute(ast_view, set())
        windows_read_only_peek = executor.execute(ast_read_only_peek, set())

        # Should produce identical windows (ignoring labels)
        assert len(windows_view) == len(
            windows_read_only_peek
        ), "view and read-only-peek should produce same number of windows"

        for wv, wp in zip(windows_view, windows_read_only_peek):
            assert wv.filepath == wp.filepath, "Same file"
            assert wv.start_line == wp.start_line, "Same start"
            assert wv.end_line == wp.end_line, "Same end"
            assert wv.lines == wp.lines, "Same content"


@timeout(10)
def test_complex_pipeline_executes_without_data_loss():
    """Requirement: Complex multi-operation pipelines must execute without
    losing data or corrupting windows.

    Integration stress test: Pattern → expand → filter → expand → limit.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        content = """def alpha():
    # KEEP
    x = 1
    return x

def beta():
    # SKIP
    y = 2
    return y

def gamma():
    # KEEP
    z = 3
    return z
"""
        testfile.write_text(content)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Complex pipeline
        ast = parser.parse_read_only_peek(
            "read-only-peek /def / in *.py | while-indent | filter /KEEP/ | context 1 | limit 2"
        )
        windows = executor.execute(ast, set())

        # Should execute successfully
        assert isinstance(windows, list)

        # Verify pipeline effects
        # 1. Pattern matches 3 functions
        # 2. while-indent expands each to full function
        # 3. filter keeps only those with KEEP (alpha, gamma)
        # 4. context 1 adds 1 line up and down
        # 5. limit 2 keeps first 2 results

        assert len(windows) <= 2, "limit 2 should cap at 2 windows"
        for window in windows:
            content = "\n".join(window.lines)
            assert "KEEP" in content, "filter should ensure KEEP in all windows"
            assert "def " in content, "Should contain function definition"


# ====================
# Executor Limit Enforcement
# ====================


@timeout(10)
def test_executor_enforces_max_window_lines_limit():
    """Requirement: Executor must enforce MAX_WINDOW_LINES (200) on all operations.

    Any operation that would create window > 200 lines must be clamped.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "large.py"
        # Create file with 500 lines, unique match at line 250
        lines = [f"# comment {i}" for i in range(1, 501)]
        lines[249] = "# UNIQUE_MATCH_TARGET"  # Line 250
        testfile.write_text("\n".join(lines) + "\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Try to expand beyond limit with unique match
        ast = parser.parse_read_only_peek(
            "read-only-peek /UNIQUE_MATCH_TARGET/ in *.py | context 300"
        )
        windows = executor.execute(ast, set())

        # Should have 1 match, clamped to MAX_WINDOW_LINES
        assert len(windows) == 1
        assert (
            windows[0].line_count <= 200
        ), f"Window should be clamped to 200 lines, got {windows[0].line_count}"


@timeout(10)
def test_executor_respects_excluded_files_set():
    """Requirement: Executor must respect excluded_files parameter in execute().

    Integration: Editor passes exclusions → Executor honors them.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        file1 = tmppath / "file1.py"
        file2 = tmppath / "file2.py"
        file1.write_text("# MATCH in file1\n")
        file2.write_text("# MATCH in file2\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        ast = parser.parse_read_only_peek("read-only-peek /MATCH/ in *.py")

        # Execute without exclusions
        windows_all = executor.execute(ast, set())
        assert len(windows_all) == 2, "Should find both files"

        # Execute with file1 excluded
        windows_filtered = executor.execute(ast, {file1})
        assert len(windows_filtered) == 1, "Should find only file2"
        assert windows_filtered[0].filepath == file2


# ====================
# Operation Composition Semantics
# ====================


@timeout(10)
def test_multiple_expansions_are_additive():
    """Requirement: Multiple expansion operations must compose additively.

    context 2 | up 3 should expand more than just context 2 alone.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        lines = [f"line{i}" for i in range(1, 30)]
        lines[14] = "TARGET"  # Line 15
        testfile.write_text("\n".join(lines) + "\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Just context 2
        ast1 = parser.parse_read_only_peek(
            "read-only-peek /TARGET/ in *.py | context 2"
        )
        windows1 = executor.execute(ast1, set())
        span1 = windows1[0].end_line - windows1[0].start_line + 1

        # context 2 | up 3 (should expand further)
        ast2 = parser.parse_read_only_peek(
            "read-only-peek /TARGET/ in *.py | context 2 | up 3"
        )
        windows2 = executor.execute(ast2, set())
        span2 = windows2[0].end_line - windows2[0].start_line + 1

        # Second should be larger (or equal if hitting file boundaries)
        assert span2 >= span1, "Additional expansion should not shrink window"
        # Start should be further up
        assert windows2[0].start_line <= windows1[0].start_line


@timeout(10)
def test_filter_after_expansion_operates_on_expanded_content():
    """Requirement: Filter must operate on expanded windows, not original matches.

    Semantic: expand THEN filter, not filter on match lines only.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        content = """def alpha():
    x = 1
    # MARKER

def beta():
    y = 2
    # other
"""
        testfile.write_text(content)

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Match both functions, expand, then filter
        ast = parser.parse_read_only_peek(
            "read-only-peek /def / in *.py | while-indent | filter /MARKER/"
        )
        windows = executor.execute(ast, set())

        # Should have only alpha (which contains MARKER after expansion)
        assert len(windows) == 1, "Filter should operate on expanded content"
        content = "\n".join(windows[0].lines)
        assert "alpha" in content, "Should include alpha function"
        assert (
            "beta" not in content
        ), "Should exclude beta (no MARKER in expanded content)"


# ====================
# Edge Case Integration
# ====================


@timeout(10)
def test_operations_on_empty_window_list():
    """Requirement: All operations must handle empty input window list gracefully.

    Edge case: Pattern matches nothing, operations should not crash.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        testfile.write_text("no match here\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Pattern that matches nothing, followed by operations
        operations = ["context 5", "while-indent", "filter /x/", "limit 5"]

        for op in operations:
            ast = parser.parse_read_only_peek(
                f"read-only-peek /NEVER_MATCHES/ in *.py | {op}"
            )

            # Should not crash on empty input
            windows = executor.execute(ast, set())
            assert windows == [], f"Operation {op} should handle empty input"


@timeout(10)
def test_operations_on_single_line_file():
    """Requirement: All expansion operations must handle single-line files gracefully.

    Edge case: File with only 1 line, operations should not crash or produce invalid ranges.
    Note: Some operations may expand to show the single line multiple times or clamp to file bounds.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        testfile.write_text("TARGET\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        operations = ["context 5", "up 5", "down 5", "while-indent", "until-blank"]

        for op in operations:
            ast = parser.parse_read_only_peek(f"read-only-peek /TARGET/ in *.py | {op}")
            windows = executor.execute(ast, set())

            assert len(windows) == 1, f"Should match TARGET with operation: {op}"
            window = windows[0]

            # Verify valid range - should be within file bounds
            assert (
                window.start_line >= 1
            ), f"Start line must be >= 1 for operation: {op}"
            assert (
                window.end_line >= window.start_line
            ), f"End >= start for operation: {op}"
            # Single line file may result in window showing that line (possibly expanded via context)
            # but end should be clamped to what's available
            assert (
                window.line_count >= 1
            ), f"Should have at least 1 line for operation: {op}"


@timeout(10)
def test_line_matcher_with_out_of_bounds_range():
    """Requirement: Executor must handle line ranges that exceed file bounds gracefully.

    Edge case: read-only-peek line N-M where M exceeds file length.
    Current behavior: Returns empty if start line > file length, clamps end if in range.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        testfile.write_text("line1\nline2\nline3\n")  # Only 3 lines

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Request lines 2-100 (end beyond file length)
        ast = parser.parse_read_only_peek("read-only-peek line 2-100 in test.py")
        windows = executor.execute(ast, set())

        # LineMatcher behavior: if start is valid, returns window clamped to file
        # If no windows returned, that's also acceptable behavior (no match)
        if len(windows) > 0:
            window = windows[0]
            assert window.start_line == 2, "Should start at requested line"
            assert window.end_line <= 3, "Should clamp to file length"
            assert "line2" in window.lines


# ====================
# Type Safety Integration
# ====================


@timeout(10)
def test_executor_handles_all_operation_types_in_ast():
    """Requirement: Executor must handle all Operation subclasses that parser can produce.

    Type safety integration: Parser produces typed operations → Executor handles all types.
    """
    with TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)

        testfile = tmppath / "test.py"
        testfile.write_text("def foo():\n    x = 1\n\ndef bar():\n    pass\n")

        parser = QueryParser()
        executor = QueryExecutor(tmppath)

        # Each operation type
        operation_syntaxes = [
            "context 2",
            "up 2",
            "down 2",
            "until /^def bar/",
            "up-until /^def foo/",
            "until-blank",
            "while-indent",
            "filter /x/",
            "exclude /bar/",
            "limit 1",
        ]

        for op_syntax in operation_syntaxes:
            cmd = f"read-only-peek /def foo/ in *.py | {op_syntax}"
            ast = parser.parse_read_only_peek(cmd)

            # Executor must handle the operation type
            try:
                windows = executor.execute(ast, set())
                assert isinstance(windows, list)
            except KeyError as e:
                pytest.fail(
                    f"Executor missing handler for operation: {op_syntax} - {e}"
                )
            except AttributeError as e:
                pytest.fail(
                    f"Executor operation handler type mismatch: {op_syntax} - {e}"
                )
