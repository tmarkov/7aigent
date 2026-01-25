//! Main agent loop for 7aigent.
//!
//! This module implements the core agent that:
//! - Loads configuration and manages sessions
//! - Calls LLM with context and budget checking
//! - Parses LLM responses for commands
//! - Executes commands via the containerized orchestrator
//! - Persists conversation history and screen states

use crate::budget::{check_budget, BudgetCheckResult};
use crate::config::Config;
use crate::container::ContainerHandle;
use crate::context::build_llm_messages;
use crate::llm::{CompletionRequest, LlmClient, LlmMessage};
use crate::parser::parse_commands;
use crate::types::{Message, MessageRole, ScreenState, Session, SessionStatus};
use anyhow::{Context, Result};
use ignore::WalkBuilder;
use std::io::{self, Write};
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
    session: Session,
    /// Agent configuration
    config: Config,
    /// Container handle for orchestrator communication
    container: ContainerHandle,
    /// LLM client
    llm_client: C,
    /// Conversation history (loaded from session)
    history: Vec<Message>,
    /// Screen state history (loaded from session)
    screens: Vec<ScreenState>,
}

impl<C: LlmClient> Agent<C> {
    /// Create a new agent
    pub fn new(
        session: Session,
        config: Config,
        container: ContainerHandle,
        llm_client: C,
    ) -> Result<Self> {
        // Load history and screens from session
        let history = session.load_history()?;
        let screens = session.load_screens()?;

        Ok(Self {
            session,
            config,
            container,
            llm_client,
            history,
            screens,
        })
    }

    /// Create an empty screen state with the given step number
    fn create_empty_screen(step: usize) -> ScreenState {
        ScreenState {
            step,
            timestamp: chrono::Utc::now(),
            sections: std::collections::HashMap::new(),
        }
    }

    /// Run the main agent loop until task completion or error
    pub async fn run(&mut self) -> Result<()> {
        println!("Starting task: {}", self.session.task);
        println!();

        // On first run, save system prompt and task to history, then execute simulated initial message
        if self.history.is_empty() {
            let system_prompt =
                crate::context::build_system_prompt(&self.config, &self.config.sandbox);
            let task_message = Message::user(self.session.task.clone());

            // Print system message
            println!("=== SYSTEM ===");
            println!("{}", system_prompt.content);
            println!();

            // Print task message
            println!("=== TASK ===");
            println!("{}", task_message.content);
            println!();

            // Save to history
            self.history.push(system_prompt.clone());
            self.history.push(task_message.clone());

            self.session
                .save_step(&system_prompt, &Self::create_empty_screen(0))?;
            self.session
                .save_step(&task_message, &Self::create_empty_screen(0))?;

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
                let simulated_message = Message::assistant(simulated_content.clone());

                // Print simulated message
                println!("=== ASSISTANT (Initial) ===");
                println!("{}", simulated_content);
                println!();

                // Save simulated message to history
                self.history.push(simulated_message.clone());
                self.session
                    .save_step(&simulated_message, &Self::create_empty_screen(0))?;

                // Execute the editor view command
                println!("  [1] Executing editor command...");
                self.container
                    .send_command("editor", &format!("view {}", overview_file))
                    .context("Failed to send initial view command")?;

                let (cmd_response, screen_state) = self
                    .container
                    .receive_response()
                    .context("Failed to receive initial view response")?;

                // Print command output
                println!();
                println!("=== ORCHESTRATOR ===");
                println!("{}", cmd_response.output);
                println!();

                // Store command output as user message
                let user_message = Message::user(cmd_response.output);
                self.history.push(user_message.clone());

                // Store screen state
                self.screens.push(screen_state.clone());

                // Save step (message + screen)
                self.session
                    .save_step(&user_message, &screen_state)
                    .context("Failed to save initial view step")?;

                println!("[Initialization] Complete. Starting main loop...");
                println!();
            }
        }

