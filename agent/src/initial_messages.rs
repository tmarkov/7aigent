//! Initial messages parsing and loading.
//!
//! This module handles loading and parsing initial messages from markdown files.
//! Initial messages are pre-configured simulated assistant messages that can be
//! executed at agent startup to populate context without LLM costs.

use anyhow::{Context, Result};
use std::path::PathBuf;

/// Load initial messages from a markdown file.
///
/// The file should contain one or more simulated assistant messages, separated
/// by horizontal rules (---, ***, ___, or ~~~). Each message can contain
/// commands in <environment>command</environment> format.
///
/// # Format
///
/// ```markdown
/// Let's check the readme:
///
/// <editor>
/// view README.md
/// </editor>
/// ---
/// Now search for main function:
///
/// <editor>
/// search "fn main" *.rs
/// </editor>
/// ```
///
/// # Returns
///
/// A vector of message strings, one per section. Empty sections are filtered out.
///
/// # Errors
///
/// Returns error if file cannot be read.
pub fn load_initial_messages(path: &PathBuf) -> Result<Vec<String>> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("Failed to read initial messages file: {}", path.display()))?;

    // Split on horizontal rules (---, ***, ___, ~~~)
    // We need at least 3 consecutive characters to count as a separator
    let separator_regex = regex::Regex::new(r"(?m)^(?:---+|\*\*\*+|___+|~~~+)\s*$").unwrap();

    let messages: Vec<String> = separator_regex
        .split(&content)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    Ok(messages)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_load_initial_messages_single_message() {
        // Requirement: Single message without separators should return one message.
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("init.md");

        std::fs::write(
            &file_path,
            "Let's check the README:\n\n<editor>\nview README.md\n</editor>",
        )
        .unwrap();

        let messages = load_initial_messages(&file_path).unwrap();

        assert_eq!(messages.len(), 1, "Should have exactly one message");
        assert!(
            messages[0].contains("view README.md"),
            "Message should contain command"
        );
    }

    #[test]
    fn test_load_initial_messages_multiple_with_dash_separator() {
        // Requirement: Messages separated by --- should be split into separate messages.
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("init.md");

        std::fs::write(
            &file_path,
            "Message 1\n\n<bash>\nls\n</bash>\n---\nMessage 2\n\n<bash>\npwd\n</bash>",
        )
        .unwrap();

        let messages = load_initial_messages(&file_path).unwrap();

        assert_eq!(messages.len(), 2, "Should have exactly two messages");
        assert!(
            messages[0].contains("ls"),
            "First message should contain ls"
        );
        assert!(
            messages[1].contains("pwd"),
            "Second message should contain pwd"
        );
    }

    #[test]
    fn test_load_initial_messages_multiple_separator_types() {
        // Requirement: All horizontal rule types (---, ***, ___, ~~~) should work as separators.
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("init.md");

        std::fs::write(
            &file_path,
            "Msg 1\n---\nMsg 2\n***\nMsg 3\n___\nMsg 4\n~~~\nMsg 5",
        )
        .unwrap();

        let messages = load_initial_messages(&file_path).unwrap();

        assert_eq!(
            messages.len(),
            5,
            "Should split on all separator types. Got: {:?}",
            messages
        );
    }

    #[test]
    fn test_load_initial_messages_filters_empty_sections() {
        // Requirement: Empty sections (whitespace only) should be filtered out.
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("init.md");

        std::fs::write(
            &file_path,
            "Message 1\n---\n   \n---\nMessage 2\n---\n\n\n---\nMessage 3",
        )
        .unwrap();

        let messages = load_initial_messages(&file_path).unwrap();

        assert_eq!(
            messages.len(),
            3,
            "Should filter out empty sections. Got: {:?}",
            messages
        );
        assert!(messages[0].contains("Message 1"));
        assert!(messages[1].contains("Message 2"));
        assert!(messages[2].contains("Message 3"));
    }

    #[test]
    fn test_load_initial_messages_preserves_whitespace_in_content() {
        // Requirement: Whitespace within message content must be preserved,
        // including indentation in code blocks.
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("init.md");

        let content = "Let's run Python:\n\n<python>\ndef foo():\n    return 42\n</python>";
        std::fs::write(&file_path, content).unwrap();

        let messages = load_initial_messages(&file_path).unwrap();

        assert_eq!(messages.len(), 1);
        assert!(
            messages[0].contains("    return 42"),
            "Should preserve indentation. Got: {}",
            messages[0]
        );
    }

    #[test]
    fn test_load_initial_messages_requires_separator_on_own_line() {
        // Requirement: Separator must be on its own line to count as delimiter.
        // Inline dashes like "test---test" should not split.
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("init.md");

        std::fs::write(&file_path, "Message with inline---dashes should not split").unwrap();

        let messages = load_initial_messages(&file_path).unwrap();

        assert_eq!(
            messages.len(),
            1,
            "Inline separators should not split messages"
        );
    }

    #[test]
    fn test_load_initial_messages_long_separators() {
        // Requirement: Separators with more than 3 characters (----, *****) should work.
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("init.md");

        std::fs::write(&file_path, "Msg 1\n-----\nMsg 2\n*****\nMsg 3").unwrap();

        let messages = load_initial_messages(&file_path).unwrap();

        assert_eq!(messages.len(), 3, "Long separators should work");
    }

    #[test]
    fn test_load_initial_messages_trims_surrounding_whitespace() {
        // Requirement: Leading and trailing whitespace should be trimmed from each message.
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("init.md");

        std::fs::write(&file_path, "\n\n  Message 1  \n\n---\n\n  Message 2  \n\n").unwrap();

        let messages = load_initial_messages(&file_path).unwrap();

        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0], "Message 1", "Should trim whitespace");
        assert_eq!(messages[1], "Message 2", "Should trim whitespace");
    }

    #[test]
    fn test_load_initial_messages_nonexistent_file_returns_error() {
        // Requirement: Attempting to load from nonexistent file should return error.
        let result = load_initial_messages(&PathBuf::from("/nonexistent/file.md"));

        assert!(result.is_err(), "Should return error for nonexistent file");
        assert!(
            result.unwrap_err().to_string().contains("Failed to read"),
            "Error should mention read failure"
        );
    }

    #[test]
    fn test_load_initial_messages_empty_file_returns_empty_vec() {
        // Requirement: Empty file should return empty vector, not error.
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("init.md");

        std::fs::write(&file_path, "").unwrap();

        let messages = load_initial_messages(&file_path).unwrap();

        assert_eq!(messages.len(), 0, "Empty file should return empty vec");
    }

    #[test]
    fn test_load_initial_messages_only_separators_returns_empty_vec() {
        // Requirement: File with only separators (no content) should return empty vector.
        let temp_dir = TempDir::new().unwrap();
        let file_path = temp_dir.path().join("init.md");

        std::fs::write(&file_path, "---\n***\n___\n~~~").unwrap();

        let messages = load_initial_messages(&file_path).unwrap();

        assert_eq!(messages.len(), 0, "Only separators should return empty vec");
    }
}
