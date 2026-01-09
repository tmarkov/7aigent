use crate::budget::BudgetCheckResult;
use crate::types::{Message, MessageRole, ScreenSection, ScreenState, Session, SessionStatus};
use rust_decimal::Decimal;
use std::io::{self, Write};

/// Display a session's progress after a step
pub fn display_step_progress(step: usize, screen: &ScreenState) {
    println!("\n=== Step {} ===", step);
    println!("Time: {}", screen.timestamp);

    for (env_name, section) in &screen.sections {
        display_screen_section(env_name, section);
    }
}

/// Display a screen section
fn display_screen_section(env_name: &str, section: &ScreenSection) {
    println!("\n--- {} ---", env_name);
    println!("{}", section.content);
}

/// Display the cost summary at the end of a session
pub fn display_cost_summary(session: &Session) {
    println!("\n=== Session Summary ===");
    println!("Session ID: {}", session.id);
    println!("Status: {:?}", session.status);
    println!("Total Cost: ${:.6}", session.total_cost);
    println!("Created: {}", session.created_at);
    println!("Updated: {}", session.updated_at);
    let duration = session.updated_at - session.created_at;
    println!("Duration: {}s", duration.num_seconds());
}

/// Prompt the user for confirmation when exceeding budget
pub fn prompt_budget_confirmation(
    check_result: &BudgetCheckResult,
    estimated_cost: Decimal,
) -> io::Result<bool> {
    match check_result {
        BudgetCheckResult::Ok => Ok(true),
        BudgetCheckResult::WarningThreshold { projected, limit } => {
            println!(
                "\n⚠️  WARNING: Approaching warning threshold (projected: ${:.6}, limit: ${:.6})",
                projected, limit
            );
            println!("Estimated cost for this call: ${:.6}", estimated_cost);
            prompt_yes_no("Continue anyway?")
        }
        BudgetCheckResult::ExceedsPerCall { estimated, limit } => {
            eprintln!(
                "\n❌ ERROR: Estimated cost (${:.6}) exceeds per-call limit (${:.6})",
                estimated, limit
            );
            println!("This call cannot proceed without adjusting the budget.");
            Ok(false)
        }
        BudgetCheckResult::ExceedsSession {
            current,
            estimated,
            limit,
        } => {
            eprintln!(
                "\n❌ ERROR: Session cost (${:.6}) would exceed session limit (${:.6})",
                current + estimated,
                limit
            );
            println!("Current session cost: ${:.6}", current);
            println!("Estimated cost for this call: ${:.6}", estimated);
            println!("This call cannot proceed without adjusting the budget.");
            Ok(false)
        }
    }
}

/// Prompt the user with a yes/no question
fn prompt_yes_no(prompt: &str) -> io::Result<bool> {
    print!("{} [y/N] ", prompt);
    io::stdout().flush()?;

    let mut input = String::new();
    io::stdin().read_line(&mut input)?;

    let input = input.trim().to_lowercase();
    Ok(input == "y" || input == "yes")
}

/// Display an error message
pub fn display_error(error: &anyhow::Error) {
    eprintln!("\n❌ Error: {}", error);
    for cause in error.chain().skip(1) {
        eprintln!("  Caused by: {}", cause);
    }
}

/// Display a paused session message
pub fn display_paused(session_id: &uuid::Uuid) {
    println!("\n⏸  Session paused: {}", session_id);
    println!("Resume with: 7aigent resume {}", session_id);
}

/// Display session list
pub fn display_session_list(sessions: &[Session], verbose: bool) {
    if sessions.is_empty() {
        println!("No sessions found.");
        return;
    }

    println!("\n{} session(s) found:", sessions.len());
    for session in sessions {
        display_session_summary(session, verbose);
    }
}

/// Display a single session summary
fn display_session_summary(session: &Session, verbose: bool) {
    let status_icon = match session.status {
        SessionStatus::Active => "🟢",
        SessionStatus::Paused => "⏸",
        SessionStatus::Completed => "✅",
        SessionStatus::Failed => "❌",
    };

    println!("\n{} {} ({:?})", status_icon, session.id, session.status);
    println!("  Project: {}", session.project_dir.display());
    println!("  Created: {}", session.created_at);
    println!("  Cost: ${:.6}", session.total_cost);

    if verbose {
        println!("  Updated: {}", session.updated_at);
        println!("  Steps: {}", session.step_count);
    }
}

