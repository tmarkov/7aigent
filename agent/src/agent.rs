//! Main agent loop for 7aigent.
//!
//! This module implements the core agent that:
//! - Loads configuration and manages sessions
//! - Calls LLM with context and budget checking
//! - Parses LLM responses for commands
//! - Executes commands via the containerized orchestrator
//! - Persists all events to event log

use crate::budget::{check_budget, BudgetCheckResult};
use crate::config::Config;
use crate::container::ContainerHandle;
use crate::format::{format_completion_summary, format_event, DisplayMode};
use crate::llm::{CompletionRequest, LlmClient, LlmMessage};
use crate::parser::parse_commands;
use crate::types::{
    Event, LlmCallPurpose, MessageRole, ScreenState, SessionMetadata, SessionStatus,
};
use anyhow::{Context, Result};
use chrono::Utc;
use ignore::WalkBuilder;
use std::collections::HashMap;
use std::io::{self, Write as IoWrite};
use std::path::Path;

/// Helper struct for tree building results
struct TreeResult {
    content: String,
    file_count: usize,
}

/// Build directory tree at specific depth
fn build_tree_at_depth(project_dir: &Path, max_depth: usize) -> Result<TreeResult> {
    let mut entries = Vec::new();
    let mut file_count = 0;

    // Use ignore crate to respect .gitignore
    let walker = WalkBuilder::new(project_dir)
        .max_depth(Some(max_depth))
        .hidden(false) // Show hidden files like .github
        .git_ignore(true) // Respect .gitignore
        .git_exclude(true) // Respect .git/info/exclude
        .git_global(false) // Don't use global gitignore
        .require_git(false) // Respect .gitignore even in non-git directories
        .build();

    for result in walker {
        let entry = result.context("Failed to read directory entry")?;
        let path = entry.path();

        // Skip .git and .7aigent directories and all their contents
        let file_name = path.file_name().and_then(|n| n.to_str());
        if file_name == Some(".git")
            || file_name == Some(".7aigent")
            || path.ancestors().any(|p| {
                let name = p.file_name().and_then(|n| n.to_str());
                name == Some(".git") || name == Some(".7aigent")
            })
        {
            continue;
        }

        // Get relative path
        let rel_path = path
            .strip_prefix(project_dir)
            .unwrap_or(path)
            .to_string_lossy()
            .to_string();

        if rel_path.is_empty() {
            continue; // Skip root
        }

        if entry.file_type().is_some_and(|ft| ft.is_file()) {
            file_count += 1;
        }

        entries.push((rel_path, entry.file_type()));
    }

    // Sort entries
    entries.sort_by(|a, b| a.0.cmp(&b.0));

    // Build tree-style output
    let mut content = String::new();
    for (path, file_type) in entries {
        let is_dir = file_type.is_some_and(|ft| ft.is_dir());
        let display = if is_dir {
            format!("{}/\n", path)
        } else {
            format!("{}\n", path)
        };
        content.push_str(&display);
    }

    Ok(TreeResult {
        content,
        file_count,
    })
}

/// Build a directory tree with adaptive depth based on file count.
///
/// Starts at depth 1 and increases until hitting max_files or max depth of 5.
/// Always returns at least depth 1, even if there are >max_files files at root.
fn build_directory_tree(project_dir: &Path, max_files: usize) -> Result<String> {
    const MAX_DEPTH: usize = 5;

    let mut depth = 1;
    let mut tree = build_tree_at_depth(project_dir, depth)?;

    // Always guarantee at least depth 1
    if tree.file_count > max_files {
        return Ok(tree.content);
    }

    // Try to go deeper
    while depth < MAX_DEPTH {
        depth += 1;
        let new_tree = build_tree_at_depth(project_dir, depth)?;

        if new_tree.file_count > max_files {
            // Too many files, return previous depth
            return Ok(tree.content);
        }

        tree = new_tree;
    }

    Ok(tree.content)
}

