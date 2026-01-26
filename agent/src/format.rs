//! Formatting functions for displaying session events and metadata.
//!
//! This module provides a single source of truth for formatting session information,
//! used by both runtime display (during agent execution) and the inspect command.

use crate::types::{Event, LlmCallPurpose, SessionMetadata};
use chrono::{DateTime, Utc};

/// Display mode for formatting events
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayMode {
    /// Runtime display during agent execution
    Runtime,
    /// Inspect command display (includes timestamps)
    Inspect,
    /// Raw JSON dump
    Raw,
}

/// Format an event for display
pub fn format_event(event: &Event, mode: DisplayMode) -> String {
    format_event_with_context(event, mode, false)
}

/// Format an event for display with optional context (prompt messages)
pub fn format_event_with_context(event: &Event, mode: DisplayMode, show_context: bool) -> String {
    match mode {
        DisplayMode::Raw => {
            // Raw JSON output
            serde_json::to_string_pretty(event).unwrap_or_else(|e| format!("Error: {}", e))
        }
        DisplayMode::Runtime | DisplayMode::Inspect => {
            format_event_pretty(event, mode == DisplayMode::Inspect, show_context)
        }
    }
}

/// Format an event in pretty (human-readable) mode
fn format_event_pretty(event: &Event, include_timestamp: bool, show_context: bool) -> String {
    match event {
        Event::SystemPrompt { timestamp, content } => {
            let header = if include_timestamp {
                format!("=== SYSTEM === ({})", format_timestamp(timestamp))
            } else {
                "=== SYSTEM ===".to_string()
            };
            format!("{}\n{}\n", header, content)
        }
        Event::TaskMessage { timestamp, content } => {
            let header = if include_timestamp {
                format!("=== TASK === ({})", format_timestamp(timestamp))
            } else {
                "=== TASK ===".to_string()
            };
            format!("{}\n{}\n", header, content)
        }
        Event::LlmCall {
            timestamp,
            call_id,
            purpose,
            request,
            response,
        } => {
            let purpose_str = match purpose {
                LlmCallPurpose::Initialization => " (Initialization)",
                LlmCallPurpose::MainLoop => "",
            };

            let call_header = if include_timestamp {
                format!(
                    "[LLM Call {}{}] {} - Cost: ${:.4}",
                    call_id,
                    purpose_str,
                    format_timestamp(timestamp),
                    response.cost
                )
            } else {
                format!(
                    "[LLM Call {}{}] Cost: ${:.4}",
                    call_id, purpose_str, response.cost
                )
            };

            if show_context {
                // Format with context (prompt messages)
                let mut output = format!("{}\n\n", call_header);

                // Add model info
                output.push_str("=== MODEL INFO ===\n");
                output.push_str(&format!("Model: {}\n", request.model));
                if let Some(max_tokens) = request.max_tokens {
                    output.push_str(&format!("Max tokens: {}\n", max_tokens));
                }
                if let Some(temperature) = request.temperature {
                    output.push_str(&format!("Temperature: {}\n", temperature));
                }

                // Add prompt messages
                output.push_str(&format!(
                    "\n=== PROMPT ({} messages) ===\n",
                    request.messages.len()
                ));
                for (idx, msg) in request.messages.iter().enumerate() {
                    output.push_str(&format!("\n[{}] {} ---\n", idx, msg.role.to_uppercase()));
                    output.push_str(&msg.content);
                    output.push('\n');
                }

                // Add response
                output.push_str(&format!("\n=== RESPONSE ===\n{}\n", response.content));
                output
            } else {
                // Default: just show assistant response
                format!(
                    "{}\n\n=== ASSISTANT ===\n{}\n",
                    call_header, response.content
                )
            }
        }
        Event::CommandExecution {
            timestamp,
            environment,
            output,
            ..
        } => {
            let header = if include_timestamp {
                format!(
                    "=== ORCHESTRATOR ({}) === ({})",
                    environment,
                    format_timestamp(timestamp)
                )
            } else {
                format!("=== ORCHESTRATOR ({}) ===", environment)
            };
            format!("{}\n{}\n", header, output)
        }
        Event::SessionEnd {
            timestamp,
            status,
            reason,
        } => {
            let header = if include_timestamp {
                format!("=== SESSION END === ({})", format_timestamp(timestamp))
            } else {
                "=== SESSION END ===".to_string()
            };
            let status_str = format!("Status: {:?}", status);
            let reason_str = reason
                .as_ref()
                .map(|r| format!("\nReason: {}", r))
                .unwrap_or_default();
            format!("{}\n{}{}\n", header, status_str, reason_str)
        }
    }
}

/// Format a timestamp in a human-readable way
fn format_timestamp(timestamp: &DateTime<Utc>) -> String {
    timestamp.format("%Y-%m-%d %H:%M:%S UTC").to_string()
}

/// Format session metadata summary
pub fn format_session_summary(session: &SessionMetadata) -> String {
    format!(
        "Session {}\nTask: {}\nStatus: {:?}\nCreated: {}\nUpdated: {}\nTotal cost: ${:.4}\nLLM calls: {}\nCommands: {}\nTokens: {} prompt + {} completion = {} total\n",
        session.id,
        session.task,
        session.status,
        format_timestamp(&session.created_at),
        format_timestamp(&session.updated_at),
        session.total_cost,
        session.llm_call_count,
        session.command_count,
        session.total_tokens.prompt_tokens,
        session.total_tokens.completion_tokens,
        session.total_tokens.total_tokens,
    )
}