        loop {
            // Get current screen state (last one in history, or empty)
            let current_screen = self
                .screens
                .last()
                .cloned()
                .unwrap_or_else(|| Self::create_empty_screen(0));

            // Build LLM context
            let messages = self.build_context(&current_screen);

            // Convert to LLM messages
            let llm_messages: Vec<LlmMessage> = messages
                .iter()
                .map(|m| match m.role {
                    MessageRole::System => LlmMessage::system(m.content.clone()),
                    MessageRole::User => LlmMessage::user(m.content.clone()),
                    MessageRole::Assistant => LlmMessage::assistant(m.content.clone()),
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

            match check_budget(&self.session, estimated_cost, &self.config.budget) {
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

                    if !confirm_continue()? {
                        println!("Session paused by user.");
                        self.session.status = SessionStatus::Paused;
                        self.session
                            .save_metadata()
                            .context("Failed to save session")?;
                        return Ok(());
                    }
                }
                BudgetCheckResult::ExceedsPerCall { estimated, limit } => {
                    eprintln!(
                        "ERROR: Estimated cost ${:.2} exceeds per-call limit of ${:.2}",
                        estimated, limit
                    );
                    eprintln!("Cannot proceed. Consider increasing budget.max_cost_per_call.");
                    self.session.status = SessionStatus::Failed;
                    self.session
                        .save_metadata()
                        .context("Failed to save session")?;
                    anyhow::bail!("Budget per-call limit exceeded");
                }
                BudgetCheckResult::ExceedsSession {
                    current,
                    estimated,
                    limit,
                } => {
                    eprintln!(
                        "ERROR: Current total ${:.2} + estimated ${:.2} exceeds session limit of ${:.2}",
                        current, estimated, limit
                    );
                    eprintln!("Cannot proceed. Consider increasing budget.max_cost_per_session.");
                    self.session.status = SessionStatus::Failed;
                    self.session
                        .save_metadata()
                        .context("Failed to save session")?;
                    anyhow::bail!("Budget session limit exceeded");
                }
            }

            // Call LLM
            println!("[Step {}] Calling LLM...", self.session.step_count + 1);
            let response = self
                .llm_client
                .complete(request)
                .await
                .context("LLM call failed")?;

            println!("  Cost: ${:.4}", response.cost);

            // Update session cost and token usage
            self.session.total_cost += response.cost;
            self.session.token_usage.prompt_tokens += response.usage.prompt_tokens as usize;
            self.session.token_usage.completion_tokens += response.usage.completion_tokens as usize;
            self.session.token_usage.total_tokens += response.usage.total_tokens as usize;
            self.session.step_count += 1;

            // Print LLM response
            println!();
            println!("=== ASSISTANT ===");
            println!("{}", response.content);
            println!();

            // Store assistant response in history
            let assistant_message = Message::assistant(response.content.clone());
            self.history.push(assistant_message.clone());

            // Save assistant message to history.jsonl (with empty screen since no command executed yet)
            self.session
                .save_step(
                    &assistant_message,
                    &Self::create_empty_screen(self.session.step_count),
                )
                .context("Failed to save assistant message")?;

            // Parse commands from response
            let commands = parse_commands(&response.content).context("Failed to parse commands")?;

            if commands.is_empty() {
                // No commands means agent is done
                println!();
                println!("✓ Task completed!");
                println!();
                println!("Summary:");
                println!("  Total steps: {}", self.session.step_count);
                println!("  Total cost: ${:.4}", self.session.total_cost);
                println!(
                    "  Total tokens: {} prompt + {} completion = {} total",
                    self.session.token_usage.prompt_tokens,
                    self.session.token_usage.completion_tokens,
                    self.session.token_usage.total_tokens
                );
                println!();

                self.session.status = SessionStatus::Completed;
                self.session
                    .save_metadata()
                    .context("Failed to save session")?;
                break;
            }

            // Execute each command
            for (idx, cmd) in commands.iter().enumerate() {
                println!("  [{}] Executing {} command...", idx + 1, cmd.env);

                self.container
                    .send_command(&cmd.env, &cmd.command)
                    .context("Failed to send command to orchestrator")?;

                let (cmd_response, screen_state) = self
                    .container
                    .receive_response()
                    .context("Failed to receive response from orchestrator")?;

                // Print command output
                println!();
                println!("=== ORCHESTRATOR ===");
                println!("{}", cmd_response.output);
                println!();

                // Store command output as user message
                let user_message = Message::user(cmd_response.output);
                self.history.push(user_message.clone());

                // Store screen state
                self.screens.push(screen_state.clone());

                // Save step (message + screen)
                self.session
                    .save_step(&user_message, &screen_state)
                    .context("Failed to save step")?;
            }

            println!("  Session total: ${:.4}", self.session.total_cost);
            println!();
        }

        Ok(())
    }

