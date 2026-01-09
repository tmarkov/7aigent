//! Command parser for extracting commands from LLM responses.
//!
//! This module parses fenced code blocks from LLM responses to extract
//! environment-specific commands.

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

/// Get the regex pattern for matching fenced code blocks
///
/// Pattern matches: ```env\ncommand```
/// Captures: (env, command)
fn code_block_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        // Match fenced code blocks: ```env\ncommand```
        // Group 1: environment name (word characters)
        // Group 2: command content (any characters including newlines)
        Regex::new(r"```(\w+)\n([\s\S]*?)```").expect("Failed to compile regex")
    })
}

/// Parse commands from LLM response
///
/// Extracts all fenced code blocks from the response and converts them
/// to Command objects. Each code block should have the format:
///
/// ```env
/// command text
/// ```
///
/// Where `env` is the environment name (bash, python, editor) and
/// `command text` is the command to execute.
///
/// # Example
///
/// ```
/// use agent::parser::parse_commands;
///
/// let response = "I'll list the files:\n\n```bash\nls -la\n```\n";
///
/// let commands = parse_commands(response).unwrap();
/// assert_eq!(commands.len(), 1);
/// assert_eq!(commands[0].env, "bash");
/// assert_eq!(commands[0].command, "ls -la");
/// ```
pub fn parse_commands(response: &str) -> Result<Vec<Command>> {
    let mut commands = Vec::new();
    let re = code_block_regex();

    for cap in re.captures_iter(response) {
        let env = cap[1].to_string();
        // Trim trailing newline if present (the closing ``` is on a new line)
        let command = cap[2].trim_end_matches('\n').to_string();

        commands.push(Command { env, command });
    }

    Ok(commands)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_single_command() {
        let response = r#"
I'll list the files:

```bash
ls -la
```
"#;

        let commands = parse_commands(response).unwrap();
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[0].command, "ls -la");
    }

    #[test]
    fn test_parse_multiple_commands() {
        let response = r#"
Let me check the files and then analyze them:

```bash
ls -la
```

Now let's check Python version:

```python
import sys
print(sys.version)
```

And view a file:

```editor
view src/main.py 1-50
```
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
    fn test_parse_multiline_command() {
        let response = r#"
```python
def hello():
    print("Hello, world!")

hello()
```
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
    fn test_parse_no_commands() {
        let response = "The task is complete! I've successfully added authentication.";

        let commands = parse_commands(response).unwrap();
        assert_eq!(commands.len(), 0);
    }

    #[test]
    fn test_parse_command_with_empty_body() {
        let response = r#"
```bash
```
"#;

        let commands = parse_commands(response).unwrap();
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[0].command, "");
    }

    #[test]
    fn test_parse_mixed_content() {
        let response = r#"
I'll analyze the code first:

```bash
cat src/main.py
```

Some regular code formatting like `inline code` should be ignored.

```python
x = 42
print(x)
```

Done!
"#;

        let commands = parse_commands(response).unwrap();
        assert_eq!(commands.len(), 2);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[1].env, "python");
    }

    #[test]
    fn test_parse_command_with_backticks_in_content() {
        let response = r#"
```bash
echo "Use \`backticks\` for inline code"
```
"#;

        let commands = parse_commands(response).unwrap();
        assert_eq!(commands.len(), 1);
        assert_eq!(
            commands[0].command,
            r#"echo "Use \`backticks\` for inline code""#
        );
    }

    #[test]
    fn test_parse_command_preserves_whitespace() {
        let response = r#"
```python
def foo():
    if True:
        print("indented")
```
"#;

        let commands = parse_commands(response).unwrap();
        assert_eq!(commands.len(), 1);
        assert_eq!(
            commands[0].command,
            "def foo():\n    if True:\n        print(\"indented\")"
        );
    }

    #[test]
    fn test_parse_various_env_names() {
        let response = r#"
```bash
ls
```

```python3
print()
```

```sh
pwd
```

```editor
view file
```
"#;

        let commands = parse_commands(response).unwrap();
        assert_eq!(commands.len(), 4);
        assert_eq!(commands[0].env, "bash");
        assert_eq!(commands[1].env, "python3");
        assert_eq!(commands[2].env, "sh");
        assert_eq!(commands[3].env, "editor");
    }
}