/// Format a completion summary (when agent finishes)
pub fn format_completion_summary(session: &SessionMetadata) -> String {
    format!(
        "✓ Task completed!\n\nSummary:\n  Total LLM calls: {}\n  Total commands: {}\n  Total cost: ${:.4}\n  Total tokens: {} prompt + {} completion = {} total\n",
        session.llm_call_count,
        session.command_count,
        session.total_cost,
        session.total_tokens.prompt_tokens,
        session.total_tokens.completion_tokens,
        session.total_tokens.total_tokens,
    )
}

/// Format a list of LLM calls (for --list-calls)
pub fn format_llm_call_list(events: &[Event]) -> String {
    let mut output = String::new();

    for event in events {
        if let Event::LlmCall {
            call_id,
            timestamp,
            purpose,
            response,
            ..
        } = event
        {
            let purpose_str = match purpose {
                LlmCallPurpose::Initialization => " (init)",
                LlmCallPurpose::MainLoop => "",
            };
            output.push_str(&format!(
                "[{}{}] {} - ${:.4} ({} tokens)\n",
                call_id,
                purpose_str,
                format_timestamp(timestamp),
                response.cost,
                response.usage.total_tokens
            ));
        }
    }

    if output.is_empty() {
        "No LLM calls found\n".to_string()
    } else {
        output
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::{CompletionResponse, FinishReason, TokenUsage as LlmTokenUsage};
    use crate::types::{SessionStatus, TokenUsage};
    use chrono::Utc;
    use rust_decimal_macros::dec;
    use std::path::PathBuf;

    #[test]
    fn test_format_system_prompt() {
        let event = Event::SystemPrompt {
            timestamp: Utc::now(),
            content: "You are a helpful assistant".to_string(),
        };

        let output = format_event(&event, DisplayMode::Runtime);
        assert!(output.contains("=== SYSTEM ==="));
        assert!(output.contains("You are a helpful assistant"));
        assert!(!output.contains("UTC")); // Runtime mode doesn't show timestamp
    }

    #[test]
    fn test_format_llm_call_runtime() {
        let event = Event::LlmCall {
            timestamp: Utc::now(),
            call_id: 0,
            purpose: LlmCallPurpose::Initialization,
            request: crate::llm::CompletionRequest {
                messages: vec![],
                model: "test".to_string(),
                max_tokens: None,
                temperature: None,
            },
            response: CompletionResponse {
                content: "Hello, world!".to_string(),
                usage: LlmTokenUsage {
                    prompt_tokens: 10,
                    completion_tokens: 5,
                    total_tokens: 15,
                },
                cost: dec!(0.0001),
                finish_reason: FinishReason::Stop,
            },
        };

        let output = format_event(&event, DisplayMode::Runtime);
        assert!(output.contains("[LLM Call 0 (Initialization)]"));
        assert!(output.contains("Cost: $0.0001"));
        assert!(output.contains("=== ASSISTANT ==="));
        assert!(output.contains("Hello, world!"));
    }

    #[test]
    fn test_format_llm_call_inspect() {
        let event = Event::LlmCall {
            timestamp: Utc::now(),
            call_id: 1,
            purpose: LlmCallPurpose::MainLoop,
            request: crate::llm::CompletionRequest {
                messages: vec![],
                model: "test".to_string(),
                max_tokens: None,
                temperature: None,
            },
            response: CompletionResponse {
                content: "Test response".to_string(),
                usage: LlmTokenUsage {
                    prompt_tokens: 20,
                    completion_tokens: 10,
                    total_tokens: 30,
                },
                cost: dec!(0.0002),
                finish_reason: FinishReason::Stop,
            },
        };

        let output = format_event(&event, DisplayMode::Inspect);
        assert!(output.contains("[LLM Call 1]"));
        assert!(output.contains("UTC")); // Inspect mode shows timestamp
        assert!(output.contains("Cost: $0.0002"));
    }

    #[test]
    fn test_format_raw() {
        let event = Event::SystemPrompt {
            timestamp: Utc::now(),
            content: "Test".to_string(),
        };

        let output = format_event(&event, DisplayMode::Raw);
        assert!(output.contains("\"type\": \"system_prompt\""));
        assert!(output.contains("\"content\": \"Test\""));
    }

    #[test]
    fn test_format_session_summary() {
        let session = SessionMetadata {
            id: crate::types::SessionId::from_u64(42),
            project_dir: PathBuf::from("/test"),
            task: "Test task".to_string(),
            created_at: Utc::now(),
            updated_at: Utc::now(),
            status: SessionStatus::Completed,
            total_cost: dec!(0.1234),
            total_tokens: TokenUsage {
                prompt_tokens: 1000,
                completion_tokens: 500,
                total_tokens: 1500,
            },
            llm_call_count: 3,
            command_count: 5,
        };

        let output = format_session_summary(&session);
        assert!(output.contains("Session 42"));
        assert!(output.contains("Test task"));
        assert!(output.contains("Completed"));
        assert!(output.contains("$0.1234"));
        assert!(output.contains("LLM calls: 3"));
        assert!(output.contains("Commands: 5"));
    }
}
