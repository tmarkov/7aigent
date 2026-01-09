//! OpenAI-compatible API client implementation.

use super::cost::TokenPricing;
use super::{
    CompletionRequest, CompletionResponse, FinishReason, LlmClient, LlmError, LlmMessage,
    TokenUsage,
};
use reqwest::{header, Client};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use std::time::Duration;

/// OpenAI-compatible client configuration.
#[derive(Debug, Clone)]
pub struct OpenAiConfig {
    /// API endpoint URL.
    pub endpoint: String,
    /// API key for authentication.
    pub api_key: String,
    /// Default model to use.
    pub model: String,
    /// Token pricing for cost estimation.
    pub pricing: TokenPricing,
    /// Request timeout in seconds.
    pub timeout_seconds: u64,
}

impl OpenAiConfig {
    /// Create a new OpenAiConfig.
    pub fn new(endpoint: String, api_key: String, model: String, pricing: TokenPricing) -> Self {
        Self {
            endpoint,
            api_key,
            model,
            pricing,
            timeout_seconds: 60,
        }
    }

    /// Set the timeout in seconds.
    pub fn with_timeout(mut self, timeout_seconds: u64) -> Self {
        self.timeout_seconds = timeout_seconds;
        self
    }
}

/// OpenAI-compatible API client.
pub struct OpenAiCompatibleClient {
    /// HTTP client.
    client: Client,
    /// Configuration.
    config: OpenAiConfig,
}

impl OpenAiCompatibleClient {
    /// Create a new OpenAI-compatible client.
    pub fn new(config: OpenAiConfig) -> Result<Self, LlmError> {
        let mut headers = header::HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            header::HeaderValue::from_str(&format!("Bearer {}", config.api_key))
                .map_err(|e| LlmError::Auth(format!("Invalid API key: {}", e)))?,
        );
        headers.insert(
            header::CONTENT_TYPE,
            header::HeaderValue::from_static("application/json"),
        );

        let client = Client::builder()
            .default_headers(headers)
            .timeout(Duration::from_secs(config.timeout_seconds))
            .build()
            .map_err(|e| LlmError::Other(format!("Failed to create HTTP client: {}", e)))?;

        Ok(Self { client, config })
    }

    /// Calculate cost from token usage.
    fn calculate_cost(&self, usage: &TokenUsage) -> Decimal {
        let input_cost = Decimal::from(usage.prompt_tokens) * self.config.pricing.input_cost_per_1k
            / Decimal::from(1000);
        let output_cost = Decimal::from(usage.completion_tokens)
            * self.config.pricing.output_cost_per_1k
            / Decimal::from(1000);
        input_cost + output_cost
    }
}

#[async_trait::async_trait]
impl LlmClient for OpenAiCompatibleClient {
    async fn complete(&self, request: CompletionRequest) -> Result<CompletionResponse, LlmError> {
        let api_request = OpenAiRequest {
            model: request.model,
            messages: request.messages,
            max_tokens: request.max_tokens,
            temperature: request.temperature,
        };

        let response = self
            .client
            .post(format!("{}/chat/completions", self.config.endpoint))
            .json(&api_request)
            .send()
            .await
            .map_err(|e| {
                if e.is_timeout() {
                    LlmError::Timeout(e.to_string())
                } else if e.is_connect() {
                    LlmError::Network(e.to_string())
                } else {
                    LlmError::Other(e.to_string())
                }
            })?;

        let status = response.status();
        if !status.is_success() {
            let error_text = response
                .text()
                .await
                .unwrap_or_else(|_| "Unknown error".to_string());

            return Err(match status.as_u16() {
                401 | 403 => LlmError::Auth(error_text),
                429 => LlmError::RateLimit(error_text),
                400 => LlmError::InvalidRequest(error_text),
                500..=599 => LlmError::ServerError(error_text),
                _ => LlmError::Other(format!("HTTP {}: {}", status, error_text)),
            });
        }

        let api_response: OpenAiResponse = response
            .json()
            .await
            .map_err(|e| LlmError::ParseError(format!("Failed to parse response: {}", e)))?;

        if api_response.choices.is_empty() {
            return Err(LlmError::ParseError("No choices in response".to_string()));
        }

        let choice = &api_response.choices[0];
        let usage = TokenUsage::new(
            api_response.usage.prompt_tokens,
            api_response.usage.completion_tokens,
        );
        let cost = self.calculate_cost(&usage);

        Ok(CompletionResponse {
            content: choice.message.content.clone(),
            usage,
            cost,
            finish_reason: choice.finish_reason,
        })
    }

