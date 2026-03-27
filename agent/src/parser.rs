//! Command parser for extracting commands from LLM responses.
//!
//! This module parses XML-style environment tags from LLM responses to extract
//! environment-specific commands. Commands must be inside a `# Commands` markdown
//! section; tags anywhere else in the response are ignored.

use crate::types::Command;

/// Returns the length of a fence opener if `line` begins with 3–5 backticks.
fn fence_open_len(line: &str) -> Option<usize> {
    let count = line.chars().take_while(|&c| c == '`').count();
    if (3..=5).contains(&count) {
        Some(count)
    } else {
        None
    }
}

/// If `line` is a bare XML opening tag (`<word>` with nothing else), return the tag name.
fn xml_open_tag_name(line: &str) -> Option<String> {
    let s = line.trim_end();
    if s.len() > 2 && s.starts_with('<') && s.ends_with('>') && !s.starts_with("</") {
        let name = &s[1..s.len() - 1];
        if !name.is_empty() && name.chars().all(|c| c.is_alphanumeric() || c == '_') {
            return Some(name.to_string());
        }
    }
    None
}

/// Returns true iff `line` (trailing whitespace stripped) is exactly `</name>`.
fn is_xml_close_tag_for(line: &str, name: &str) -> bool {
    line.trim_end() == format!("</{}>", name)
}