/// Main agent that manages LLM interaction and command execution
pub struct Agent<C: LlmClient> {
    /// Session metadata and tracking
    session: SessionMetadata,
    /// Agent configuration
    config: Config,
    /// Container handle for orchestrator communication
    container: ContainerHandle,
    /// LLM client
    llm_client: C,
    /// LLM call counter for sequential IDs
    llm_call_counter: usize,
}

impl<C: LlmClient> Agent<C> {
    /// Create a new agent
    pub fn new(
        session: SessionMetadata,
        config: Config,
        container: ContainerHandle,
        llm_client: C,
    ) -> Result<Self> {
        // Count existing LLM calls to set counter
        let events = session.load_events()?;
        let llm_call_counter = events
            .iter()
            .filter(|e| matches!(e, Event::LlmCall { .. }))
            .count();

        Ok(Self {
            session,
            config,
            container,
            llm_client,
            llm_call_counter,
        })
    }

    /// Create an empty screen state
    fn create_empty_screen() -> ScreenState {
        ScreenState {
            timestamp: Utc::now(),
            sections: HashMap::new(),
        }
    }

    /// Run the main agent loop until task completion or error
    pub async fn run(&mut self) -> Result<()> {
        println!("Starting task: {}", self.session.task);
        println!();

        // Load existing events to check if this is a new session or resume
        let events = self.session.load_events()?;
        let is_new_session = events.is_empty();

        // On first run, emit system prompt and task events
        if is_new_session {
            let system_prompt_content =
                crate::context::build_system_prompt(&self.config, &self.config.sandbox).content;
            let task_content = self.session.task.clone();

            // Create and emit system prompt event
            let system_event = Event::SystemPrompt {
                timestamp: Utc::now(),
                content: system_prompt_content,
            };
            print!("{}", format_event(&system_event, DisplayMode::Runtime));
            self.session.append_event(&system_event)?;

            // Create and emit task event
            let task_event = Event::TaskMessage {
                timestamp: Utc::now(),
                content: task_content,
            };
            print!("{}", format_event(&task_event, DisplayMode::Runtime));
            self.session.append_event(&task_event)?;

            // Build directory tree and find best overview file
            println!("[Initialization] Building directory tree...");
            let dir_tree =
                build_directory_tree(&self.session.project_dir, 100).unwrap_or_else(|e| {
                    eprintln!("Warning: Failed to build directory tree: {}", e);
                    String::from("Unable to build directory tree")
                });
            println!("  Found project structure");
            println!();

            println!("[Initialization] Finding best overview file...");
            let overview_file = self
                .find_overview_file(&dir_tree)
                .await
                .unwrap_or_else(|e| {
                    eprintln!("Warning: Failed to find overview file: {}", e);
                    // Fallback to README.md if it exists, otherwise empty
                    let readme_path = self.session.project_dir.join("README.md");
                    if readme_path.exists() {
                        "README.md".to_string()
                    } else {
                        String::new()
                    }
                });

            if overview_file.is_empty() {
                eprintln!("Warning: No overview file found, skipping initial view");
                println!("[Initialization] Complete. Starting main loop...");
                println!();
            } else {
                println!("  Overview file: {}", overview_file);
                println!();

                let simulated_content = Self::generate_simulated_message(&overview_file);

                // Print simulated message (not saved as event - it's just for display)
                println!("=== ASSISTANT (Initial) ===");
                println!("{}", simulated_content);
                println!();

                // Parse commands from simulated message (same as regular LLM responses)
                let commands = parse_commands(&simulated_content)
                    .context("Failed to parse simulated message")?;

                // Execute each command (same as main loop)
                for (idx, cmd) in commands.iter().enumerate() {
                    println!("  [{}] Executing {} command...", idx + 1, cmd.env);

                    self.container
                        .send_command(&cmd.env, &cmd.command)
                        .context("Failed to send command to orchestrator")?;

                    let (cmd_response, mut screen_state) = self
                        .container
                        .receive_response()
                        .context("Failed to receive response from orchestrator")?;

                    // Print command output
                    println!();
                    println!("=== ORCHESTRATOR ({}) ===", cmd.env);
                    println!("{}", cmd_response.output);
                    println!();

                    // Update screen timestamp
                    screen_state.timestamp = Utc::now();

                    // Create and emit command execution event
                    let cmd_event = Event::CommandExecution {
                        timestamp: Utc::now(),
                        environment: cmd.env.clone(),
                        command: cmd.command.clone(),
                        output: cmd_response.output,
                        success: cmd_response.success,
                        screen: screen_state,
                    };
                    self.session.append_event(&cmd_event)?;
                }

                println!("[Initialization] Complete. Starting main loop...");
                println!();
            }
        }

        loop {
            // Load all events to build context
            let events = self.session.load_events()?;

            // Get current screen state (from last CommandExecution event)
            let current_screen = events
                .iter()
                .rev()
                .find_map(|e| {
                    if let Event::CommandExecution { screen, .. } = e {
                        Some(screen.clone())
                    } else {
                        None
                    }
                })
                .unwrap_or_else(Self::create_empty_screen);

            // Build LLM context from events
            let messages = build_llm_messages_from_events(&events, &current_screen);

            // Convert to LLM messages
            let llm_messages: Vec<LlmMessage> = messages
                .iter()
                .map(|(role, content)| match role {
                    MessageRole::System => LlmMessage::system(content.clone()),
                    MessageRole::User => LlmMessage::user(content.clone()),
                    MessageRole::Assistant => LlmMessage::assistant(content.clone()),
                })
                .collect();

            // Check budget
            let request = CompletionRequest {
                messages: llm_messages.clone(),
                model: self.config.llm.model.clone(),
                max_tokens: self.config.llm.max_tokens.map(|t| t as u32),
                temperature: self.config.llm.temperature,
            };

            let estimated_cost = self
                .llm_client
                .estimate_cost(&request)
                .context("Failed to estimate cost")?;

            // Check budget before making LLM call
            match check_budget(self.session.total_cost, estimated_cost, &self.config.budget) {
                BudgetCheckResult::Ok => {
                    // Continue without prompting
                }
                BudgetCheckResult::WarningThreshold { projected, limit } => {
                    println!(
                        "WARNING: Next LLM call estimated at ${:.2}, approaching session limit of ${:.2}",
                        estimated_cost, limit
                    );
                    println!("Current total: ${:.2}", self.session.total_cost);
                    println!("Projected total: ${:.2}", projected);
                    println!();
                    print!("Continue? [y/n]: ");
                    io::stdout().flush()?;

                    let mut input = String::new();
                    io::stdin().read_line(&mut input)?;

                    if !input.trim().eq_ignore_ascii_case("y") {
                        println!("Stopping agent");
                        self.session.status = SessionStatus::Paused;
                        self.session.save()?;
                        return Ok(());
                    }
                }
                BudgetCheckResult::ExceedsPerCall { limit, .. } => {
                    eprintln!(
                        "ERROR: Estimated cost ${:.2} exceeds per-call limit of ${:.2}",
                        estimated_cost, limit
                    );
                    self.session.status = SessionStatus::Failed;
                    self.session.save()?;
                    anyhow::bail!("Budget exceeded");
                }
                BudgetCheckResult::ExceedsSession { limit, .. } => {
                    eprintln!(
                        "ERROR: Current total ${:.2} + estimated ${:.2} exceeds session limit of ${:.2}",
                        self.session.total_cost, estimated_cost, limit
                    );
                    self.session.status = SessionStatus::Failed;
                    self.session.save()?;
                    anyhow::bail!("Budget exceeded");
                }
            }

            // Call LLM
            let call_id = self.llm_call_counter;
            self.llm_call_counter += 1;

            let response = self
                .llm_client
                .complete(request.clone())
                .await
                .context("LLM call failed")?;

            // Create and emit LLM call event
            let llm_event = Event::LlmCall {
                timestamp: Utc::now(),
                call_id,
                purpose: LlmCallPurpose::MainLoop,
                request,
                response: response.clone(),
            };
            print!("{}", format_event(&llm_event, DisplayMode::Runtime));
            self.session.append_event(&llm_event)?;

            // Parse commands from response
            let commands = parse_commands(&response.content).context("Failed to parse commands")?;

            if commands.is_empty() {
                // No commands means agent is done
                println!();
                print!("{}", format_completion_summary(&self.session));
                println!();

                let end_event = Event::SessionEnd {
                    timestamp: Utc::now(),
                    status: SessionStatus::Completed,
                    reason: None,
                };
                self.session.append_event(&end_event)?;
                break;
            }

            // Execute each command
            for (idx, cmd) in commands.iter().enumerate() {
                println!("  [{}] Executing {} command...", idx + 1, cmd.env);

                self.container
                    .send_command(&cmd.env, &cmd.command)
                    .context("Failed to send command to orchestrator")?;

                let (cmd_response, mut screen_state) = self
                    .container
                    .receive_response()
                    .context("Failed to receive response from orchestrator")?;

                // Print command output
                println!();
                println!("=== ORCHESTRATOR ({}) ===", cmd.env);
                println!("{}", cmd_response.output);
                println!();

                // Update screen timestamp
                screen_state.timestamp = Utc::now();

                // Create and emit command execution event
                let cmd_event = Event::CommandExecution {
                    timestamp: Utc::now(),
                    environment: cmd.env.clone(),
                    command: cmd.command.clone(),
                    output: cmd_response.output,
                    success: cmd_response.success,
                    screen: screen_state,
                };
                self.session.append_event(&cmd_event)?;
            }

            println!("  Session total: ${:.4}", self.session.total_cost);
            println!();
        }

        Ok(())
    }

