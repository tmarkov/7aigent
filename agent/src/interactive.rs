//! Interactive mode (REPL) for 7aigent.
//!
//! Implements a read-eval-print loop that allows users to have multi-turn
//! conversations with the agent, maintaining context across turns.

use crate::{
    config::ConfigLoader, container::ContainerManager, llm::openai::OpenAiCompatibleClient,
    llm::retry::RetryClient, types::SessionManager, ui, Agent,
};
use anyhow::{Context, Result};
use std::io::{self, BufRead, Write as IoWrite};
use std::path::Path;

/// Meta-commands recognized in interactive mode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MetaCommand {
    Help,
    Status,
    Clear,
    Exit,
}

/// Kind of user input in interactive mode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputKind {
    /// A recognized meta-command.
    Meta(MetaCommand),
    /// A task description to send to the agent.
    Task(String),
    /// Empty or whitespace-only input.
    Empty,
}

/// Parse a line of user input into an `InputKind`.
///
/// Recognizes meta-commands case-insensitively; everything else is a task.
pub fn parse_input(s: &str) -> InputKind {
    let trimmed = s.trim();
    if trimmed.is_empty() {
        return InputKind::Empty;
    }
    match trimmed.to_lowercase().as_str() {
        "help" | "?" => InputKind::Meta(MetaCommand::Help),
        "exit" | "quit" => InputKind::Meta(MetaCommand::Exit),
        "status" => InputKind::Meta(MetaCommand::Status),
        "clear" => InputKind::Meta(MetaCommand::Clear),
        _ => InputKind::Task(trimmed.to_string()),
    }
}

/// Print help text describing interactive mode commands.
fn print_help() {
    println!("Interactive mode commands:");
    println!();
    println!("  <task>   Give the agent a task to work on");
    println!("  help     Show this help message");
    println!("  status   Show current session status");
    println!("  clear    Clear conversation context (start fresh)");
    println!("  exit     Exit interactive mode");
    println!("  quit     Exit interactive mode");
}

/// Create a new agent session for the given first task.
///
/// Loads configuration, allocates a session, spawns the container, and
/// returns a ready-to-use `Agent`.
fn create_agent_session(
    project_dir: &Path,
    first_task: &str,
) -> Result<Agent<RetryClient<OpenAiCompatibleClient>>> {
    let config = ConfigLoader::load()?;
    let llm_config = config.llm.validate()?;
    let base_client = OpenAiCompatibleClient::new(llm_config)?;
    let llm_client = RetryClient::new(base_client);

    let session_manager = SessionManager::new(project_dir.to_path_buf());
    let session = session_manager.create_session(first_task.to_string())?;

    println!("Created session {}", session.id);
    println!();

    let container_manager = ContainerManager::new()?;
    let container = container_manager
        .spawn_container(project_dir, &config.sandbox)
        .context("Failed to start container")?;

    Agent::new(session, config, container, llm_client)
}

