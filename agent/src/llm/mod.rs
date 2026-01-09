//! LLM client abstraction and implementations.

use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use std::fmt;
use thiserror::Error;

pub mod cost;
pub mod openai;
pub mod retry;

// Re-export ValidatedLlmConfig for convenience
pub use openai::ValidatedLlmConfig;

/// Errors that can occur during LLM operations.
#[derive(Debug, Error)]
pub enum LlmError {
    /// Rate limit exceeded - should retry with backoff.
    #[error("Rate limit exceeded: {0}")]
    RateLimit(String),

    /// Request timeout - can retry.
    #[error("Request timeout: {0}")]
    Timeout(String),

    /// Authentication failed - should not retry.
    #[error("Authentication failed: {0}")]
    Auth(String),

    /// Invalid request - should not retry.
    #[error("Invalid request: {0}")]
    InvalidRequest(String),

    /// Server error - can retry.
    #[error("Server error: {0}")]
    ServerError(String),

    /// Network error - can retry.
    #[error("Network error: {0}")]
    Network(String),

    /// Response parsing error.
    #[error("Failed to parse response: {0}")]
    ParseError(String),

    /// Other errors.
    #[error("LLM error: {0}")]
    Other(String),
}

/// Message to send to the LLM.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LlmMessage {
    /// Role of the message sender.
    pub role: String,
    /// Content of the message.
    pub content: String,
}

impl LlmMessage {
    /// Create a system message.
    pub fn system(content: impl Into<String>) -> Self {
        Self {
            role: "system".to_string(),
            content: content.into(),
        }
    }

    /// Create a user message.
    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: "user".to_string(),
            content: content.into(),
        }
    }

    /// Create an assistant message.
    pub fn assistant(content: impl Into<String>) -> Self {
        Self {
            role: "assistant".to_string(),
            content: content.into(),
        }
    }
}

/// Token usage information.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct TokenUsage {
    /// Number of prompt tokens.
    pub prompt_tokens: u32,
    /// Number of completion tokens.
    pub completion_tokens: u32,
    /// Total tokens (prompt + completion).
    pub total_tokens: u32,
}

impl TokenUsage {
    /// Create a new TokenUsage.
    pub fn new(prompt_tokens: u32, completion_tokens: u32) -> Self {
        Self {
            prompt_tokens,
            completion_tokens,
            total_tokens: prompt_tokens + completion_tokens,
        }
    }
}

/// Why the completion finished.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FinishReason {
    /// Natural stop point.
    Stop,
    /// Max tokens reached.
    Length,
    /// Content filter triggered.
    ContentFilter,
    /// Function call (tool use).
    ToolCalls,
    /// Unknown reason.
    Other,
}

impl fmt::Display for FinishReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Stop => write!(f, "stop"),
            Self::Length => write!(f, "length"),
            Self::ContentFilter => write!(f, "content_filter"),
            Self::ToolCalls => write!(f, "tool_calls"),
            Self::Other => write!(f, "other"),
        }
    }
}

/// Response from an LLM completion.
#[derive(Debug, Clone)]
pub struct CompletionResponse {
    /// Generated content.
    pub content: String,
    /// Token usage information.
    pub usage: TokenUsage,
    /// Actual cost in USD.
    pub cost: Decimal,
    /// Why the completion finished.
    pub finish_reason: FinishReason,
}

/// Request to the LLM.
#[derive(Debug, Clone)]
pub struct CompletionRequest {
    /// Messages to send.
    pub messages: Vec<LlmMessage>,
    /// Model to use (e.g., "gpt-4").
    pub model: String,
    /// Maximum tokens to generate.
    pub max_tokens: Option<u32>,
    /// Temperature (0.0 - 2.0).
    pub temperature: Option<f32>,
}

impl Clone for LlmError {
    fn clone(&self) -> Self {
        match self {
            Self::RateLimit(msg) => Self::RateLimit(msg.clone()),
            Self::Timeout(msg) => Self::Timeout(msg.clone()),
            Self::Auth(msg) => Self::Auth(msg.clone()),
            Self::InvalidRequest(msg) => Self::InvalidRequest(msg.clone()),
            Self::ServerError(msg) => Self::ServerError(msg.clone()),
            Self::Network(msg) => Self::Network(msg.clone()),
            Self::ParseError(msg) => Self::ParseError(msg.clone()),
            Self::Other(msg) => Self::Other(msg.clone()),
        }
    }
}

/// LLM client trait.
#[async_trait::async_trait]
pub trait LlmClient: Send + Sync {
    /// Complete a chat conversation.
    async fn complete(&self, request: CompletionRequest) -> Result<CompletionResponse, LlmError>;

    /// Estimate the cost of a completion request.
    fn estimate_cost(&self, request: &CompletionRequest) -> Result<Decimal, LlmError>;

    /// Count tokens in a message.
    fn count_tokens(&self, message: &str) -> usize;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_llm_message_constructors() {
        let system = LlmMessage::system("You are a helpful assistant");
        assert_eq!(system.role, "system");
        assert_eq!(system.content, "You are a helpful assistant");

        let user = LlmMessage::user("Hello!");
        assert_eq!(user.role, "user");
        assert_eq!(user.content, "Hello!");

        let assistant = LlmMessage::assistant("Hi there!");
        assert_eq!(assistant.role, "assistant");
        assert_eq!(assistant.content, "Hi there!");
    }

    #[test]
    fn test_token_usage() {
        let usage = TokenUsage::new(100, 50);
        assert_eq!(usage.prompt_tokens, 100);
        assert_eq!(usage.completion_tokens, 50);
        assert_eq!(usage.total_tokens, 150);
    }

    #[test]
    fn test_finish_reason_display() {
        assert_eq!(FinishReason::Stop.to_string(), "stop");
        assert_eq!(FinishReason::Length.to_string(), "length");
        assert_eq!(FinishReason::ContentFilter.to_string(), "content_filter");
        assert_eq!(FinishReason::ToolCalls.to_string(), "tool_calls");
        assert_eq!(FinishReason::Other.to_string(), "other");
    }
}