    /// Get a reference to the session
    pub fn session(&self) -> &SessionMetadata {
        &self.session
    }

    /// Ask LLM to identify the best file for project overview given a directory tree.
    async fn find_overview_file(&mut self, dir_tree: &str) -> Result<String> {
        let system_msg =
            "You identify the best file for understanding a project's purpose and structure."
                .to_string();
        let user_msg = format!(
            "Here's a directory tree:\n\n{}\n\nWhich single file would be best for getting a general overview of this project?\nLook for README files, documentation, or main entry points.\n\nRespond with ONLY the file path (e.g., 'README.md' or 'docs/overview.md'), nothing else.",
            dir_tree
        );

        let overview_request = CompletionRequest {
            messages: vec![LlmMessage::system(system_msg), LlmMessage::user(user_msg)],
            model: self.config.llm.model.clone(),
            max_tokens: Some(500), // Increased to allow for reasoning tokens + actual response
            temperature: Some(0.3),
        };

        // Track this LLM call
        let call_id = self.llm_call_counter;
        self.llm_call_counter += 1;

        let response = self
            .llm_client
            .complete(overview_request.clone())
            .await
            .context("Failed to find overview file")?;

        // Emit LLM call event for initialization
        let llm_event = Event::LlmCall {
            timestamp: Utc::now(),
            call_id,
            purpose: LlmCallPurpose::Initialization,
            request: overview_request,
            response: response.clone(),
        };
        self.session.append_event(&llm_event)?;

        // Parse response - take first line, trim whitespace
        let file_path = response
            .content
            .lines()
            .next()
            .unwrap_or("")
            .trim()
            .to_string();

        // Validate path exists
        let full_path = self.session.project_dir.join(&file_path);
        if !full_path.exists() || !full_path.is_file() {
            anyhow::bail!("LLM returned invalid file path: {}", file_path);
        }

        Ok(file_path)
    }