    /// Build LLM message context from session state
    fn build_context(&self, current_screen: &ScreenState) -> Vec<Message> {
        build_llm_messages(
            &self.config,
            &self.config.sandbox,
            &self.session.task,
            &self.history,
            current_screen,
        )
    }

    /// Get the current session (useful for inspecting state after run)
    pub fn session(&self) -> &Session {
        &self.session
    }

    /// Ask LLM to identify the best file for project overview given a directory tree.
    async fn find_overview_file(&self, dir_tree: &str) -> Result<String> {
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

        let response = self
            .llm_client
            .complete(overview_request)
            .await
            .context("Failed to find overview file")?;

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
    /// by viewing a relevant overview file.
    fn generate_simulated_message(file_path: &str) -> String {
        format!(
            "I can see the project structure and git status on screen. Let me start by viewing the overview documentation.\n\n```editor\nview {}\n```",
            file_path
        )
    }
}

/// Prompt user to confirm continuing despite budget warning
fn confirm_continue() -> Result<bool> {
    print!("Continue? [y/n]: ");
    io::stdout().flush()?;

    let mut input = String::new();
    io::stdin().read_line(&mut input)?;

    Ok(input.trim().eq_ignore_ascii_case("y") || input.trim().eq_ignore_ascii_case("yes"))
}

#[cfg(test)]
#[allow(dead_code)]
mod tests {
    use super::*;
    use crate::config::{BehaviorConfig, BudgetConfig, LlmConfig, SandboxConfig, TokenPricing};
    use crate::llm::{CompletionResponse, FinishReason, LlmError, TokenUsage as LlmTokenUsage};
    use crate::types::{LlmConfigSnapshot, SessionId, TokenUsage};
    use async_trait::async_trait;
    use chrono::Utc;
    use rust_decimal::Decimal;
    use std::collections::HashMap;
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};

    /// Mock LLM client for testing
    struct MockLlmClient {
        responses: Arc<Mutex<Vec<String>>>,
        call_count: Arc<Mutex<usize>>,
    }

    impl MockLlmClient {
        fn new(responses: Vec<String>) -> Self {
            Self {
                responses: Arc::new(Mutex::new(responses)),
                call_count: Arc::new(Mutex::new(0)),
            }
        }
    }

    #[async_trait]
    impl LlmClient for MockLlmClient {
        async fn complete(
            &self,
            _request: CompletionRequest,
        ) -> Result<CompletionResponse, LlmError> {
            let mut count = self.call_count.lock().unwrap();
            let responses = self.responses.lock().unwrap();

            if *count >= responses.len() {
                return Err(LlmError::Other("No more responses".to_string()));
            }

            let content = responses[*count].clone();
            *count += 1;

            Ok(CompletionResponse {
                content,
                usage: LlmTokenUsage::new(100, 50),
                cost: Decimal::new(1, 2), // $0.01
                finish_reason: FinishReason::Stop,
            })
        }

        fn estimate_cost(&self, _request: &CompletionRequest) -> Result<Decimal, LlmError> {
            Ok(Decimal::new(1, 2)) // $0.01
        }

        fn count_tokens(&self, message: &str) -> usize {
            message.len() / 4
        }
    }