/// Display session history
pub fn display_session_history(
    session: &Session,
    messages: &[Message],
    screens: &[ScreenState],
    step: Option<usize>,
) {
    println!("\n=== Session {} ===", session.id);
    println!("Status: {:?}", session.status);
    println!("Project: {}", session.project_dir.display());
    println!("Total Cost: ${:.6}", session.total_cost);

    if let Some(step_num) = step {
        // Display a specific step
        if step_num >= screens.len() {
            eprintln!("Step {} not found (only {} steps)", step_num, screens.len());
            return;
        }

        println!("\n=== Step {} ===", step_num);
        display_screen_section_full(&screens[step_num]);
    } else {
        // Display all messages
        println!("\n=== Message History ===");
        for (i, msg) in messages.iter().enumerate() {
            display_message(i, msg);
        }

        // Display all screens
        println!("\n=== Screen History ===");
        for (i, screen) in screens.iter().enumerate() {
            println!("\n--- Step {} ---", i);
            display_screen_section_full(screen);
        }
    }
}

/// Display a message
fn display_message(index: usize, message: &Message) {
    let role_prefix = match message.role {
        MessageRole::System => "SYS",
        MessageRole::User => "USR",
        MessageRole::Assistant => "AST",
    };

    println!("\n[{}] {} @ {}", index, role_prefix, message.timestamp);
    println!("{}", message.content);
}

/// Display a screen state with all sections
fn display_screen_section_full(screen: &ScreenState) {
    println!("Time: {}", screen.timestamp);
    for (env_name, section) in &screen.sections {
        println!("\n--- {} ---", env_name);
        println!("{}", section.content);
    }
}

/// Display the initial config template content
pub fn get_config_template() -> &'static str {
    r#"# 7aigent configuration file
# See docs/agent-design.md for full documentation

[llm]
# OpenAI-compatible API endpoint
# endpoint = "https://api.openai.com/v1"

# Model to use
# model = "gpt-4"

# API key (can also use OPENAI_API_KEY environment variable)
# api_key = "sk-..."

# Token pricing (dollars per 1K tokens)
# input_price_per_1k = 0.03
# output_price_per_1k = 0.06

# Temperature for LLM sampling
# temperature = 0.7

# Maximum tokens to generate
# max_tokens = 4096

[budget]
# Maximum cost per LLM call (dollars)
# max_cost_per_call = 1.00

# Maximum total cost per session (dollars)
# max_session_cost = 10.00

# Warning threshold as fraction of session budget
# warning_threshold = 0.8

[sandbox]
# Container image to use for orchestrator
# container_image = "7aigent-orchestrator:latest"

# Maximum execution time for commands (seconds)
# timeout = 300

# Memory limit (e.g., "512M", "2G")
# memory_limit = "2G"

# CPU limit (number of cores, e.g., 1.0, 2.5)
# cpu_limit = 2.0

[behavior]
# Maximum conversation history to keep in context
# max_history_messages = 50

# Require confirmation before executing commands
# confirm_before_execute = false

# Auto-save session after each step
# auto_save = true
"#
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ScreenSection, ScreenState, Session, SessionId, SessionStatus};
    use chrono::Utc;
    use rust_decimal_macros::dec;
    use std::path::PathBuf;

    #[test]
    fn test_display_step_progress() {
        use std::collections::HashMap;

        let mut sections = HashMap::new();
        sections.insert(
            "bash".to_string(),
            ScreenSection {
                content: "Test output".to_string(),
                max_lines: 100,
            },
        );

        let screen = ScreenState {
            step: 0,
            timestamp: Utc::now(),
            sections,
        };

        // Just verify it doesn't panic
        display_step_progress(0, &screen);
    }

    #[test]
    fn test_display_cost_summary() {
        use crate::types::LlmConfigSnapshot;

        let session = Session {
            id: SessionId::new(),
            project_dir: PathBuf::from("/test"),
            task: "test task".to_string(),
            created_at: Utc::now(),
            updated_at: Utc::now(),
            status: SessionStatus::Active,
            total_cost: dec!(1.23),
            token_usage: Default::default(),
            step_count: 0,
            llm_config: LlmConfigSnapshot {
                endpoint: "http://localhost".to_string(),
                model: "gpt-4".to_string(),
            },
        };

        // Just verify it doesn't panic
        display_cost_summary(&session);
    }

    #[test]
    fn test_get_config_template() {
        let template = get_config_template();
        assert!(template.contains("[llm]"));
        assert!(template.contains("[budget]"));
        assert!(template.contains("[sandbox]"));
        assert!(template.contains("[behavior]"));
    }
}