    /// Generate a simulated initial assistant message that views the overview file.
    ///
    /// This creates the appearance that the LLM has already taken a first step
    /// by viewing a relevant overview file. The message demonstrates proper LLM
    /// behavior: reasoning about the situation, explaining the plan, and using
    /// proper tool formatting.
    ///
    /// The approach varies based on file type:
    /// - Markdown files (.md): Search for headings, then view by sections
    /// - Other text files: View paragraphs (blank line to blank line)
    /// - Empty string (no file): Fallback to ls command
    fn generate_simulated_message(file_path: &str) -> String {
        if file_path.is_empty() {
            // Case 3: No overview file - use ls as fallback
            "I can see the project structure and git status on screen. Since there's no obvious overview documentation file, let me list the directory contents to understand what we're working with:\n\n<bash>\nls -alh\n</bash>".to_string()
        } else if file_path.ends_with(".md") {
            // Case 1: Markdown file - search for headings and view by sections
            format!(
                "I can see the project structure and git status on screen. To understand what we're working with and address the task effectively, I should start by examining the overview documentation.\n\nLet me first find the structure of the markdown file by searching for section headers:\n\n<editor>\nsearch \"^#\\s\" {}\n</editor>\n\nNow let me view the sections to understand the content:\n\n<editor>\nview {} /^#\\s/ /^#\\s/\n</editor>",
                file_path, file_path
            )
        } else {
            // Case 2: Other text file - view by paragraphs (empty line to empty line)
            format!(
                "I can see the project structure and git status on screen. To understand what we're working with and address the task effectively, I should start by examining the overview documentation.\n\nLet me view the file content by paragraphs:\n\n<editor>\nview {} /^$|^/ /^$/\n</editor>",
                file_path
            )
        }
    }
}