    fn create_test_config() -> Config {
        let mut pricing = HashMap::new();
        pricing.insert(
            "test-model".to_string(),
            TokenPricing::new(Decimal::new(1, 3), Decimal::new(2, 3)),
        );

        Config {
            llm: LlmConfig {
                endpoint: "https://api.example.com".to_string(),
                model: "test-model".to_string(),
                api_key_env: None,
                temperature: Some(0.7),
                max_tokens: Some(2000),
                system_prompt_suffix: None,
                pricing,
            },
            sandbox: SandboxConfig::default(),
            budget: BudgetConfig {
                max_cost_per_session: Some(Decimal::new(100, 2)), // $1.00
                max_cost_per_call: Some(Decimal::new(10, 2)),     // $0.10
                warn_threshold: Decimal::new(80, 2),              // 0.80
            },
            behavior: BehaviorConfig::default(),
        }
    }

    fn create_test_session() -> Session {
        Session {
            id: SessionId::new(),
            project_dir: PathBuf::from("/test"),
            task: "Test task".to_string(),
            created_at: Utc::now(),
            updated_at: Utc::now(),
            status: SessionStatus::Active,
            total_cost: Decimal::ZERO,
            token_usage: TokenUsage::default(),
            step_count: 0,
            llm_config: Some(LlmConfigSnapshot {
                endpoint: "https://api.example.com".to_string(),
                model: "test-model".to_string(),
            }),
        }
    }

    #[test]
    fn test_budget_check_result_formatting() {
        // This test just ensures the types compile and can be constructed
        let result = BudgetCheckResult::Ok;
        assert_eq!(result, BudgetCheckResult::Ok);

        let result = BudgetCheckResult::WarningThreshold {
            projected: Decimal::new(90, 2),
            limit: Decimal::new(100, 2),
        };
        match result {
            BudgetCheckResult::WarningThreshold { projected, limit } => {
                assert_eq!(projected, Decimal::new(90, 2));
                assert_eq!(limit, Decimal::new(100, 2));
            }
            _ => panic!("Wrong variant"),
        }
    }

    // Note: Full integration tests would require mocking ContainerHandle
    // which is complex. For now, we verify the types compile and basic logic works.

    // Tests for directory tree building
    use std::fs;
    use tempfile::TempDir;

    fn create_test_project() -> TempDir {
        let temp_dir = TempDir::new().unwrap();
        let base = temp_dir.path();

        // Create a simple project structure
        fs::write(base.join("README.md"), "# Test Project").unwrap();
        fs::write(base.join("main.rs"), "fn main() {}").unwrap();
        fs::create_dir(base.join("src")).unwrap();
        fs::write(base.join("src").join("lib.rs"), "// lib").unwrap();
        fs::write(base.join("src").join("utils.rs"), "// utils").unwrap();

        temp_dir
    }

    // Helper to create test session
    fn create_test_session_with_dir(project_dir: PathBuf) -> Session {
        Session {
            id: SessionId::new(),
            project_dir,
            task: "Test task".to_string(),
            created_at: Utc::now(),
            updated_at: Utc::now(),
            status: SessionStatus::Active,
            total_cost: Decimal::ZERO,
            token_usage: TokenUsage::default(),
            step_count: 0,
            llm_config: Some(LlmConfigSnapshot {
                endpoint: "https://api.example.com".to_string(),
                model: "test-model".to_string(),
            }),
        }
    }

    #[test]
    fn test_generate_simulated_message() {
        let message = Agent::<MockLlmClient>::generate_simulated_message("README.md");

        assert!(message.contains("README.md"), "Should mention the file");
        assert!(
            message.contains("```editor"),
            "Should contain editor code block"
        );
        assert!(message.contains("view"), "Should use view command");
    }

    #[test]
    fn test_build_directory_tree_basic() {
        let temp_dir = create_test_project();
        let tree = build_directory_tree(temp_dir.path(), 100).unwrap();

        println!("Tree output:\n{}", tree);

        // Should contain files at depth 1
        assert!(tree.contains("README.md"), "Tree should contain README.md");
        assert!(tree.contains("main.rs"), "Tree should contain main.rs");
        assert!(tree.contains("src/"), "Tree should contain src/ directory");
    }

