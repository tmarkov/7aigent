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
use std::io::{self, Write};

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

    /// Run the main agent loop until task completion or error
    pub async fn run(&mut self) -> Result<()> {
        println!("Starting task: {}", self.session.task);
        println!();

        // On first run, save system prompt and task to history
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

            self.session.save_step(
                &system_prompt,
                &ScreenState {
                    step: 0,
                    timestamp: chrono::Utc::now(),
                    sections: std::collections::HashMap::new(),
                },
            )?;
            self.session.save_step(
                &task_message,
                &ScreenState {
                    step: 0,
                    timestamp: chrono::Utc::now(),
                    sections: std::collections::HashMap::new(),
                },
            )?;
        }

        loop {
            // Get current screen state (last one in history, or empty)
            let current_screen = self.screens.last().cloned().unwrap_or_else(|| ScreenState {
                step: 0,
                timestamp: chrono::Utc::now(),
                sections: std::collections::HashMap::new(),
            });

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
                    &ScreenState {
                        step: self.session.step_count,
                        timestamp: chrono::Utc::now(),
                        sections: std::collections::HashMap::new(),
                    },
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
}
