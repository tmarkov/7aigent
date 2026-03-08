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
use crate::initial_messages::load_initial_messages;
use crate::llm::{CompletionRequest, LlmClient, LlmMessage};
use crate::parser::parse_commands;
use crate::types::{
    Event, LlmCallPurpose, MessageRole, ScreenState, SessionMetadata, SessionStatus,
};
use anyhow::{Context, Result};
use chrono::Utc;
use std::collections::HashMap;
use std::io::{self, Write as IoWrite};
use std::path::{Path, PathBuf};

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

    /// Receive response from container, handling any auxiliary requests that arrive first
    async fn receive_with_aux_handling(
        &mut self,
    ) -> Result<(crate::types::CommandResponse, ScreenState)> {
        use crate::container::OrchestratorMessage;

        loop {
            let message = self
                .container
                .receive_message()
                .context("Failed to receive message from orchestrator")?;

            match message {
                OrchestratorMessage::CommandResponse(response, screen) => {
                    return Ok((response, screen));
                }
                OrchestratorMessage::AuxiliaryLlmRequest(request) => {
                    let request_id = request.request_id.clone();
                    let result = self.handle_auxiliary_request(request).await;
                    self.container
                        .send_auxiliary_response(&request_id, result)
                        .context("Failed to send auxiliary response")?;
                    // Continue loop to wait for actual command response
                }
            }
        }
    }

    /// Handle an auxiliary LLM request from the orchestrator
    async fn handle_auxiliary_request(
        &mut self,
        request: crate::container::AuxiliaryLlmRequest,
    ) -> std::result::Result<String, String> {
        use crate::llm::LlmMessage;

        println!(
            "[Auxiliary LLM Query] request_id={}, prompt_len={}",
            request.request_id,
            request.prompt.len()
        );

        // Build auxiliary LLM request with special system message
        let mut messages = vec![LlmMessage::system(
            "You specialize in providing concise summaries and explanations. \
             When provided one or a few larger snippets of code or text, provide a summary of each \
             and explain how they relate to each other. When provided multiple smaller snippets, \
             focus on identifying common threads and patterns between them. Be clear and concise."
                .to_string(),
        )];

        // Add context if provided
        let user_content = if let Some(ctx) = &request.context {
            format!("{}\n\nContext:\n{}", request.prompt, ctx)
        } else {
            request.prompt.clone()
        };

        messages.push(LlmMessage::user(user_content));

        // Create LLM request
        let llm_request = crate::llm::CompletionRequest {
            messages,
            model: self.config.llm.model.clone(),
            max_tokens: Some(5000), // Limit auxiliary responses
            temperature: self.config.llm.temperature,
        };

        // Call LLM
        let llm_response = match self.llm_client.complete(llm_request.clone()).await {
            Ok(resp) => resp,
            Err(e) => {
                eprintln!("[Auxiliary LLM Query] Error: {}", e);
                return Err(format!("LLM error: {}", e));
            }
        };

        // Log event
        let event = Event::AuxiliaryLlmQuery {
            timestamp: Utc::now(),
            request_id: request.request_id.clone(),
            prompt: request.prompt,
            context: request.context,
            request: llm_request,
            response: llm_response.clone(),
        };

        if let Err(e) = self.session.append_event(&event) {
            eprintln!("[Auxiliary LLM Query] Failed to log event: {}", e);
        }

        println!(
            "[Auxiliary LLM Query] Complete. tokens={} cost=${:.4}",
            llm_response.usage.total_tokens, llm_response.cost
        );

        Ok(llm_response.content)
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
            let system_prompt_content = crate::context::build_system_prompt(
                &self.config,
                &self.config.sandbox,
                &self.session.project_dir,
            )
            .content;
            let task_content =
                crate::context::format_task(&self.session.task, &self.session.project_dir).content;

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

            // Load and execute initial messages from config if available
            let init_file_path = self.get_initial_messages_path();

            if let Some(path) = init_file_path {
                if path.exists() {
                    println!(
                        "[Initialization] Loading initial messages from: {}",
                        path.display()
                    );

                    let messages =
                        load_initial_messages(&path).context("Failed to load initial messages")?;

                    if messages.is_empty() {
                        println!("  No messages found in file");
                    } else {
                        println!("  Loaded {} initial message(s)", messages.len());
                        println!();

                        // Execute each simulated message
                        for (msg_idx, simulated_content) in messages.iter().enumerate() {
                            // Print simulated message (not saved as event - it's just for display)
                            println!("=== ASSISTANT (Initial {}) ===", msg_idx + 1);
                            println!("{}", simulated_content);
                            println!();

                            // Parse commands from simulated message (same as regular LLM responses)
                            let commands = parse_commands(simulated_content)
                                .context("Failed to parse simulated message")?;

                            // Execute each command (same as main loop)
                            for (idx, cmd) in commands.iter().enumerate() {
                                println!("  [{}] Executing {} command...", idx + 1, cmd.env);

                                self.container
                                    .send_command(&cmd.env, &cmd.command)
                                    .context("Failed to send command to orchestrator")?;

                                let (cmd_response, mut screen_state) =
                                    self.receive_with_aux_handling().await?;

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
                                    processed: cmd_response.processed,
                                    exit_code: cmd_response.exit_code,
                                    screen: screen_state,
                                };
                                self.session.append_event(&cmd_event)?;
                            }

                            println!();
                        }
                    }
                } else {
                    println!(
                        "[Initialization] Initial messages file not found: {}",
                        path.display()
                    );
                }
            } else {
                println!("[Initialization] No initial messages configured");
            }

            println!("[Initialization] Complete. Starting main loop...");
            println!();
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
            let messages =
                build_llm_messages_from_events(&events, &current_screen, &self.session.project_dir);

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

                let (cmd_response, mut screen_state) = self.receive_with_aux_handling().await?;

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
                    processed: cmd_response.processed,
                    exit_code: cmd_response.exit_code,
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

    /// Get the path to the initial messages file based on configuration.
    ///
    /// Returns the path if configured or if default file exists, None otherwise.
    fn get_initial_messages_path(&self) -> Option<PathBuf> {
        // If explicitly configured, use that path
        if let Some(ref path) = self.config.behavior.initial_messages {
            // If relative path, resolve relative to project directory
            if path.is_relative() {
                return Some(self.session.project_dir.join(path));
            } else {
                return Some(path.clone());
            }
        }

        // Otherwise, check for default .7aigent/init.md in project directory
        let default_path = self.session.project_dir.join(".7aigent").join("init.md");
        if default_path.exists() {
            Some(default_path)
        } else {
            None
        }
    }
}

/// Build LLM messages from events (for context)
///
/// Converts events into Message format and applies truncation
fn build_llm_messages_from_events(
    events: &[Event],
    current_screen: &ScreenState,
    project_dir: &Path,
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
                environment,
                command,
                output,
                exit_code,
                processed,
                timestamp,
                ..
            } => {
                let formatted = crate::context::format_command_output(
                    environment,
                    command,
                    output,
                    *exit_code,
                    *processed,
                    project_dir,
                );
                messages.push(Message {
                    role: MessageRole::User,
                    content: formatted.content,
                    timestamp: *timestamp,
                });
            }
            Event::SessionEnd { .. } => {
                // Don't include session end in context
            }
            Event::AuxiliaryLlmQuery { .. } => {
                // Don't include auxiliary queries in main conversation context
            }
        }
    }

    // Apply truncation to history (keep most recent)
    let truncated = truncate_history(&messages, MAX_HISTORY_CHARS);

    // Add current screen
    let screen_message = crate::context::format_screen(current_screen, project_dir);

    // Build final message list
    let mut result: Vec<(MessageRole, String)> = truncated
        .iter()
        .map(|m| (m.role, m.content.clone()))
        .collect();

    result.push((screen_message.role, screen_message.content));

    result
}
