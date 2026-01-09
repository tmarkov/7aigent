//! Context building for LLM interactions.
//!
//! This module handles constructing the message context sent to the LLM,
//! including system prompts, task descriptions, conversation history,
//! and screen state.

use crate::config::{Config, SandboxConfig};
use crate::types::{Message, ScreenState};

/// Maximum tokens for conversation history (approximate)
/// Using a character-based approximation: 4 chars per token
const MAX_HISTORY_CHARS: usize = 400_000; // ~100k tokens

/// Build system prompt from configuration
///
/// The system prompt includes:
/// - Agent identity and capabilities
/// - Available environments
/// - Command syntax instructions
/// - File access restrictions (from sandbox config)
/// - Behavioral guidelines
pub fn build_system_prompt(config: &Config, sandbox: &SandboxConfig) -> Message {
    let mut prompt = String::new();

    // Agent identity
    prompt.push_str(
        "You are 7aigent, an AI assistant that helps users accomplish diverse tasks.\n\n",
    );

    // Available environments
    prompt.push_str("You have access to the following environments:\n");
    prompt.push_str("- bash: Execute shell commands\n");
    prompt.push_str("- python: Execute Python code (persistent REPL)\n");
    prompt.push_str("- editor: View and edit files\n\n");

    // Command syntax
    prompt.push_str("To execute commands, use fenced code blocks with the environment name:\n");
    prompt.push_str("```bash\nls -la\n```\n\n");
    prompt.push_str("```python\nimport pandas as pd\n```\n\n");
    prompt.push_str("```editor\nview src/main.py 1-50\n```\n\n");

    // File restrictions
    if !sandbox.files.read_only.is_empty() {
        prompt.push_str("IMPORTANT: Do NOT modify these files (read-only):\n");
        for pattern in &sandbox.files.read_only {
            prompt.push_str(&format!("  - {}\n", pattern));
        }
        prompt.push('\n');
    }

    if !sandbox.files.no_access.is_empty() {
        prompt.push_str("IMPORTANT: Do NOT access these files:\n");
        for pattern in &sandbox.files.no_access {
            prompt.push_str(&format!("  - {}\n", pattern));
        }
        prompt.push('\n');
    }

    // Behavioral guidelines
    prompt.push_str("Guidelines:\n");
    prompt.push_str("- Work step by step to accomplish the task\n");
    prompt.push_str("- Check your work and fix errors\n");
    prompt.push_str("- When done, explain what you accomplished\n");

    if !config.behavior.explain_actions {
        prompt.push_str("- Be concise. Don't explain every action unless asked\n");
    }

    if config.behavior.ask_before_destructive {
        prompt.push_str("- Ask before destructive operations (rm, drop table, etc.)\n");
    }

    prompt.push('\n');

    Message::system(prompt)
}

/// Build the complete message context for LLM
///
/// Returns messages in this order:
/// 1. System prompt (always included)
/// 2. Task description (always included)
/// 3. Recent conversation history (truncated to fit character limit)
/// 4. Current screen state (always included)
pub fn build_llm_messages(
    config: &Config,
    sandbox: &SandboxConfig,
    task: &str,
    history: &[Message],
    current_screen: &ScreenState,
) -> Vec<Message> {
    let mut messages = Vec::new();

    // 1. System prompt (always included)
    let system_prompt = build_system_prompt(config, sandbox);
    messages.push(system_prompt);

    // 2. Task description (always included)
    messages.push(Message::user(task.to_string()));

    // 3. Recent history (truncated to fit)
    let truncated_history = truncate_history(history, MAX_HISTORY_CHARS);
    messages.extend(truncated_history);

    // 4. Current screen (always included)
    let screen_message = format_screen(current_screen);
    messages.push(screen_message);

    messages
}

