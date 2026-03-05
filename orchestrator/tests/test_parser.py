"""Tests for query parser."""

import pytest

from orchestrator.environments.editor.parser import (
    ContextOp,
    DownOp,
    ExcludeOp,
    FilterOp,
    LimitOp,
    LineMatcher,
    ParseError,
    PatternMatcher,
    QueryParser,
    UntilBlankOp,
    UntilOp,
    UpOp,
    UpUntilOp,
    WhileIndentOp,
)


@pytest.fixture
def parser():
    """Create a parser instance."""
    return QueryParser()


# ====================
# View command tests
# ====================


def test_view_basic(parser):
    """Test basic view command."""
    ast = parser.parse_view("view test /pattern/ in *.py")
    assert ast.is_view
    assert ast.label == "test"
    assert isinstance(ast.matcher, PatternMatcher)
    assert ast.matcher.pattern == "pattern"
    assert ast.matcher.glob == "*.py"
    assert len(ast.operations) == 0


def test_view_with_pipe_in_pattern(parser):
    """Test view with | operator in regex pattern."""
    ast = parser.parse_view("view dns /# DNS|dnsmasq|networking/ in *.nix")
    assert ast.label == "dns"
    assert ast.matcher.pattern == "# DNS|dnsmasq|networking"
    assert ast.matcher.glob == "*.nix"


def test_view_with_complex_pattern(parser):
    """Test view with complex regex patterns."""
    # Pattern with character class and pipe
    ast = parser.parse_view("view test /[a-z]+|[0-9]+/ in **/*.rs")
    assert ast.matcher.pattern == "[a-z]+|[0-9]+"
    assert ast.matcher.glob == "**/*.rs"


def test_view_with_operations(parser):
    """Test view with pipeline operations."""
    ast = parser.parse_view("view test /TODO/ in **/*.py | context 5 | limit 10")
    assert ast.label == "test"
    assert len(ast.operations) == 2
    assert isinstance(ast.operations[0], ContextOp)
    assert ast.operations[0].n == 5
    assert isinstance(ast.operations[1], LimitOp)
    assert ast.operations[1].n == 10


def test_view_with_pipe_in_pattern_and_operations(parser):
    """Test view with pipe in pattern AND pipeline operations."""
    ast = parser.parse_view(
        "view h1 /LoadCredential|DynamicUser/ in *.nix | context 3 | filter /true/"
    )
    assert ast.matcher.pattern == "LoadCredential|DynamicUser"
    assert len(ast.operations) == 2
    assert isinstance(ast.operations[0], ContextOp)
    assert isinstance(ast.operations[1], FilterOp)


def test_view_rejects_line_matcher(parser):
    """Test that view rejects line matcher."""
    with pytest.raises(ParseError) as exc:
        parser.parse_view("view test line 10 in file.py")
    assert "line" in str(exc.value).lower()


def test_view_invalid_syntax(parser):
    """Test view with invalid syntax."""
    with pytest.raises(ParseError):
        parser.parse_view("view")

    with pytest.raises(ParseError):
        parser.parse_view("view test")

    with pytest.raises(ParseError):
        parser.parse_view("view test pattern without slashes in *.py")


# ====================
# Peek command tests
# ====================


def test_peek_basic(parser):
    """Test basic peek command."""
    ast = parser.parse_peek("peek /pattern/ in *.py")
    assert not ast.is_view
    assert ast.label is None
    assert isinstance(ast.matcher, PatternMatcher)
    assert ast.matcher.pattern == "pattern"
    assert ast.matcher.glob == "*.py"


def test_peek_with_pipe_in_pattern(parser):
    """Test peek with | in regex pattern."""
    ast = parser.parse_peek("peek /TODO|FIXME|NOTE/ in **/*.rs | limit 5")
    assert ast.matcher.pattern == "TODO|FIXME|NOTE"
    assert len(ast.operations) == 1
    assert isinstance(ast.operations[0], LimitOp)


def test_peek_line_matcher_single(parser):
    """Test peek with single line matcher."""
    ast = parser.parse_peek("peek line 155 in file.c")
    assert isinstance(ast.matcher, LineMatcher)
    assert ast.matcher.start_line == 155
    assert ast.matcher.end_line == 155
    assert ast.matcher.filepath.name == "file.c"


