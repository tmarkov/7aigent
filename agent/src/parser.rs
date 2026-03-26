//! Command parser for extracting commands from LLM responses.
//!
//! This module parses XML-style environment tags from LLM responses to extract
//! environment-specific commands. Commands must be inside a `# Commands` markdown
//! section; tags anywhere else in the response are ignored.

use crate::types::Command;
use regex::Regex;
use std::sync::OnceLock;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ParseError {
    #[error("Failed to compile regex pattern: {0}")]
    RegexError(String),
}

pub type Result<T> = std::result::Result<T, ParseError>;

/// Get the regex pattern for matching environment tags
///
/// Pattern matches: <env>command</env>
/// Captures: (env, command)
/// Note: Closing tag must be alone on its own line
fn environment_tag_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        // Match environment tags: <env>command</env>
        // Group 1: environment name (word characters)
        // Group 2: command content (any characters including newlines)
        // Note: We match the closing tag separately without backreference
        // since rust regex doesn't support backreferences
        Regex::new(r"<(\w+)>\n?([\s\S]*?)\n?</\w+>").expect("Failed to compile regex")
    })
}

/// Returns true if the line is a bare XML opening tag, e.g. `<bash>`.
fn is_xml_open_tag(s: &str) -> bool {
    s.len() > 2
        && s.starts_with('<')
        && s.ends_with('>')
        && !s.starts_with("</")
        && s[1..s.len() - 1]
            .chars()
            .all(|c| c.is_alphanumeric() || c == '_')
}

/// Returns true if the line is a bare XML closing tag, e.g. `</bash>`.
fn is_xml_close_tag(s: &str) -> bool {
    s.len() > 3
        && s.starts_with("</")
        && s.ends_with('>')
        && s[2..s.len() - 1]
            .chars()
            .all(|c| c.is_alphanumeric() || c == '_')
}

/// Extract text from all `# Commands` sections in the response.
///
/// A commands section starts at a line that is exactly `# Commands` (or
/// `# Commands` followed only by whitespace) and ends at the next `^# `
/// heading or the end of the string.
///
/// Section-boundary detection is suppressed inside fenced code blocks
/// (triple-backtick delimited) and inside XML environment tags, so that
/// Markdown headings appearing in heredoc content or code examples do not
/// prematurely terminate an active section.
fn extract_commands_sections(response: &str) -> String {
    let mut result = String::new();
    let mut in_commands_section = false;
    let mut in_code_block = false;
    let mut in_xml_tag = false;

    for line in response.lines() {
        let trimmed = line.trim_end();

        // Toggle fenced code block state.
        if trimmed.starts_with("```") {
            in_code_block = !in_code_block;
        }

        // Track XML environment tag boundaries (only meaningful outside code blocks).
        if !in_code_block {
            if is_xml_open_tag(trimmed) {
                in_xml_tag = true;
            } else if is_xml_close_tag(trimmed) {
                in_xml_tag = false;
            }
        }

        // Section headings are only recognised outside code blocks and XML tags.
        if !in_code_block && !in_xml_tag {
            if trimmed == "# Commands" || trimmed.starts_with("# Commands ") {
                in_commands_section = true;
                continue;
            }
            if trimmed.starts_with("# ") {
                in_commands_section = false;
                continue;
            }
        }

        if in_commands_section {
            result.push_str(line);
            result.push('\n');
        }
    }

    result
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
/// let commands = parse_commands(response).unwrap();
/// assert_eq!(commands.len(), 1);
/// assert_eq!(commands[0].env, "bash");
/// assert_eq!(commands[0].command, "ls -la");
/// ```
pub fn parse_commands(response: &str) -> Result<Vec<Command>> {
    let mut commands = Vec::new();
    let re = environment_tag_regex();

    let sections_text = extract_commands_sections(response);

    for cap in re.captures_iter(&sections_text) {
        let env = cap[1].to_string();
        // Trim leading/trailing newlines from the command content
        let command = cap[2].trim().to_string();

        commands.push(Command { env, command });
    }

    Ok(commands)
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
        assert_eq!(commands.len(), 0);
    }

    #[test]
    fn test_parse_commands_heading_inside_xml_tag_not_section_terminator() {
        // Requirement: An H1 heading that appears inside an XML env tag (e.g. inside
        // a bash heredoc) must not terminate the active # Commands section.

        let response =
            "# Commands\n\n<bash>\ncat > task.md << 'EOF'\n# Task: do something\nEOF\n</bash>\n";

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
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

        let commands = parse_commands(response).unwrap();
        assert_eq!(commands.len(), 2);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[0].command, "ls");
        assert_eq!(commands[1].env, "editor");
        assert_eq!(commands[1].command, "view README.md /^#/");
    }
}
