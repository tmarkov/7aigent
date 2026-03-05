"""Tests for indentation analysis module."""

from orchestrator.environments.editor.indentation import IndentationAnalyzer


class TestIndentationAnalyzer:
    """Tests for IndentationAnalyzer."""

    def test_get_indent_level_spaces(self):
        """Test indent level calculation with spaces."""
        analyzer = IndentationAnalyzer()
        assert analyzer._get_indent_level("    hello") == 4
        assert analyzer._get_indent_level("        hello") == 8
        assert analyzer._get_indent_level("  hello") == 2
        assert analyzer._get_indent_level("hello") == 0

    def test_get_indent_level_tabs(self):
        """Test indent level calculation with tabs (tabs = 4 spaces)."""
        analyzer = IndentationAnalyzer()
        assert analyzer._get_indent_level("\thello") == 4
        assert analyzer._get_indent_level("\t\thello") == 8
        assert analyzer._get_indent_level("\t\t\thello") == 12

    def test_get_indent_level_mixed(self):
        """Test indent level with mixed tabs and spaces."""
        analyzer = IndentationAnalyzer()
        assert analyzer._get_indent_level("\t  hello") == 6  # tab(4) + 2 spaces
        assert analyzer._get_indent_level("  \thello") == 6  # 2 spaces + tab(4)

    def test_expand_python_function(self):
        """Test expanding Python function with while-indent."""
        lines = [
            "def func():",  # line 1, indent=0
            "    for i in range(10):",  # line 2, indent=4
            "        print(i)",  # line 3, indent=8
            "    print('done')",  # line 4, indent=4
            "",  # line 5, empty
            "def outer():",  # line 6, indent=0
        ]
        analyzer = IndentationAnalyzer()

        # Starting at line 1, should expand to line 5 (includes empty line)
        result = analyzer.expand_while_indented(lines, 1, 1, 200)
        assert result == 5

    def test_expand_nested_python(self):
        """Test expanding nested Python function."""
        lines = [
            "def outer():",  # line 1
            "    def func():",  # line 2, indent=4
            "        for i in range(10):",  # line 3, indent=8
            "            print(i)",  # line 4, indent=12
            "        print('done')",  # line 5, indent=8
            "    func()",  # line 6, indent=4 (stops here - not > 4)
        ]
        analyzer = IndentationAnalyzer()

        # Starting at line 2 (inner function), should expand to line 5
        result = analyzer.expand_while_indented(lines, 2, 2, 200)
        assert result == 5

    def test_expand_c_function_with_closing_brace(self):
        """Test expanding C function - auto-includes closing brace."""
        lines = [
            "void process() {",  # line 1, indent=0
            "    int x;",  # line 2, indent=4
            "    return x;",  # line 3, indent=4
            "}",  # line 4, indent=0 (auto-included)
            "",  # line 5
        ]
        analyzer = IndentationAnalyzer()

        # Starting at line 1, should expand to line 4 (includes closing brace)
        result = analyzer.expand_while_indented(lines, 1, 1, 200)
        assert result == 4

    def test_expand_javascript_function(self):
        """Test expanding JavaScript function with braces."""
        lines = [
            "function test() {",  # line 1, indent=0
            "  const x = 42;",  # line 2, indent=2
            "  return x;",  # line 3, indent=2
            "}",  # line 4, indent=0 (auto-included)
        ]
        analyzer = IndentationAnalyzer()

        result = analyzer.expand_while_indented(lines, 1, 1, 200)
        assert result == 4

    def test_expand_with_empty_lines(self):
        """Test that empty lines don't stop expansion."""
        lines = [
            "def func():",  # line 1
            "    x = 1",  # line 2
            "",  # line 3 (empty - treated as indented)
            "    y = 2",  # line 4
            "",  # line 5 (empty - treated as indented)
            "def other():",  # line 6 (stops here)
        ]
        analyzer = IndentationAnalyzer()

        result = analyzer.expand_while_indented(lines, 1, 1, 200)
        assert result == 5  # Includes both empty lines

    def test_expand_respects_max_lines(self):
        """Test that expansion respects max_lines limit."""
        lines = ["def func():"] + ["    x = 1"] * 300  # Very long function
        analyzer = IndentationAnalyzer()

        # Limit to 50 lines
        result = analyzer.expand_while_indented(lines, 1, 1, 50)
        assert result == 50

    def test_expand_no_further_indented_lines(self):
        """Test expansion when no further indented lines exist."""
        lines = [
            "def func():",  # line 1
            "def other():",  # line 2 (same indent - stops immediately)
        ]
        analyzer = IndentationAnalyzer()

        result = analyzer.expand_while_indented(lines, 1, 1, 200)
        assert result == 1  # No expansion

    def test_expand_array_closing_bracket(self):
        """Test that closing bracket is auto-included."""
        lines = [
            "const arr = [",  # line 1
            "  1,",  # line 2
            "  2,",  # line 3
            "  3",  # line 4
            "]",  # line 5 (closing bracket - auto-included)
        ]
        analyzer = IndentationAnalyzer()

        result = analyzer.expand_while_indented(lines, 1, 1, 200)
        assert result == 5

    def test_expand_parenthesis_closing(self):
        """Test that closing parenthesis is auto-included."""
        lines = [
            "result = func(",  # line 1
            "    arg1,",  # line 2
            "    arg2",  # line 3
            ")",  # line 4 (closing paren - auto-included)
        ]
        analyzer = IndentationAnalyzer()

        result = analyzer.expand_while_indented(lines, 1, 1, 200)
        assert result == 4

    def test_closing_brace_with_semicolon_not_included(self):
        """Test that '}; ' is NOT auto-included (not just closing char)."""
        lines = [
            "struct S {",  # line 1
            "  int x;",  # line 2
            "};",  # line 3 (has semicolon - NOT auto-included)
        ]
        analyzer = IndentationAnalyzer()

        # Pattern is ^\s*[\])}>]\s*$ which matches ONLY closing char
        # "};" has ';' so doesn't match
        result = analyzer.expand_while_indented(lines, 1, 1, 200)
        # Should stop at line 2, NOT include line 3
        assert result == 2

    def test_expand_from_middle_of_block(self):
        """Test expanding from middle of existing block."""
        lines = [
            "def func():",  # line 1
            "    x = 1",  # line 2
            "    y = 2",  # line 3
            "    z = 3",  # line 4
            "def other():",  # line 5
        ]
        analyzer = IndentationAnalyzer()

        # Start at line 1, but current_end is already at line 2
        result = analyzer.expand_while_indented(lines, 1, 2, 200)
        assert result == 4  # Expands to include remaining indented lines

    def test_expand_single_line_file(self):
        """Test expansion with single line file."""
        lines = ["def func():"]
        analyzer = IndentationAnalyzer()

        result = analyzer.expand_while_indented(lines, 1, 1, 200)
        assert result == 1  # No expansion possible

    def test_expand_empty_file(self):
        """Test expansion with empty file."""
        lines = []
        analyzer = IndentationAnalyzer()

        result = analyzer.expand_while_indented(lines, 1, 1, 200)
        assert result == 1  # Return current_end unchanged

    def test_expand_invalid_start_line(self):
        """Test expansion with invalid start line."""
        lines = ["def func():", "    x = 1"]
        analyzer = IndentationAnalyzer()

        # Start line beyond file length
        result = analyzer.expand_while_indented(lines, 10, 10, 200)
        assert result == 10  # Return current_end unchanged

    def test_nix_attribute_set(self):
        """Test expanding Nix attribute set."""
        lines = [
            "services.container = {",  # line 1
            "  enable = true;",  # line 2
            "  config = {",  # line 3
            '    user = "root";',  # line 4
            "  };",  # line 5 (not auto-included - has semicolon)
            "};",  # line 6 (not auto-included - has semicolon)
        ]
        analyzer = IndentationAnalyzer()

        result = analyzer.expand_while_indented(lines, 1, 1, 200)
        # Should stop at line 5 (inner closing doesn't match pattern)
        assert result == 5