/// Run the 7aigent interactive REPL.
///
/// Prompts for tasks, runs the agent for each, and handles meta-commands.
/// Maintains a single agent session (and container) across turns until the
/// user explicitly clears the context or exits.
pub async fn run_interactive(project_dir: &Path) -> Result<()> {
    println!("7aigent interactive mode. Type 'help' for commands, 'exit' to quit.");
    println!();

    let mut active_agent: Option<Agent<RetryClient<OpenAiCompatibleClient>>> = None;
    let stdin = io::stdin();

    loop {
        print!("7aigent> ");
        io::stdout().flush()?;

        let mut line = String::new();
        let bytes_read = stdin.lock().read_line(&mut line)?;

        // EOF (Ctrl+D)
        if bytes_read == 0 {
            println!();
            println!("Goodbye!");
            break;
        }

        match parse_input(&line) {
            InputKind::Empty => {}
            InputKind::Meta(MetaCommand::Help) => {
                print_help();
                println!();
            }
            InputKind::Meta(MetaCommand::Exit) => {
                println!("Goodbye!");
                break;
            }
            InputKind::Meta(MetaCommand::Status) => {
                match &active_agent {
                    None => println!("No active session."),
                    Some(agent) => {
                        let session = agent.session();
                        println!("Session: {}", session.id);
                        println!("Task:    {}", session.task);
                        println!("Status:  {:?}", session.status);
                        println!("Cost:    ${:.4}", session.total_cost);
                        println!("LLM calls: {}", session.llm_call_count);
                        println!("Commands:  {}", session.command_count);
                    }
                }
                println!();
            }
            InputKind::Meta(MetaCommand::Clear) => {
                active_agent = None;
                println!("Context cleared. Starting fresh on next task.");
                println!();
            }
            InputKind::Task(task) => {
                // Lazily create the agent session on the first task (or after clear).
                if active_agent.is_none() {
                    match create_agent_session(project_dir, &task) {
                        Ok(agent) => active_agent = Some(agent),
                        Err(e) => {
                            ui::display_error(&e);
                            println!();
                            continue;
                        }
                    }
                }

                let agent = active_agent.as_mut().unwrap();
                if let Err(e) = agent.run_turn(&task).await {
                    ui::display_error(&e);
                    println!();
                    println!(
                        "The agent encountered an error. \
                         You can try another task or type 'exit'."
                    );
                    println!();
                }
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_input_empty_string_returns_empty() {
        // Requirement: Completely empty input must be treated as no-op.
        assert_eq!(parse_input(""), InputKind::Empty);
    }

    #[test]
    fn test_parse_input_whitespace_only_returns_empty() {
        // Requirement: Whitespace-only input must be treated as no-op.
        assert_eq!(parse_input("   "), InputKind::Empty);
        assert_eq!(parse_input("\t"), InputKind::Empty);
        assert_eq!(parse_input("\n"), InputKind::Empty);
    }

    #[test]
    fn test_parse_input_help_keyword_and_question_mark_recognized() {
        // Requirement: Both 'help' and '?' must trigger the help command.
        assert_eq!(parse_input("help"), InputKind::Meta(MetaCommand::Help));
        assert_eq!(parse_input("HELP"), InputKind::Meta(MetaCommand::Help));
        assert_eq!(parse_input("?"), InputKind::Meta(MetaCommand::Help));
    }

    #[test]
    fn test_parse_input_exit_and_quit_both_recognized() {
        // Requirement: Both 'exit' and 'quit' must exit interactive mode.
        assert_eq!(parse_input("exit"), InputKind::Meta(MetaCommand::Exit));
        assert_eq!(parse_input("quit"), InputKind::Meta(MetaCommand::Exit));
        assert_eq!(parse_input("EXIT"), InputKind::Meta(MetaCommand::Exit));
        assert_eq!(parse_input("QUIT"), InputKind::Meta(MetaCommand::Exit));
    }

    #[test]
    fn test_parse_input_status_recognized_case_insensitively() {
        // Requirement: 'status' must show session status regardless of case.
        assert_eq!(parse_input("status"), InputKind::Meta(MetaCommand::Status));
        assert_eq!(parse_input("STATUS"), InputKind::Meta(MetaCommand::Status));
    }

    #[test]
    fn test_parse_input_clear_recognized_case_insensitively() {
        // Requirement: 'clear' must clear conversation context regardless of case.
        assert_eq!(parse_input("clear"), InputKind::Meta(MetaCommand::Clear));
        assert_eq!(parse_input("CLEAR"), InputKind::Meta(MetaCommand::Clear));
    }

    #[test]
    fn test_parse_input_non_command_text_becomes_task() {
        // Requirement: Any non-command text must be passed to the agent as a task.
        assert_eq!(
            parse_input("add a --verbose flag"),
            InputKind::Task("add a --verbose flag".to_string())
        );
    }

    #[test]
    fn test_parse_input_trims_surrounding_whitespace_from_task() {
        // Requirement: Leading/trailing whitespace must be stripped from tasks.
        assert_eq!(
            parse_input("  fix the bug  "),
            InputKind::Task("fix the bug".to_string())
        );
    }

    #[test]
    fn test_parse_input_trailing_newline_stripped_from_task() {
        // Requirement: Newline appended by read_line must not appear in the task.
        assert_eq!(
            parse_input("fix the bug\n"),
            InputKind::Task("fix the bug".to_string())
        );
    }

    #[test]
    fn test_parse_input_multiword_task_preserved_intact() {
        // Requirement: Multi-word tasks with internal spaces must be passed through intact.
        let task = "Add input validation to the config loader and write tests";
        assert_eq!(parse_input(task), InputKind::Task(task.to_string()));
    }
}
