//! Formatting functions for displaying session events and metadata.
//!
//! This module provides a single source of truth for formatting session information,
//! used by both runtime display (during agent execution) and the inspect command.

use crate::types::{Event, LlmCallPurpose, ScreenState, SessionMetadata};
use chrono::{DateTime, Utc};

/// Display mode for formatting events
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayMode {
    /// Runtime display during agent execution
    Runtime,
}

/// Format an event for display
pub fn format_event(event: &Event, mode: DisplayMode) -> String {
    let DisplayMode::Runtime = mode;
    format_event_pretty(event)
}

/// Format an event in human-readable form for runtime display
fn format_event_pretty(event: &Event) -> String {
    match event {
        Event::SystemPrompt { content, .. } => {
            format!("=== SYSTEM ===\n{}\n", content)
        }
        Event::TaskMessage { content, .. } => {
            format!("=== TASK ===\n{}\n", content)
        }
        Event::LlmCall {
            call_id,
            purpose,
            response,
            ..
        } => {
            let purpose_str = match purpose {
                LlmCallPurpose::Initialization => " (Initialization)",
                LlmCallPurpose::MainLoop => "",
            };
            format!(
                "[LLM Call {}{}] Cost: ${:.4}\n\n=== ASSISTANT ===\n{}\n",
                call_id, purpose_str, response.cost, response.content
            )
        }
        Event::CommandExecution {
            environment,
            output,
            ..
        } => {
            format!("=== ORCHESTRATOR ({}) ===\n{}\n", environment, output)
        }
        Event::SessionEnd { status, reason, .. } => {
            let reason_str = reason
                .as_ref()
                .map(|r| format!("\nReason: {}", r))
                .unwrap_or_default();
            format!("=== SESSION END ===\nStatus: {:?}{}\n", status, reason_str)
        }
        Event::AuxiliaryLlmQuery {
            request_id,
            prompt,
            context,
            response,
            ..
        } => {
            let mut out = format!(
                "=== AUXILIARY LLM QUERY ({}) ===\nPrompt: {}\n",
                request_id, prompt
            );
            if let Some(ctx) = context {
                out.push_str(&format!("Context: {}\n", ctx));
            }
            out.push_str(&format!("Response: {}\n", response.content));
            out
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
    let mut output = format!(
        "✓ Task completed!\n\nSummary:\n  Total LLM calls: {}\n  Total commands: {}\n",
        session.llm_call_count, session.command_count,
    );

    if session.auxiliary_query_count > 0 {
        output.push_str(&format!(
            "  Auxiliary LLM queries: {}\n",
            session.auxiliary_query_count
        ));
    }

    output.push_str(&format!("  Total cost: ${:.4}", session.total_cost));

    if session.auxiliary_query_count > 0 {
        output.push_str(&format!(
            " (main: ${:.4}, auxiliary: ${:.4})",
            session.total_cost - session.auxiliary_cost,
            session.auxiliary_cost
        ));
    }

    output.push_str(&format!(
        "\n  Total tokens: {} prompt + {} completion = {} total\n",
        session.total_tokens.prompt_tokens,
        session.total_tokens.completion_tokens,
        session.total_tokens.total_tokens,
    ));

    output
}

/// Format a list of LLM calls — one line per call with ID, timestamp, cost, and tokens
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

/// Format all LLM replies in sequence — one header per call followed by the reply text
pub fn format_llm_replies(events: &[Event]) -> String {
    let mut output = String::new();

    for event in events {
        if let Event::LlmCall {
            timestamp,
            call_id,
            response,
            ..
        } = event
        {
            output.push_str(&format!(
                "[Call {}] {}\n{}\n\n",
                call_id,
                format_timestamp(timestamp),
                response.content
            ));
        }
    }

    if output.is_empty() {
        "No LLM calls found\n".to_string()
    } else {
        output
    }
}

/// Format the full input context and reply for a specific LLM call
///
/// Prints every message sent to the LLM (by role) followed by the reply.
pub fn format_llm_call_context(events: &[Event], call_id: usize) -> anyhow::Result<String> {
    for event in events {
        if let Event::LlmCall {
            timestamp,
            call_id: id,
            purpose,
            request,
            response,
        } = event
        {
            if *id != call_id {
                continue;
            }
            let purpose_str = match purpose {
                LlmCallPurpose::Initialization => " (init)",
                LlmCallPurpose::MainLoop => "",
            };
            let mut output = format!(
                "=== Full Context for Call {}{} ===\n{} - ${:.4} ({} tokens)\n\n",
                call_id,
                purpose_str,
                format_timestamp(timestamp),
                response.cost,
                response.usage.total_tokens
            );
            for msg in &request.messages {
                output.push_str(&format!(
                    "--- {} ---\n{}\n\n",
                    msg.role.to_uppercase(),
                    msg.content
                ));
            }
            output.push_str(&format!("=== LLM Reply ===\n{}\n", response.content));
            return Ok(output);
        }
    }
    anyhow::bail!("LLM call {} not found", call_id)
}

/// Format the LLM reply, subsequent commands, and resulting screen for a specific call
pub fn format_llm_call_after(events: &[Event], call_id: usize) -> anyhow::Result<String> {
    let call_idx = events
        .iter()
        .position(|e| matches!(e, Event::LlmCall { call_id: id, .. } if *id == call_id))
        .ok_or_else(|| anyhow::anyhow!("LLM call {} not found", call_id))?;

    let response_content = if let Event::LlmCall { response, .. } = &events[call_idx] {
        &response.content
    } else {
        unreachable!()
    };

    let mut output = format!("=== LLM Reply ===\n{}\n\n", response_content);

    let mut last_screen: Option<&ScreenState> = None;
    for event in &events[call_idx + 1..] {
        match event {
            Event::LlmCall { .. } => break,
            Event::CommandExecution {
                environment,
                command,
                output: cmd_output,
                screen,
                ..
            } => {
                output.push_str(&format!(
                    "=== [{}] {} ===\n{}\n",
                    environment, command, cmd_output
                ));
                last_screen = Some(screen);
            }
            _ => {}
        }
    }

    if let Some(screen) = last_screen {
        output.push_str("=== Screen ===\n");
        output.push_str(&format_screen_state(screen));
    }

    Ok(output)
}

/// Pretty-print a screen state — sections in sorted key order
fn format_screen_state(screen: &ScreenState) -> String {
    let mut keys: Vec<&String> = screen.sections.keys().collect();
    keys.sort();
    let mut output = String::new();
    for key in keys {
        let section = &screen.sections[key];
        output.push_str(&format!("--- {} ---\n{}\n", key, section.content));
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::{CompletionResponse, FinishReason, LlmMessage, TokenUsage as LlmTokenUsage};
    use crate::types::{ScreenSection, ScreenState, SessionStatus, TokenUsage};
    use chrono::Utc;
    use rust_decimal_macros::dec;
    use std::collections::HashMap;
    use std::path::PathBuf;

    // ── Test helpers ─────────────────────────────────────────────────────────

    fn make_llm_call(call_id: usize, content: &str) -> Event {
        Event::LlmCall {
            timestamp: Utc::now(),
            call_id,
            purpose: LlmCallPurpose::MainLoop,
            request: crate::llm::CompletionRequest {
                messages: vec![LlmMessage {
                    role: "user".to_string(),
                    content: "test prompt".to_string(),
                }],
                model: "test".to_string(),
                max_tokens: None,
                temperature: None,
            },
            response: CompletionResponse {
                content: content.to_string(),
                usage: LlmTokenUsage {
                    prompt_tokens: 10,
                    completion_tokens: 5,
                    total_tokens: 15,
                },
                cost: dec!(0.0001),
                finish_reason: FinishReason::Stop,
            },
        }
    }

    fn make_cmd_execution(env: &str, cmd: &str, out: &str, screen: ScreenState) -> Event {
        Event::CommandExecution {
            timestamp: Utc::now(),
            environment: env.to_string(),
            command: cmd.to_string(),
            output: out.to_string(),
            processed: true,
            exit_code: None,
            screen,
        }
    }

    fn make_screen(env: &str, content: &str) -> ScreenState {
        let mut sections = HashMap::new();
        sections.insert(
            env.to_string(),
            ScreenSection {
                content: content.to_string(),
                max_lines: 50,
            },
        );
        ScreenState {
            timestamp: Utc::now(),
            sections,
        }
    }

    // ── format_event (runtime) ────────────────────────────────────────────────

    #[test]
    fn test_format_system_prompt_runtime_includes_content_without_timestamp() {
        // Requirement: Runtime mode must include system header and full content
        // without timestamp.

        let event = Event::SystemPrompt {
            timestamp: Utc::now(),
            content: "You are a helpful assistant".to_string(),
        };

        let output = format_event(&event, DisplayMode::Runtime);

        // Must include header to identify event type
        assert!(
            output.contains("=== SYSTEM ==="),
            "Output must include SYSTEM header for user recognition"
        );

        // Must include full content
        assert!(
            output.contains("You are a helpful assistant"),
            "Output must include complete content. Output:\n{}",
            output
        );

        // Runtime mode must NOT include timestamp
        assert!(
            !output.contains("UTC"),
            "Runtime mode should not include timestamp. Output:\n{}",
            output
        );
    }

    #[test]
    fn test_format_llm_call_runtime_includes_call_info_and_response() {
        // Requirements:
        // 1. Must include call ID and purpose
        // 2. Must include cost with 4 decimal places
        // 3. Must include response content under ASSISTANT header
        // 4. Must NOT include timestamp in runtime mode
        //
        // Combined requirements for LLM call formatting in runtime display.

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

        // Requirement 1: Call ID and purpose
        assert!(
            output.contains("[LLM Call 0") && output.contains("Initialization"),
            "Must include call ID and purpose. Output:\n{}",
            output
        );

        // Requirement 2: Cost with 4 decimal places
        assert!(
            output.contains("$0.0001"),
            "Must show cost with 4 decimal places. Output:\n{}",
            output
        );

        // Requirement 3: Response under ASSISTANT header
        assert!(
            output.contains("=== ASSISTANT ==="),
            "Must have ASSISTANT header. Output:\n{}",
            output
        );
        assert!(
            output.contains("Hello, world!"),
            "Must include response content. Output:\n{}",
            output
        );

        // Requirement 4: No timestamp in runtime mode
        assert!(
            !output.contains("UTC"),
            "Runtime mode should not include timestamp. Output:\n{}",
            output
        );
    }

    // ── format_session_summary ───────────────────────────────────────────────

    #[test]
    fn test_format_session_summary_includes_all_metadata() {
        // Requirements:
        // 1. Must include session ID
        // 2. Must include task description
        // 3. Must include status
        // 4. Must include total cost with 4 decimal places
        // 5. Must include call and command counts
        // 6. Must include token usage breakdown
        //
        // Combined requirements for session summary formatting.

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
            auxiliary_cost: dec!(0.0000),
            auxiliary_tokens: Default::default(),
            auxiliary_query_count: 0,
        };

        let output = format_session_summary(&session);

        // Requirement 1: Session ID
        assert!(
            output.contains("42"),
            "Must include session ID. Output:\n{}",
            output
        );

        // Requirement 2: Task description
        assert!(
            output.contains("Test task"),
            "Must include task description. Output:\n{}",
            output
        );

        // Requirement 3: Status
        assert!(
            output.contains("Completed"),
            "Must include status. Output:\n{}",
            output
        );

        // Requirement 4: Total cost with decimals
        assert!(
            output.contains("0.1234"),
            "Must include total cost with 4 decimals. Output:\n{}",
            output
        );

        // Requirement 5: Call and command counts
        assert!(
            output.contains("3") && (output.contains("LLM") || output.contains("call")),
            "Must include LLM call count. Output:\n{}",
            output
        );
        assert!(
            output.contains("5") && (output.contains("Command") || output.contains("command")),
            "Must include command count. Output:\n{}",
            output
        );

        // Requirement 6: Token breakdown
        assert!(
            output.contains("1000") && output.contains("500") && output.contains("1500"),
            "Must include token breakdown (prompt/completion/total). Output:\n{}",
            output
        );
    }

    // ── format_llm_call_list ─────────────────────────────────────────────────

    #[test]
    fn test_format_llm_call_list_with_no_calls_returns_not_found_message() {
        // Requirement: When no LLM call events exist, output must clearly say so.

        let events: Vec<Event> = vec![Event::SystemPrompt {
            timestamp: Utc::now(),
            content: "sys".to_string(),
        }];

        let output = format_llm_call_list(&events);

        assert!(
            output.contains("No LLM calls found"),
            "Must report absence of calls. Output:\n{}",
            output
        );
    }

    #[test]
    fn test_format_llm_call_list_shows_id_timestamp_cost_and_tokens_per_call() {
        // Requirement: Each LLM call must appear on its own line with ID, timestamp,
        // cost formatted to 4 decimal places, and total token count.

        let events = vec![make_llm_call(0, "hello"), make_llm_call(1, "world")];

        let output = format_llm_call_list(&events);

        assert!(
            output.contains("[0]"),
            "Must include call ID 0. Output:\n{}",
            output
        );
        assert!(
            output.contains("[1]"),
            "Must include call ID 1. Output:\n{}",
            output
        );
        assert!(
            output.contains("$0.0001"),
            "Must include cost with 4 decimal places. Output:\n{}",
            output
        );
        assert!(
            output.contains("15 tokens"),
            "Must include token count. Output:\n{}",
            output
        );
    }

    // ── format_llm_replies ───────────────────────────────────────────────────

    #[test]
    fn test_format_llm_replies_with_no_calls_returns_not_found_message() {
        // Requirement: When no LLM call events exist, output must clearly say so.

        let events: Vec<Event> = vec![];

        let output = format_llm_replies(&events);

        assert!(
            output.contains("No LLM calls found"),
            "Must report absence of calls. Output:\n{}",
            output
        );
    }

    #[test]
    fn test_format_llm_replies_shows_all_replies_in_sequence() {
        // Requirement: Each LLM call must have a header with call ID and timestamp
        // followed by the full reply text, in event order.

        let events = vec![
            make_llm_call(0, "first reply"),
            make_llm_call(1, "second reply"),
        ];

        let output = format_llm_replies(&events);

        // Both call IDs must appear
        assert!(
            output.contains("[Call 0]"),
            "Must include Call 0 header. Output:\n{}",
            output
        );
        assert!(
            output.contains("[Call 1]"),
            "Must include Call 1 header. Output:\n{}",
            output
        );

        // Both reply bodies must appear
        assert!(
            output.contains("first reply"),
            "Must include first reply content. Output:\n{}",
            output
        );
        assert!(
            output.contains("second reply"),
            "Must include second reply content. Output:\n{}",
            output
        );

        // Call 0 must appear before Call 1
        let pos0 = output.find("[Call 0]").unwrap();
        let pos1 = output.find("[Call 1]").unwrap();
        assert!(pos0 < pos1, "Calls must be in sequence order");
    }

    // ── format_llm_call_context ──────────────────────────────────────────────

    #[test]
    fn test_format_llm_call_context_returns_error_for_missing_call() {
        // Requirement: Requesting context for a non-existent call ID must return an error.

        let events = vec![make_llm_call(0, "hello")];

        let result = format_llm_call_context(&events, 99);

        assert!(result.is_err(), "Must return error for missing call");
        assert!(
            result.unwrap_err().to_string().contains("99"),
            "Error message must include the requested call ID"
        );
    }

    #[test]
    fn test_format_llm_call_context_shows_messages_and_reply() {
        // Requirements:
        // 1. Must show a header identifying the call number
        // 2. Must show each prompt message with its role
        // 3. Must show the LLM reply under a distinct header

        let events = vec![make_llm_call(2, "assistant reply")];

        let output = format_llm_call_context(&events, 2).unwrap();

        // Requirement 1: Header with call number
        assert!(
            output.contains("Call 2"),
            "Must include call number in header. Output:\n{}",
            output
        );

        // Requirement 2: Prompt message with role
        assert!(
            output.contains("USER") || output.contains("user"),
            "Must include role header for prompt message. Output:\n{}",
            output
        );
        assert!(
            output.contains("test prompt"),
            "Must include prompt message content. Output:\n{}",
            output
        );

        // Requirement 3: LLM reply under distinct header
        assert!(
            output.contains("=== LLM Reply ==="),
            "Must have LLM Reply header. Output:\n{}",
            output
        );
        assert!(
            output.contains("assistant reply"),
            "Must include reply content. Output:\n{}",
            output
        );
    }

    // ── format_llm_call_after ────────────────────────────────────────────────

    #[test]
    fn test_format_llm_call_after_returns_error_for_missing_call() {
        // Requirement: Requesting after-view for a non-existent call ID must return an error.

        let events: Vec<Event> = vec![];

        let result = format_llm_call_after(&events, 5);

        assert!(result.is_err(), "Must return error for missing call");
        assert!(
            result.unwrap_err().to_string().contains("5"),
            "Error message must include the requested call ID"
        );
    }

    #[test]
    fn test_format_llm_call_after_shows_reply_then_commands_then_screen() {
        // Requirements:
        // 1. Must show LLM reply first
        // 2. Must show commands executed after the call
        // 3. Must show screen state from the last command

        let screen = make_screen("bash", "$ ls\nfile.txt\n");
        let events = vec![
            make_llm_call(0, "do some work"),
            make_cmd_execution("bash", "ls", "file.txt", screen),
        ];

        let output = format_llm_call_after(&events, 0).unwrap();

        // Requirement 1: LLM reply first
        assert!(
            output.contains("=== LLM Reply ==="),
            "Must include LLM Reply header. Output:\n{}",
            output
        );
        assert!(
            output.contains("do some work"),
            "Must include reply content. Output:\n{}",
            output
        );

        // Requirement 2: Commands after call
        assert!(
            output.contains("[bash]") && output.contains("ls"),
            "Must include command with environment. Output:\n{}",
            output
        );
        assert!(
            output.contains("file.txt"),
            "Must include command output. Output:\n{}",
            output
        );

        // Requirement 3: Screen state
        assert!(
            output.contains("=== Screen ==="),
            "Must include Screen header. Output:\n{}",
            output
        );

        // LLM reply must appear before commands
        let reply_pos = output.find("=== LLM Reply ===").unwrap();
        let cmd_pos = output.find("[bash]").unwrap();
        assert!(reply_pos < cmd_pos, "LLM reply must appear before commands");
    }

    #[test]
    fn test_format_llm_call_after_stops_at_next_llm_call() {
        // Requirement: Commands belonging to the NEXT LLM call cycle must not appear.

        let screen1 = make_screen("bash", "output1");
        let screen2 = make_screen("bash", "output2");
        let events = vec![
            make_llm_call(0, "first call"),
            make_cmd_execution("bash", "cmd1", "output1", screen1),
            make_llm_call(1, "second call"),
            make_cmd_execution("bash", "cmd2", "output2", screen2),
        ];

        let output = format_llm_call_after(&events, 0).unwrap();

        assert!(
            output.contains("cmd1"),
            "Must include cmd1 (belongs to call 0). Output:\n{}",
            output
        );
        assert!(
            !output.contains("cmd2"),
            "Must NOT include cmd2 (belongs to call 1). Output:\n{}",
            output
        );
    }
}
