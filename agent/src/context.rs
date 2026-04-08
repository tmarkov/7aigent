//! Context building for LLM interactions.
//!
//! This module handles constructing the message context sent to the LLM,
//! including system prompts, task descriptions, conversation history,
//! and screen state.

use crate::config::{Config, SandboxConfig};
use crate::templates::{TemplateContext, TemplateRenderer};
use crate::types::{Message, ScreenState};
use std::path::Path;

/// Build system prompt from configuration
///
/// The system prompt includes:
/// - Agent identity and capabilities
/// - Available environments
/// - Command syntax instructions
/// - File access restrictions (from sandbox config)
/// - Behavioral guidelines
pub fn build_system_prompt(
    config: &Config,
    sandbox: &SandboxConfig,
    project_dir: &Path,
) -> Message {
    let renderer = TemplateRenderer::new(project_dir);
    let mut context = TemplateContext::new();

    // Build read-only files section
    let read_only_files = if !sandbox.files.read_only.is_empty() {
        let mut section = String::from("IMPORTANT: Do NOT modify these files (read-only):\n");
        for pattern in &sandbox.files.read_only {
            section.push_str(&format!("  - {}\n", pattern));
        }
        section.push('\n');
        section
    } else {
        String::new()
    };

    // Build no-access files section
    let no_access_files = if !sandbox.files.no_access.is_empty() {
        let mut section = String::from("IMPORTANT: Do NOT access these files:\n");
        for pattern in &sandbox.files.no_access {
            section.push_str(&format!("  - {}\n", pattern));
        }
        section.push('\n');
        section
    } else {
        String::new()
    };

    // Build additional guidelines
    let mut additional_guidelines = String::new();
    if !config.behavior.explain_actions {
        additional_guidelines.push_str("- Be concise. Don't explain every action unless asked\n");
    }
    if config.behavior.ask_before_destructive {
        additional_guidelines
            .push_str("- Ask before destructive operations (rm, drop table, etc.)\n");
    }

    // Insert all template keys
    context.insert("read_only_files", read_only_files);
    context.insert("no_access_files", no_access_files);
    context.insert("additional_guidelines", additional_guidelines);

    // Render template
    let content = renderer
        .render("system.md", &context)
        .expect("Failed to render system prompt template");

    Message::system(content)
}

/// Format task message
///
/// Converts the task description into a user message.
pub fn format_task(task: &str, project_dir: &Path) -> Message {
    let renderer = TemplateRenderer::new(project_dir);
    let mut context = TemplateContext::new();

    context.insert("task", task);

    let content = renderer
        .render("task.md", &context)
        .expect("Failed to render task template");

    Message::user(content)
}

/// Format command execution output
///
/// Converts command execution results into a user message.
/// If threshold > 0 and output exceeds threshold, truncates with summary indicator.
/// TODO: Use an LLM-generated summary (need to know the LLM context window threshold)
pub fn format_command_output(
    environment: &str,
    command: &str,
    output: &str,
    exit_code: Option<i32>,
    processed: bool,
    project_dir: &Path,
    threshold: usize,
) -> Message {
    let renderer = TemplateRenderer::new(project_dir);
    let mut context = TemplateContext::new();

    // Apply summarization threshold if configured
    let output_to_use = if threshold > 0 && output.len() > threshold {
        // Truncate output and add summary indicator
        let truncated = &output[..threshold.min(output.len())];
        let summary_note = format!(
            "\n\n... [OUTPUT TRUNCATED: {} chars total, showing first {} chars] ...",
            output.len(),
            threshold
        );
        format!("{}{}", truncated, summary_note)
    } else {
        output.to_string()
    };

    context.insert("environment", environment);
    context.insert("command", command);
    context.insert("output", &output_to_use);
    context.insert(
        "exit_code",
        exit_code
            .map(|c| c.to_string())
            .unwrap_or_else(|| "N/A".to_string()),
    );
    context.insert("processed", if processed { "yes" } else { "no" });

    let content = renderer
        .render("command_output.md", &context)
        .expect("Failed to render command output template");

    Message::user(content)
}

/// Truncate conversation history to fit within character limit
///
/// Public to allow event-based context building
///
/// Keeps the most recent messages that fit within the character budget.
/// Messages are kept in chronological order.
/// Uses character count as proxy for tokens (approximately 4 chars per token).
pub fn truncate_history(history: &[Message], max_chars: usize) -> Vec<Message> {
    let mut result = Vec::new();
    let mut total_chars = 0;

    // Iterate from most recent to oldest
    for msg in history.iter().rev() {
        let msg_chars = msg.content.len();

        if total_chars + msg_chars > max_chars {
            break;
        }

        result.push(msg.clone());
        total_chars += msg_chars;
    }

    // Reverse to restore chronological order
    result.reverse();
    result
}