def test_peek_line_matcher_range(parser):
    """Test peek with line range matcher."""
    ast = parser.parse_peek("peek line 10-20 in src/main.py")
    assert isinstance(ast.matcher, LineMatcher)
    assert ast.matcher.start_line == 10
    assert ast.matcher.end_line == 20
    assert str(ast.matcher.filepath) == "src/main.py"


def test_peek_line_with_operations(parser):
    """Test peek line with operations."""
    ast = parser.parse_peek("peek line 100 in file.c | context 10")
    assert isinstance(ast.matcher, LineMatcher)
    assert ast.matcher.start_line == 100
    assert len(ast.operations) == 1
    assert isinstance(ast.operations[0], ContextOp)


def test_peek_invalid_syntax(parser):
    """Test peek with invalid syntax."""
    with pytest.raises(ParseError):
        parser.parse_peek("peek")

    with pytest.raises(ParseError):
        parser.parse_peek("peek pattern without slashes")


# ====================
# Operation parsing tests
# ====================


def test_operation_context(parser):
    """Test context operation."""
    ast = parser.parse_view("view test /pattern/ in *.py | context 3")
    assert len(ast.operations) == 1
    assert isinstance(ast.operations[0], ContextOp)
    assert ast.operations[0].n == 3


def test_operation_up(parser):
    """Test up operation."""
    ast = parser.parse_view("view test /pattern/ in *.py | up 5")
    assert isinstance(ast.operations[0], UpOp)
    assert ast.operations[0].n == 5


def test_operation_down(parser):
    """Test down operation."""
    ast = parser.parse_view("view test /pattern/ in *.py | down 7")
    assert isinstance(ast.operations[0], DownOp)
    assert ast.operations[0].n == 7


def test_operation_until(parser):
    """Test until operation."""
    ast = parser.parse_view("view test /start/ in *.py | until /end/")
    assert isinstance(ast.operations[0], UntilOp)
    assert ast.operations[0].pattern == "end"


def test_operation_up_until(parser):
    """Test up-until operation."""
    ast = parser.parse_view("view test /current/ in *.py | up-until /^class/")
    assert isinstance(ast.operations[0], UpUntilOp)
    assert ast.operations[0].pattern == "^class"


def test_operation_until_blank(parser):
    """Test until-blank operation."""
    ast = parser.parse_view("view test /# Section/ in *.md | until-blank")
    assert isinstance(ast.operations[0], UntilBlankOp)


def test_operation_while_indent(parser):
    """Test while-indent operation."""
    ast = parser.parse_view("view test /def / in *.py | while-indent")
    assert isinstance(ast.operations[0], WhileIndentOp)


def test_operation_filter(parser):
    """Test filter operation."""
    ast = parser.parse_view("view test /def / in *.py | filter /async/")
    assert isinstance(ast.operations[0], FilterOp)
    assert ast.operations[0].pattern == "async"


def test_operation_exclude(parser):
    """Test exclude operation."""
    ast = parser.parse_view("view test /def / in *.py | exclude /test_/")
    assert isinstance(ast.operations[0], ExcludeOp)
    assert ast.operations[0].pattern == "test_"


def test_operation_limit(parser):
    """Test limit operation."""
    ast = parser.parse_view("view test /TODO/ in **/*.py | limit 20")
    assert isinstance(ast.operations[0], LimitOp)
    assert ast.operations[0].n == 20


# ====================
# Pipeline composition tests
# ====================


def test_pipeline_multiple_operations(parser):
    """Test pipeline with multiple operations."""
    ast = parser.parse_view(
        "view test /pattern/ in *.py | context 5 | filter /important/ | limit 10"
    )
    assert len(ast.operations) == 3
    assert isinstance(ast.operations[0], ContextOp)
    assert isinstance(ast.operations[1], FilterOp)
    assert isinstance(ast.operations[2], LimitOp)


def test_pipeline_complex(parser):
    """Test complex pipeline."""
    ast = parser.parse_view(
        "view test /^def / in **/*.py | while-indent | filter /async|await/ | limit 5"
    )
    assert ast.matcher.pattern == "^def "
    assert len(ast.operations) == 3
    assert isinstance(ast.operations[0], WhileIndentOp)
    assert isinstance(ast.operations[1], FilterOp)
    assert ast.operations[1].pattern == "async|await"
    assert isinstance(ast.operations[2], LimitOp)