    fn estimate_cost(&self, request: &CompletionRequest) -> Result<Decimal, LlmError> {
        // Count tokens in all messages
        let mut prompt_tokens = 0;
        for msg in &request.messages {
            prompt_tokens += self.count_tokens(&msg.content);
        }

        // Estimate completion tokens (use max_tokens or 1/4 of prompt as heuristic)
        let completion_tokens = request
            .max_tokens
            .map(|t| t as usize)
            .unwrap_or(prompt_tokens / 4);

        let usage = TokenUsage::new(prompt_tokens as u32, completion_tokens as u32);
        Ok(self.calculate_cost(&usage))
    }

    fn count_tokens(&self, text: &str) -> usize {
        // Simple character-based approximation: ~4 chars per token
        // This is rough but good enough for cost estimation
        text.len().div_ceil(4)
    }
}

/// OpenAI API request format.
#[derive(Debug, Serialize)]
struct OpenAiRequest {
    model: String,
    messages: Vec<LlmMessage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_tokens: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    temperature: Option<f32>,
}

/// OpenAI API response format.
#[derive(Debug, Deserialize)]
struct OpenAiResponse {
    choices: Vec<Choice>,
    usage: Usage,
}

#[derive(Debug, Deserialize)]
struct Choice {
    message: ResponseMessage,
    finish_reason: FinishReason,
}

#[derive(Debug, Deserialize)]
struct ResponseMessage {
    content: String,
}

#[derive(Debug, Deserialize)]
struct Usage {
    prompt_tokens: u32,
    completion_tokens: u32,
}

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    fn test_config() -> OpenAiConfig {
        OpenAiConfig::new(
            "https://api.openai.com/v1".to_string(),
            "test-key".to_string(),
            "gpt-4".to_string(),
            TokenPricing::new(dec!(0.03), dec!(0.06)),
        )
    }

    #[test]
    fn test_client_creation() {
        let config = test_config();
        let client = OpenAiCompatibleClient::new(config);
        assert!(client.is_ok());
    }

    #[test]
    fn test_calculate_cost() {
        let config = test_config();
        let client = OpenAiCompatibleClient::new(config).unwrap();

        let usage = TokenUsage::new(1000, 500);
        let cost = client.calculate_cost(&usage);

        // 1000 * 0.03 / 1000 + 500 * 0.06 / 1000 = 0.03 + 0.03 = 0.06
        assert_eq!(cost, dec!(0.06));
    }

    #[test]
    fn test_count_tokens() {
        let config = test_config();
        let client = OpenAiCompatibleClient::new(config).unwrap();

        // ~4 chars per token
        let count = client.count_tokens("Hello, world!");
        assert_eq!(count, 4); // 13 chars / 4 = 3.25 -> 4 (div_ceil)
    }

    #[test]
    fn test_estimate_cost() {
        let config = test_config();
        let client = OpenAiCompatibleClient::new(config).unwrap();

        let request = CompletionRequest {
            messages: vec![
                LlmMessage::system("You are helpful"),
                LlmMessage::user("Hello!"),
            ],
            model: "gpt-4".to_string(),
            max_tokens: Some(100),
            temperature: None,
        };

        let cost = client.estimate_cost(&request).unwrap();
        assert!(cost > Decimal::ZERO);
    }
}