/// Format screen state as a user message
///
/// Converts the screen state into a text representation that shows
/// the current state of each environment.
/// Format screen state into a Message (public for event-based context building)
pub fn format_screen(screen: &ScreenState, project_dir: &Path) -> Message {
    let renderer = TemplateRenderer::new(project_dir);
    let mut context = TemplateContext::new();

    // Build screen content
    let mut screen_content = String::new();

    // Sort environment names for consistent ordering
    let mut env_names: Vec<_> = screen.sections.keys().collect();
    env_names.sort();

    for env_name in env_names {
        let section = &screen.sections[env_name];

        screen_content.push_str(&format!("--- {} ---\n", env_name));
        screen_content.push_str(&section.content);

        // Add newline if content doesn't end with one
        if !section.content.ends_with('\n') {
            screen_content.push('\n');
        }

        screen_content.push('\n');
    }

    context.insert("screen", screen_content);

    let content = renderer
        .render("screen.md", &context)
        .expect("Failed to render screen template");

    Message::user(content)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{FileAccessConfig, ResourceConfig};
    use crate::types::{MessageRole, ScreenSection};
    use chrono::Utc;
    use std::collections::HashMap;
    use tempfile::TempDir;

    #[test]
    fn test_build_system_prompt_basic() {
        let tmp = TempDir::new().unwrap();
        let config = Config::default();

        let sandbox = SandboxConfig {
            shell_prefix: None,
            disable_network: Some(true),
            sandbox_path: None,
            files: FileAccessConfig::default(),
            resources: ResourceConfig::default(),
        };

        let msg = build_system_prompt(&config, &sandbox, tmp.path());
        assert_eq!(msg.role, MessageRole::System);
        assert!(msg.content.contains("7aigent"));
        assert!(msg.content.contains("bash"));
        assert!(msg.content.contains("python"));
        assert!(msg.content.contains("editor"));
    }

    #[test]
    fn test_build_system_prompt_with_restrictions() {
        let tmp = TempDir::new().unwrap();
        let mut config = Config::default();
        config.behavior.explain_actions = false;
        config.behavior.ask_before_destructive = true;

        let sandbox = SandboxConfig {
            shell_prefix: None,
            disable_network: Some(true),
            sandbox_path: None,
            files: FileAccessConfig {
                read_only: vec!["*.lock".to_string()],
                read_write: vec![],
                no_access: vec![".env".to_string()],
            },
            resources: ResourceConfig::default(),
        };

        let msg = build_system_prompt(&config, &sandbox, tmp.path());
        assert!(msg.content.contains("*.lock"));
        assert!(msg.content.contains(".env"));
        assert!(msg.content.contains("Be concise"));
        assert!(msg.content.contains("Ask before destructive"));
    }

    #[test]
    fn test_format_task() {
        let tmp = TempDir::new().unwrap();
        let task = "Fix the authentication bug";

        let msg = format_task(task, tmp.path());
        assert_eq!(msg.role, MessageRole::User);
        assert_eq!(msg.content.trim(), task);
    }

    #[test]
    fn test_format_command_output() {
        let tmp = TempDir::new().unwrap();

        let msg = format_command_output(
            "bash",
            "ls -la",
            "file1.txt\nfile2.txt",
            Some(0),
            true,
            tmp.path(),
            0, // No threshold
        );
        assert_eq!(msg.role, MessageRole::User);
        assert!(msg.content.contains("Environment: bash"));
        assert!(msg.content.contains("Command: ls -la"));
        assert!(msg.content.contains("Exit Code: 0"));
        assert!(msg.content.contains("Processed: yes"));
        assert!(msg.content.contains("file1.txt"));
    }

    #[test]
    fn test_format_command_output_with_truncation() {
        let tmp = TempDir::new().unwrap();

        // Create output that exceeds threshold
        let long_output = "x".repeat(1000);
        let threshold = 100;

        let msg = format_command_output(
            "bash",
            "cat bigfile.txt",
            &long_output,
            Some(0),
            true,
            tmp.path(),
            threshold,
        );

        // Verify the output is truncated
        assert!(msg.content.contains("OUTPUT TRUNCATED"));
        assert!(msg.content.contains("1000 chars total"));
        assert!(msg.content.contains("showing first 100 chars"));
        // The truncated portion should be in the output
        assert!(msg.content.contains(&"x".repeat(100)));
        // But not the full output
        assert!(!msg.content.contains(&"x".repeat(500)));
    }
    #[test]
    fn test_format_screen() {
        let tmp = TempDir::new().unwrap();
        let mut sections = HashMap::new();
        sections.insert(
            "bash".to_string(),
            ScreenSection {
                content: "$ ls\nfile1.txt\nfile2.txt\n".to_string(),
            },
        );
        sections.insert(
            "python".to_string(),
            ScreenSection {
                content: ">>> x = 42\n>>> print(x)\n42\n".to_string(),
            },
        );

        let screen = ScreenState {
            timestamp: Utc::now(),
            sections,
        };

        let msg = format_screen(&screen, tmp.path());
        assert_eq!(msg.role, MessageRole::User);
        assert!(msg.content.contains("Current Screen State"));
        assert!(msg.content.contains("--- bash ---"));
        assert!(msg.content.contains("--- python ---"));
        assert!(msg.content.contains("file1.txt"));
        assert!(msg.content.contains("x = 42"));
    }

    #[test]
    fn test_truncate_history_keeps_most_recent_under_limit() {
        // Requirement: truncate_history must keep most recent messages in
        // chronological order under character limit.

        let messages = vec![
            Message::user("message 1 with some content".to_string()),
            Message::assistant("response 1 with some content".to_string()),
            Message::user("message 2 with some content".to_string()),
            Message::assistant("response 2 with some content".to_string()),
            Message::user("message 3 with some content".to_string()),
        ];

        // Allow only ~2 messages worth of characters
        let max_chars = 60;
        let truncated = truncate_history(&messages, max_chars);

        // Should keep only the most recent messages
        assert!(
            truncated.len() < messages.len(),
            "Must truncate when over limit"
        );
        assert!(!truncated.is_empty(), "Must keep at least some messages");

        // Should maintain chronological order
        if truncated.len() >= 2 {
            assert!(
                truncated[0].timestamp <= truncated[1].timestamp,
                "Must maintain chronological order after truncation"
            );
        }
    }
}