    #[test]
    fn test_build_tree_at_depth_1() {
        let temp_dir = create_test_project();
        let result = build_tree_at_depth(temp_dir.path(), 1).unwrap();

        println!("Depth 1 tree:\n{}", result.content);
        println!("File count: {}", result.file_count);

        // At depth 1, should see top-level files and directories
        assert!(result.content.contains("README.md"));
        assert!(result.content.contains("main.rs"));
        assert!(result.content.contains("src/"));

        // Should NOT see files inside src/ at depth 1
        assert!(!result.content.contains("src/lib.rs"));
        assert!(!result.content.contains("src/utils.rs"));
    }

    #[test]
    fn test_build_tree_at_depth_2() {
        let temp_dir = create_test_project();
        let result = build_tree_at_depth(temp_dir.path(), 2).unwrap();

        println!("Depth 2 tree:\n{}", result.content);
        println!("File count: {}", result.file_count);

        // At depth 2, should see files inside src/
        assert!(result.content.contains("src/lib.rs"));
        assert!(result.content.contains("src/utils.rs"));
    }

    #[test]
    fn test_build_tree_counts_only_files() {
        let temp_dir = TempDir::new().unwrap();
        let base = temp_dir.path();

        // Create 3 files and 2 directories
        fs::write(base.join("file1.txt"), "").unwrap();
        fs::write(base.join("file2.txt"), "").unwrap();
        fs::write(base.join("file3.txt"), "").unwrap();
        fs::create_dir(base.join("dir1")).unwrap();
        fs::create_dir(base.join("dir2")).unwrap();

        let result = build_tree_at_depth(base, 1).unwrap();

        println!("Content:\n{}", result.content);
        println!("File count: {}", result.file_count);

        // Should count only files, not directories
        assert_eq!(
            result.file_count, 3,
            "Should count only 3 files, not the 2 directories"
        );
    }

    #[test]
    fn test_adaptive_depth_stops_at_file_limit() {
        let temp_dir = TempDir::new().unwrap();
        let base = temp_dir.path();

        // Create directory structure that will exceed 10 files at depth 2
        fs::create_dir(base.join("dir1")).unwrap();
        fs::create_dir(base.join("dir2")).unwrap();

        // 5 files in each directory = 10 files total at depth 2
        for i in 0..5 {
            fs::write(base.join("dir1").join(format!("file{}.txt", i)), "").unwrap();
            fs::write(base.join("dir2").join(format!("file{}.txt", i)), "").unwrap();
        }

        // Add 2 more files at root
        fs::write(base.join("root1.txt"), "").unwrap();
        fs::write(base.join("root2.txt"), "").unwrap();

        // With limit of 5, should stop at depth 1 (only 2 files)
        let tree = build_directory_tree(base, 5).unwrap();

        println!("Tree with limit 5:\n{}", tree);

        // Should not include deep files since that would exceed limit
        let file_count = tree.lines().filter(|line| !line.ends_with('/')).count();
        println!("File count in output: {}", file_count);

        assert!(
            file_count <= 2,
            "With limit 5 and 12 files total, should stop at depth 1 (2 files)"
        );
    }

    #[test]
    fn test_minimum_depth_guarantee() {
        let temp_dir = TempDir::new().unwrap();
        let base = temp_dir.path();

        // Create MORE than 100 files at depth 1
        for i in 0..150 {
            fs::write(base.join(format!("file{}.txt", i)), "content").unwrap();
        }

        // Even with limit of 100, should still show depth 1
        let tree = build_directory_tree(base, 100).unwrap();

        let file_count = tree.lines().filter(|line| !line.ends_with('/')).count();

        println!("Created 150 files, got {} in output", file_count);

        // Should show all 150 files from depth 1, despite limit being 100
        assert_eq!(
            file_count, 150,
            "Should show all depth 1 files even when exceeding limit"
        );
    }

    #[test]
    fn test_tree_with_gitignore() {
        let temp_dir = TempDir::new().unwrap();
        let base = temp_dir.path();

        // Create files
        fs::write(base.join("README.md"), "# Test").unwrap();
        fs::write(base.join("main.rs"), "fn main() {}").unwrap();
        fs::write(base.join("ignored.txt"), "ignored").unwrap();

        // Create .gitignore that ignores ignored.txt
        fs::write(base.join(".gitignore"), "ignored.txt\n").unwrap();

        let tree = build_directory_tree(base, 100).unwrap();

        println!("Tree with .gitignore:\n{}", tree);

        // Should respect .gitignore
        assert!(tree.contains("README.md"), "Should contain README.md");
        assert!(tree.contains("main.rs"), "Should contain main.rs");
        assert!(
            !tree.contains("ignored.txt"),
            "Should NOT contain ignored.txt (it's in .gitignore)"
        );
    }