def test_pipeline_all_expansion_ops(parser):
    """Test pipeline with various expansion operations."""
    ast = parser.parse_view(
        "view test /start/ in *.rs | context 2 | up 3 | down 4 | until /end/"
    )
    assert len(ast.operations) == 4
    assert isinstance(ast.operations[0], ContextOp)
    assert isinstance(ast.operations[1], UpOp)
    assert isinstance(ast.operations[2], DownOp)
    assert isinstance(ast.operations[3], UntilOp)


# ====================
# Edge cases and error handling
# ====================


def test_pattern_with_escaped_slash(parser):
    """Test pattern with escaped slash inside."""
    # Note: The parser doesn't handle escaping - the pattern is between first / and last /
    ast = parser.parse_view("view test /path\\/to\\/file/ in *.sh")
    # The pattern will include the backslashes as-is
    assert "path" in ast.matcher.pattern and "file" in ast.matcher.pattern


def test_glob_patterns(parser):
    """Test various glob patterns."""
    # Simple glob
    ast = parser.parse_view("view t1 /p/ in *.py")
    assert ast.matcher.glob == "*.py"

    # Recursive glob
    ast = parser.parse_view("view t2 /p/ in **/*.js")
    assert ast.matcher.glob == "**/*.js"

    # Multiple extensions
    ast = parser.parse_view("view t3 /p/ in **/*.{ts,tsx}")
    assert ast.matcher.glob == "**/*.{ts,tsx}"

    # Path with directories
    ast = parser.parse_view("view t4 /p/ in src/**/*.rs")
    assert ast.matcher.glob == "src/**/*.rs"


def test_whitespace_handling(parser):
    """Test parser handles whitespace correctly."""
    # Extra spaces
    ast = parser.parse_view("view  test  /pattern/  in  *.py  |  context  5  ")
    assert ast.label == "test"
    assert ast.matcher.pattern == "pattern"
    assert isinstance(ast.operations[0], ContextOp)
    assert ast.operations[0].n == 5


def test_pattern_with_special_chars(parser):
    """Test patterns with special regex characters."""
    # Regex with anchors and character classes
    ast = parser.parse_view("view test /^[A-Z][a-z]+$/ in *.txt")
    assert ast.matcher.pattern == "^[A-Z][a-z]+$"

    # Regex with quantifiers
    ast = parser.parse_view("view test /\\w+@\\w+\\.\\w+/ in *")
    assert "@" in ast.matcher.pattern and "\\w" in ast.matcher.pattern


def test_empty_operations(parser):
    """Test that empty operation strings are handled."""
    # Trailing pipe with nothing after
    ast = parser.parse_view("view test /pattern/ in *.py |")
    # Should parse successfully with no operations
    assert len(ast.operations) == 0


def test_operation_with_pattern_containing_pipe(parser):
    """Test until/filter with patterns containing |."""
    ast = parser.parse_view("view test /start/ in *.py | until /end|finish/")
    assert isinstance(ast.operations[0], UntilOp)
    assert ast.operations[0].pattern == "end|finish"

    ast = parser.parse_view("view test /TODO/ in *.py | filter /bug|fix|patch/")
    assert isinstance(ast.operations[0], FilterOp)
    assert ast.operations[0].pattern == "bug|fix|patch"


def test_real_world_scenarios(parser):
    """Test real-world command scenarios from task 26."""
    # Scenario 2: DNS configuration
    ast = parser.parse_view("view dns /# DNS|dnsmasq/ in *.nix | until-blank")
    assert ast.label == "dns"
    assert ast.matcher.pattern == "# DNS|dnsmasq"
    assert isinstance(ast.operations[0], UntilBlankOp)

    # Scenario 3: Hypothesis testing
    ast = parser.parse_view("view h1_binding /LoadCredential|credentials/ in *.nix")
    assert ast.matcher.pattern == "LoadCredential|credentials"

    # Scenario 4: Find all references
    ast = parser.parse_view(
        "view refs /sops\\.secrets\\.\\w+\\.path/ in **/*.nix | context 5"
    )
    assert "sops" in ast.matcher.pattern
    assert ast.matcher.glob == "**/*.nix"

    # Scenario 5: Reference while editing
    ast = parser.parse_peek("peek line 155 in file.c | context 10")
    assert isinstance(ast.matcher, LineMatcher)
    assert ast.matcher.start_line == 155