/// Parse commands from LLM response
///
/// Only scans `# Commands` markdown sections for environment tags. XML-like
/// text in other parts of the response (reasoning, prose, code examples) is
/// ignored, preventing false positives.
///
/// Each tag inside a commands section should have the format:
///
/// ```text
/// # Commands
///
/// <env>
/// command text
/// </env>
/// ```
///
/// Where `env` is the environment name (bash, python, editor) and
/// `command text` is the command to execute.
///
/// If there is no `# Commands` section the response is interpreted as a
/// task-complete signal and an empty list is returned.
///
/// Multiple `# Commands` sections are allowed and their contents are
/// collected in order.
///
/// # Example
///
/// ```
/// use agent::parser::parse_commands;
///
/// let response = "I'll list the files.\n\n# Commands\n\n<bash>\nls -la\n</bash>\n";
///
/// let commands = parse_commands(response);
/// assert_eq!(commands.len(), 1);
/// assert_eq!(commands[0].env, "bash");
/// assert_eq!(commands[0].command, "ls -la");
/// ```
pub fn parse_commands(response: &str) -> Vec<Command> {
    enum State {
        TopLevel,
        InCodeBlock { fence_len: usize },
        InXmlTag { name: String, lines: Vec<String> },
    }

    let mut commands = Vec::new();
    let mut state = State::TopLevel;
    let mut in_commands_section = false;

    for line in response.lines() {
        state = match state {
            State::TopLevel => {
                let trimmed = line.trim_end();

                if trimmed == "# Commands" || trimmed.starts_with("# Commands ") {
                    in_commands_section = true;
                    State::TopLevel
                } else if trimmed.starts_with("# ") {
                    in_commands_section = false;
                    State::TopLevel
                } else if let Some(fl) = fence_open_len(trimmed) {
                    State::InCodeBlock { fence_len: fl }
                } else if in_commands_section {
                    if let Some(name) = xml_open_tag_name(trimmed) {
                        State::InXmlTag {
                            name,
                            lines: Vec::new(),
                        }
                    } else {
                        State::TopLevel
                    }
                } else {
                    State::TopLevel
                }
            }

            State::InCodeBlock { fence_len } => {
                let trimmed = line.trim_end();
                let backtick_count = trimmed.chars().take_while(|&c| c == '`').count();
                if backtick_count >= fence_len && backtick_count == trimmed.len() {
                    State::TopLevel
                } else {
                    State::InCodeBlock { fence_len }
                }
            }

            State::InXmlTag { name, mut lines } => {
                let trimmed = line.trim_end();
                if is_xml_close_tag_for(trimmed, &name) {
                    let command = lines.join("\n").trim().to_string();
                    commands.push(Command { env: name, command });
                    State::TopLevel
                } else {
                    lines.push(line.to_string());
                    State::InXmlTag { name, lines }
                }
            }
        };
    }

    commands
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_commands_extracts_single_command() {
        // Requirement: Parser must extract environment and command from single tag.

        let response = r#"
I'll list the files.

# Commands

<bash>
ls -la
</bash>
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[0].command, "ls -la");
    }

    #[test]
    fn test_parse_commands_extracts_multiple_commands_in_order() {
        // Requirement: Parser must extract all commands in order from multiple tags.

        let response = r#"
Let me check the files and then analyze them.

# Commands

<bash>
ls -la
</bash>

<python>
import sys
print(sys.version)
</python>

<editor>
view src/main.py 1-50
</editor>
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 3);

        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[0].command, "ls -la");

        assert_eq!(commands[1].env, "python");
        assert_eq!(commands[1].command, "import sys\nprint(sys.version)");

        assert_eq!(commands[2].env, "editor");
        assert_eq!(commands[2].command, "view src/main.py 1-50");
    }

    #[test]
    fn test_parse_commands_preserves_multiline_content() {
        // Requirement: Parser must preserve newlines and whitespace in command content.

        let response = r#"
# Commands

<python>
def hello():
    print("Hello, world!")

hello()
</python>
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].env, "python");
        assert_eq!(
            commands[0].command,
            "def hello():\n    print(\"Hello, world!\")\n\nhello()"
        );
    }

    #[test]
    fn test_parse_commands_returns_empty_for_no_tags() {
        // Requirement: Parser must return empty list when response contains no environment tags.

        let response = "The task is complete! I've successfully added authentication.";

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 0);
    }

    #[test]
    fn test_parse_commands_handles_empty_command_content() {
        // Requirement: Parser must handle tags with empty body (return empty string, not error).

        let response = r#"
# Commands

<bash>
</bash>
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[0].command, "");
    }

    #[test]
    fn test_parse_commands_ignores_markdown_code_blocks() {
        // Requirement: Parser must extract only environment tags, ignoring markdown code blocks.

        let response = r#"
I'll analyze the code first.

# Commands

<bash>
cat src/main.py
</bash>

<python>
x = 42
print(x)
</python>

Some regular markdown like ```inline code``` should be ignored.
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 2);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[1].env, "python");
    }

    #[test]
    fn test_parse_commands_preserves_special_characters() {
        // Requirement: Parser must preserve special characters (<, >, &) in command content.

        let response = r#"
# Commands

<bash>
echo "Use <brackets> and & symbols"
</bash>
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 1);
        assert_eq!(
            commands[0].command,
            r#"echo "Use <brackets> and & symbols""#
        );
    }

    #[test]
    fn test_parse_commands_preserves_exact_indentation() {
        // Requirement: Parser must preserve exact indentation for code blocks.

        let response = r#"
# Commands

<python>
def foo():
    if True:
        print("indented")
</python>
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 1);
        assert_eq!(
            commands[0].command,
            "def foo():\n    if True:\n        print(\"indented\")"
        );
    }

    #[test]
    fn test_parse_commands_extracts_various_environment_names() {
        // Requirement: Parser must handle any word-character environment name
        // (bash, python3, sh, editor, etc.).

        let response = r#"
# Commands

<bash>
ls
</bash>

<python3>
print()
</python3>

<sh>
pwd
</sh>

<editor>
view file
</editor>
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 4);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[1].env, "python3");
        assert_eq!(commands[2].env, "sh");
        assert_eq!(commands[3].env, "editor");
    }

    #[test]
    fn test_parse_commands_handles_less_than_in_content() {
        // Requirement: Parser must handle < character in command content
        // without breaking tag matching.

        let response = r#"
# Commands

<python>
if 3 < 4:
    print("Hello world")
</python>
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].env, "python");
        assert_eq!(commands[0].command, "if 3 < 4:\n    print(\"Hello world\")");
    }

    // --- New tests for section-based parsing ---

    #[test]
    fn test_parse_commands_ignores_tags_outside_commands_section() {
        // Requirement: XML tags in reasoning prose must not be parsed as commands.

        let response = r#"
# Reflection

I need to use the <matcher> pattern here. The <bash> tag would be
a problem if parsed outside the section.

# Commands

<bash>
echo "real command"
</bash>
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[0].command, r#"echo "real command""#);
    }

    #[test]
    fn test_parse_commands_collects_multiple_sections_in_order() {
        // Requirement: Multiple # Commands sections must all be collected, in document order.

        let response = r#"
# Reflection

I'll start by listing files.

# Commands

<bash>
ls
</bash>

# Consideration

Now I should check the Python version.

# Commands

<python>
import sys
print(sys.version)
</python>
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 2);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[0].command, "ls");
        assert_eq!(commands[1].env, "python");
        assert_eq!(commands[1].command, "import sys\nprint(sys.version)");
    }

    #[test]
    fn test_parse_commands_empty_commands_section_returns_empty() {
        // Requirement: A # Commands section with no XML tags yields no commands.

        let response = r#"
# Commands

No commands needed right now.
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 0);
    }

    #[test]
    fn test_parse_commands_no_commands_section_returns_empty() {
        // Requirement: A response with no # Commands section signals task complete (empty list).

        let response = r#"
# Reflection

The task is complete. Everything looks good.

# Consideration

No further action is needed.
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 0);
    }

    #[test]
    fn test_parse_commands_heading_inside_xml_tag_not_section_terminator() {
        // Requirement: An H1 heading that appears inside an XML env tag (e.g. inside
        // a bash heredoc) must not terminate the active # Commands section.

        let response =
            "# Commands\n\n<bash>\ncat > task.md << 'EOF'\n# Task: do something\nEOF\n</bash>\n";

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(
            commands[0].command,
            "cat > task.md << 'EOF'\n# Task: do something\nEOF"
        );
    }

    #[test]
    fn test_parse_commands_heading_inside_code_block_not_section_terminator() {
        // Requirement: An H1 heading inside a fenced code block must not terminate
        // the active # Commands section.

        let response = r#"
# Commands

<bash>
echo hello
</bash>

Some prose with a fenced block:

```
# This heading is inside a code fence
```

<editor>
view README.md /^#/
</editor>
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 2);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[0].command, "echo hello");
        assert_eq!(commands[1].env, "editor");
        assert_eq!(commands[1].command, "view README.md /^#/");
    }

    #[test]
    fn test_parse_commands_text_between_sections_not_scanned() {
        // Requirement: Text under non-Commands headings between two Commands sections
        // must not be scanned for tags.

        let response = r#"
# Commands

<bash>
ls
</bash>

# Reflection

The <bash> tag here is just prose, not a command.

# Commands

<editor>
view README.md /^#/
</editor>
"#;

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 2);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[0].command, "ls");
        assert_eq!(commands[1].env, "editor");
        assert_eq!(commands[1].command, "view README.md /^#/");
    }

    #[test]
    fn test_parse_commands_close_tag_in_content_not_terminator() {
        // Regression: A closing tag for a *different* environment inside a bash heredoc
        // must be treated as content, not as the terminator for the bash block.
        // Only </bash> should close a <bash> block.

        let response = "# Commands\n\n<bash>\ncat > example.md << 'EOF'\n</editor>\nEOF\n</bash>\n";

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(
            commands[0].command,
            "cat > example.md << 'EOF'\n</editor>\nEOF"
        );
    }

    #[test]
    fn test_parse_commands_xml_tags_inside_code_block_ignored() {
        // Regression: XML env tags that appear inside a fenced code block in a
        // # Commands section must not be parsed as commands.

        let response = "# Commands\n\n```\n<bash>\nls\n</bash>\n```\n";

        let commands = parse_commands(response);
        assert_eq!(commands.len(), 0);
    }
}