/// Build LLM messages from events (for context)
///
/// Converts events into Message format and applies truncation
fn build_llm_messages_from_events(
    events: &[Event],
    current_screen: &ScreenState,
) -> Vec<(MessageRole, String)> {
    use crate::context::truncate_history;
    use crate::types::Message;

    const MAX_HISTORY_CHARS: usize = 400_000; // ~100k tokens

    let mut messages: Vec<Message> = Vec::new();

    for event in events {
        match event {
            Event::SystemPrompt { content, timestamp } => {
                messages.push(Message {
                    role: MessageRole::System,
                    content: content.clone(),
                    timestamp: *timestamp,
                });
            }
            Event::TaskMessage { content, timestamp } => {
                messages.push(Message {
                    role: MessageRole::User,
                    content: content.clone(),
                    timestamp: *timestamp,
                });
            }
            Event::LlmCall {
                response,
                timestamp,
                ..
            } => {
                messages.push(Message {
                    role: MessageRole::Assistant,
                    content: response.content.clone(),
                    timestamp: *timestamp,
                });
            }
            Event::CommandExecution {
                output, timestamp, ..
            } => {
                messages.push(Message {
                    role: MessageRole::User,
                    content: output.clone(),
                    timestamp: *timestamp,
                });
            }
            Event::SessionEnd { .. } => {
                // Don't include session end in context
            }
        }
    }

    // Apply truncation to history (keep most recent)
    let truncated = truncate_history(&messages, MAX_HISTORY_CHARS);

    // Add current screen
    let screen_message = crate::context::format_screen(current_screen);

    // Build final message list
    let mut result: Vec<(MessageRole, String)> = truncated
        .iter()
        .map(|m| (m.role, m.content.clone()))
        .collect();

    result.push((screen_message.role, screen_message.content));

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::{CompletionResponse, FinishReason, TokenUsage as LlmTokenUsage};
    use rust_decimal::Decimal;
    use rust_decimal_macros::dec;
    use tempfile::TempDir;

    // Mock LLM client for testing
    struct MockLlmClient {
        response: String,
    }

    #[async_trait::async_trait]
    impl LlmClient for MockLlmClient {
        async fn complete(
            &self,
            _request: CompletionRequest,
        ) -> Result<CompletionResponse, crate::llm::LlmError> {
            Ok(CompletionResponse {
                content: self.response.clone(),
                usage: LlmTokenUsage {
                    prompt_tokens: 100,
                    completion_tokens: 50,
                    total_tokens: 150,
                },
                cost: dec!(0.001),
                finish_reason: FinishReason::Stop,
            })
        }

        fn estimate_cost(
            &self,
            _request: &CompletionRequest,
        ) -> Result<Decimal, crate::llm::LlmError> {
            Ok(dec!(0.001))
        }

        fn count_tokens(&self, _message: &str) -> usize {
            100
        }
    }

    fn create_test_project() -> TempDir {
        let temp_dir = TempDir::new().unwrap();
        let base = temp_dir.path();

        // Create a simple project structure
        std::fs::write(base.join("README.md"), "# Test Project").unwrap();
        std::fs::write(base.join("main.rs"), "fn main() {}").unwrap();
        std::fs::create_dir(base.join("src")).unwrap();
        std::fs::write(base.join("src").join("lib.rs"), "// lib").unwrap();

        temp_dir
    }

    #[test]
    fn test_generate_simulated_message_markdown() {
        let message = Agent::<MockLlmClient>::generate_simulated_message("README.md");

        // Should mention the file twice (once in search, once in view)
        assert!(message.contains("README.md"), "Should mention the file");

        // Should contain two editor commands for markdown
        assert!(
            message.matches("<editor>").count() == 2,
            "Should contain two editor tags"
        );

        // Should contain search command
        assert!(message.contains("search"), "Should contain search command");
        assert!(
            message.contains("^#\\s"),
            "Should search for section headers"
        );

        // Should contain view command
        assert!(message.contains("view"), "Should contain view command");
        assert!(
            message.contains("/^#\\s/ /^#\\s/"),
            "Should use section header patterns for view"
        );

        assert!(
            message.contains("markdown file"),
            "Should mention markdown file"
        );
    }

    #[test]
    fn test_generate_simulated_message_text() {
        let message = Agent::<MockLlmClient>::generate_simulated_message("LICENSE");

        // Should mention the file
        assert!(message.contains("LICENSE"), "Should mention the file");

        // Should contain one editor command for text files
        assert!(
            message.matches("<editor>").count() == 1,
            "Should contain one editor tag"
        );

        // Should contain view command with paragraph patterns
        assert!(message.contains("view"), "Should contain view command");
        assert!(
            message.contains("/^$|^/ /^$/"),
            "Should use paragraph patterns for view"
        );

        assert!(
            message.contains("paragraphs"),
            "Should mention viewing by paragraphs"
        );
    }

    #[test]
    fn test_generate_simulated_message_no_file() {
        let message = Agent::<MockLlmClient>::generate_simulated_message("");

        // Should contain bash command
        assert!(
            message.matches("<bash>").count() == 1,
            "Should contain one bash tag"
        );

        // Should contain ls command
        assert!(message.contains("ls -alh"), "Should contain ls command");

        assert!(
            message.contains("no obvious overview"),
            "Should mention lack of overview file"
        );
    }

    #[test]
    fn test_build_directory_tree_basic() {
        let temp_dir = create_test_project();
        let tree = build_directory_tree(temp_dir.path(), 100).unwrap();

        println!("Tree output:\n{}", tree);

        // Should contain files
        assert!(tree.contains("README.md"), "Tree should contain README.md");
        assert!(tree.contains("main.rs"), "Tree should contain main.rs");
        assert!(tree.contains("src/"), "Tree should contain src/ directory");
    }

    #[test]
    fn test_build_tree_at_depth_1() {
        let temp_dir = create_test_project();
        let result = build_tree_at_depth(temp_dir.path(), 1).unwrap();

        // At depth 1, should see top-level files and directories
        assert!(result.content.contains("README.md"));
        assert!(result.content.contains("main.rs"));
        assert!(result.content.contains("src/"));

        // Should NOT see files inside src/ at depth 1
        assert!(!result.content.contains("src/lib.rs"));
    }

    #[test]
    fn test_build_tree_at_depth_2() {
        let temp_dir = create_test_project();
        let result = build_tree_at_depth(temp_dir.path(), 2).unwrap();

        // At depth 2, should see files inside src/
        assert!(result.content.contains("src/lib.rs"));
    }
}