/// Truncate conversation history to fit within character limit
///
/// Keeps the most recent messages that fit within the character budget.
/// Messages are kept in chronological order.
/// Uses character count as proxy for tokens (approximately 4 chars per token).
fn truncate_history(history: &[Message], max_chars: usize) -> Vec<Message> {
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
fn format_screen(screen: &ScreenState) -> Message {
    let mut content = String::new();

    content.push_str("=== Current Screen State ===\n\n");

    // Sort environment names for consistent ordering
    let mut env_names: Vec<_> = screen.sections.keys().collect();
    env_names.sort();

    for env_name in env_names {
        let section = &screen.sections[env_name];

        content.push_str(&format!("--- {} ---\n", env_name));
        content.push_str(&section.content);

        // Add newline if content doesn't end with one
        if !section.content.ends_with('\n') {
            content.push('\n');
        }

        content.push('\n');
    }

    Message::user(content)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{FileAccessConfig, ResourceConfig};
    use crate::types::{MessageRole, ScreenSection};
    use chrono::Utc;
    use std::collections::HashMap;

    #[test]
    fn test_build_system_prompt_basic() {
        let config = Config::default();

        let sandbox = SandboxConfig {
            files: FileAccessConfig::default(),
            resources: ResourceConfig::default(),
        };

        let msg = build_system_prompt(&config, &sandbox);
        assert_eq!(msg.role, MessageRole::System);
        assert!(msg.content.contains("7aigent"));
        assert!(msg.content.contains("bash"));
        assert!(msg.content.contains("python"));
        assert!(msg.content.contains("editor"));
    }

    #[test]
    fn test_build_system_prompt_with_restrictions() {
        let mut config = Config::default();
        config.behavior.explain_actions = false;
        config.behavior.ask_before_destructive = true;

        let sandbox = SandboxConfig {
            files: FileAccessConfig {
                read_only: vec!["*.lock".to_string()],
                read_write: vec![],
                no_access: vec![".env".to_string()],
            },
            resources: ResourceConfig::default(),
        };

        let msg = build_system_prompt(&config, &sandbox);
        assert!(msg.content.contains("*.lock"));
        assert!(msg.content.contains(".env"));
        assert!(msg.content.contains("Be concise"));
        assert!(msg.content.contains("Ask before destructive"));
    }

    #[test]
    fn test_format_screen() {
        let mut sections = HashMap::new();
        sections.insert(
            "bash".to_string(),
            ScreenSection {
                content: "$ ls\nfile1.txt\nfile2.txt\n".to_string(),
                max_lines: 50,
            },
        );
        sections.insert(
            "python".to_string(),
            ScreenSection {
                content: ">>> x = 42\n>>> print(x)\n42\n".to_string(),
                max_lines: 50,
            },
        );

        let screen = ScreenState {
            step: 1,
            timestamp: Utc::now(),
            sections,
        };

        let msg = format_screen(&screen);
        assert_eq!(msg.role, MessageRole::User);
        assert!(msg.content.contains("Current Screen State"));
        assert!(msg.content.contains("--- bash ---"));
        assert!(msg.content.contains("--- python ---"));
        assert!(msg.content.contains("file1.txt"));
        assert!(msg.content.contains("x = 42"));
    }

    #[test]
    fn test_truncate_history() {
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
        assert!(truncated.len() < messages.len());
        assert!(!truncated.is_empty());

        // Should maintain chronological order
        if truncated.len() >= 2 {
            assert!(truncated[0].timestamp <= truncated[1].timestamp);
        }
    }

    #[test]
    fn test_build_llm_messages() {
        let config = Config::default();

        let sandbox = SandboxConfig {
            files: FileAccessConfig::default(),
            resources: ResourceConfig::default(),
        };

        let task = "Do something useful";
        let history = vec![
            Message::user("previous message".to_string()),
            Message::assistant("previous response".to_string()),
        ];

        let screen = ScreenState {
            step: 1,
            timestamp: Utc::now(),
            sections: HashMap::new(),
        };

        let messages = build_llm_messages(&config, &sandbox, task, &history, &screen);

        // Should have: system + task + history + screen
        assert!(messages.len() >= 4);

        // First should be system
        assert_eq!(messages[0].role, MessageRole::System);

        // Second should be task (user message)
        assert_eq!(messages[1].role, MessageRole::User);
        assert_eq!(messages[1].content, task);

        // Last should be screen (user message)
        assert_eq!(messages[messages.len() - 1].role, MessageRole::User);
        assert!(messages[messages.len() - 1]
            .content
            .contains("Current Screen State"));
    }
}