    #[test]
    fn test_tree_output_format() {
        let temp_dir = create_test_project();
        let tree = build_directory_tree(temp_dir.path(), 100).unwrap();

        println!("=== ACTUAL TREE OUTPUT ===");
        println!("{}", tree);
        println!("=== END TREE OUTPUT ===");
        println!("Tree length: {} bytes", tree.len());
        println!("Line count: {}", tree.lines().count());

        // If tree is empty, this is the problem!
        assert!(!tree.is_empty(), "Tree should not be empty!");
        assert!(tree.lines().count() > 0, "Tree should have lines!");
    }

    #[test]
    fn test_tree_in_git_repo() {
        let temp_dir = TempDir::new().unwrap();
        let base = temp_dir.path();

        // Initialize a git repo (skip test if git not available)
        let git_init = std::process::Command::new("git")
            .args(["init"])
            .current_dir(base)
            .output();

        if git_init.is_err() {
            eprintln!("Skipping test_tree_in_git_repo: git not available");
            return;
        }

        // Create files
        fs::write(base.join("README.md"), "# Test").unwrap();
        fs::write(base.join("main.rs"), "fn main() {}").unwrap();

        // Create .gitignore
        fs::write(base.join(".gitignore"), "*.log\n").unwrap();

        let tree = build_directory_tree(base, 100).unwrap();

        println!("Tree in git repo:\n{}", tree);
        println!("Tree length: {}", tree.len());

        assert!(
            !tree.is_empty(),
            "Tree should not be empty even in git repo!"
        );
        assert!(tree.contains("README.md"), "Should contain README.md");
    }

    #[test]
    fn test_empty_directory_tree() {
        let temp_dir = TempDir::new().unwrap();
        let base = temp_dir.path();

        // Empty directory
        let tree = build_directory_tree(base, 100).unwrap();

        println!("Empty directory tree:");
        println!("'{}'", tree);
        println!("Length: {}", tree.len());

        // Empty dir should return empty string
        assert_eq!(tree, "", "Empty directory should produce empty tree");
    }

    #[test]
    fn test_tree_excludes_7aigent_directory() {
        let temp_dir = TempDir::new().unwrap();
        let base = temp_dir.path();

        // Create project files
        fs::write(base.join("README.md"), "# Test").unwrap();
        fs::write(base.join("main.rs"), "fn main() {}").unwrap();

        // Create .7aigent directory with session files (should be excluded)
        fs::create_dir(base.join(".7aigent")).unwrap();
        fs::write(base.join(".7aigent").join("config.toml"), "config").unwrap();
        fs::create_dir(base.join(".7aigent").join("sessions")).unwrap();
        fs::create_dir(base.join(".7aigent").join("sessions").join("abc123")).unwrap();
        fs::write(
            base.join(".7aigent")
                .join("sessions")
                .join("abc123")
                .join("history.jsonl"),
            "history",
        )
        .unwrap();

        let tree = build_directory_tree(base, 100).unwrap();

        println!("Tree excluding .7aigent:\n{}", tree);

        // Should contain project files
        assert!(tree.contains("README.md"), "Should contain README.md");
        assert!(tree.contains("main.rs"), "Should contain main.rs");

        // Should NOT contain .7aigent or any of its contents
        assert!(
            !tree.contains(".7aigent"),
            "Should NOT contain .7aigent directory"
        );
        assert!(
            !tree.contains("config.toml"),
            "Should NOT contain .7aigent/config.toml"
        );
        assert!(
            !tree.contains("sessions"),
            "Should NOT contain .7aigent/sessions"
        );
        assert!(
            !tree.contains("history.jsonl"),
            "Should NOT contain session files"
        );
    }
}
