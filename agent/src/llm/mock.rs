/// Mock LLM client for testing
///
/// This module provides a mock implementation of the LLM client
/// that can be used in both unit tests and integration tests.
use crate::llm::{CompletionRequest, CompletionResponse, FinishReason, LlmClient, LlmError};
use async_trait::async_trait;
use rust_decimal::Decimal;
use std::sync::{Arc, Mutex};

/// Mock LLM client that records requests and returns canned responses
#[derive(Clone)]
pub struct MockLlmClient {
    requests: Arc<Mutex<Vec<CompletionRequest>>>,
    response_text: String,
}

impl MockLlmClient {
    /// Create a new mock client with a fixed response
    pub fn new(response_text: &str) -> Self {
        Self {
            requests: Arc::new(Mutex::new(Vec::new())),
            response_text: response_text.to_string(),
        }
    }

    /// Get all requests that were made to this client
    pub fn get_requests(&self) -> Vec<CompletionRequest> {
        self.requests.lock().unwrap().clone()
    }
}

#[async_trait]
impl LlmClient for MockLlmClient {
    async fn complete(&self, request: CompletionRequest) -> Result<CompletionResponse, LlmError> {
        // Record the request
        self.requests.lock().unwrap().push(request.clone());

        // Return mock response
        Ok(CompletionResponse {
            content: self.response_text.clone(),
            usage: crate::llm::TokenUsage::new(100, 50),
            cost: Decimal::new(15, 4), // $0.0015
            finish_reason: FinishReason::Stop,
        })
    }

    fn estimate_cost(&self, _request: &CompletionRequest) -> Result<Decimal, LlmError> {
        Ok(Decimal::new(15, 4))
    }

    fn count_tokens(&self, message: &str) -> usize {
        message.len() / 4
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_mock_client_records_requests() {
        let mock = MockLlmClient::new("test response");

        let request = CompletionRequest {
            messages: vec![crate::llm::LlmMessage::user("hello".to_string())],
            model: "test-model".to_string(),
            max_tokens: Some(100),
            temperature: Some(0.7),
        };

        let response = mock.complete(request.clone()).await.unwrap();

        assert_eq!(response.content, "test response");
        assert_eq!(mock.get_requests().len(), 1);
        assert_eq!(mock.get_requests()[0].model, "test-model");
    }
}
