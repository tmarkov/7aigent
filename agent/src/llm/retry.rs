//! Retry logic with exponential backoff for LLM requests.

use super::{CompletionRequest, CompletionResponse, LlmClient, LlmError};
use std::time::Duration;
use tokio::time::sleep;

/// Maximum number of retry attempts for retryable errors.
const MAX_RETRIES: u32 = 3;

/// Initial backoff duration in milliseconds.
const INITIAL_BACKOFF_MS: u64 = 1000;

/// Backoff multiplier for exponential backoff.
const BACKOFF_MULTIPLIER: u64 = 2;

/// LLM client with automatic retry logic.
pub struct RetryClient<C: LlmClient> {
    inner: C,
    max_retries: u32,
}

impl<C: LlmClient> RetryClient<C> {
    /// Create a new retry client wrapping another client.
    pub fn new(inner: C) -> Self {
        Self {
            inner,
            max_retries: MAX_RETRIES,
        }
    }

    /// Set the maximum number of retries.
    pub fn with_max_retries(mut self, max_retries: u32) -> Self {
        self.max_retries = max_retries;
        self
    }

    /// Check if an error is retryable.
    fn is_retryable(error: &LlmError) -> bool {
        matches!(
            error,
            LlmError::RateLimit(_)
                | LlmError::Timeout(_)
                | LlmError::ServerError(_)
                | LlmError::Network(_)
        )
    }

    /// Calculate backoff duration for a given attempt number.
    fn backoff_duration(attempt: u32) -> Duration {
        let ms = INITIAL_BACKOFF_MS * BACKOFF_MULTIPLIER.pow(attempt);
        Duration::from_millis(ms)
    }
}

#[async_trait::async_trait]
impl<C: LlmClient> LlmClient for RetryClient<C> {
    async fn complete(&self, request: CompletionRequest) -> Result<CompletionResponse, LlmError> {
        let mut last_error = None;

        for attempt in 0..=self.max_retries {
            match self.inner.complete(request.clone()).await {
                Ok(response) => return Ok(response),
                Err(e) => {
                    // Don't retry on non-retryable errors
                    if !Self::is_retryable(&e) {
                        return Err(e);
                    }

                    last_error = Some(e);

                    // Don't sleep after the last attempt
                    if attempt < self.max_retries {
                        let backoff = Self::backoff_duration(attempt);
                        sleep(backoff).await;
                    }
                }
            }
        }

        // All retries exhausted
        Err(last_error.unwrap_or_else(|| {
            LlmError::Other("All retries exhausted but no error captured".to_string())
        }))
    }

    fn estimate_cost(
        &self,
        request: &CompletionRequest,
    ) -> Result<rust_decimal::Decimal, LlmError> {
        self.inner.estimate_cost(request)
    }

    fn count_tokens(&self, message: &str) -> usize {
        self.inner.count_tokens(message)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::{FinishReason, LlmMessage, TokenUsage};
    use rust_decimal::Decimal;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Arc;

    /// Mock client for testing retry logic.
    struct MockClient {
        attempts: Arc<AtomicU32>,
        fail_count: u32,
        error: LlmError,
    }

    impl MockClient {
        fn new(fail_count: u32, error: LlmError) -> Self {
            Self {
                attempts: Arc::new(AtomicU32::new(0)),
                fail_count,
                error,
            }
        }

        fn attempts(&self) -> u32 {
            self.attempts.load(Ordering::SeqCst)
        }
    }

    #[async_trait::async_trait]
    impl LlmClient for MockClient {
        async fn complete(
            &self,
            _request: CompletionRequest,
        ) -> Result<CompletionResponse, LlmError> {
            let attempt = self.attempts.fetch_add(1, Ordering::SeqCst);

            if attempt < self.fail_count {
                Err(self.error.clone())
            } else {
                Ok(CompletionResponse {
                    content: "Success".to_string(),
                    usage: TokenUsage::new(10, 5),
                    cost: Decimal::ZERO,
                    finish_reason: FinishReason::Stop,
                })
            }
        }

        fn estimate_cost(&self, _request: &CompletionRequest) -> Result<Decimal, LlmError> {
            Ok(Decimal::ZERO)
        }

        fn count_tokens(&self, message: &str) -> usize {
            message.len() / 4
        }
    }

    #[tokio::test]
    async fn test_retry_success_on_second_attempt() {
        let mock = MockClient::new(1, LlmError::RateLimit("Rate limited".to_string()));
        let retry_client = RetryClient::new(mock);

        let request = CompletionRequest {
            messages: vec![LlmMessage::user("test")],
            model: "gpt-4".to_string(),
            max_tokens: Some(100),
            temperature: None,
            reasoning_effort: None,
        };

        let result = retry_client.complete(request).await;
        assert!(result.is_ok());
        assert_eq!(retry_client.inner.attempts(), 2);
    }

    #[tokio::test]
    async fn test_retry_exhausted() {
        let mock = MockClient::new(10, LlmError::RateLimit("Rate limited".to_string()));
        let retry_client = RetryClient::new(mock).with_max_retries(2);

        let request = CompletionRequest {
            messages: vec![LlmMessage::user("test")],
            model: "gpt-4".to_string(),
            max_tokens: Some(100),
            temperature: None,
            reasoning_effort: None,
        };

        let result = retry_client.complete(request).await;
        assert!(result.is_err());
        assert_eq!(retry_client.inner.attempts(), 3); // 1 initial + 2 retries
    }

    #[tokio::test]
    async fn test_no_retry_on_auth_error() {
        let mock = MockClient::new(10, LlmError::Auth("Unauthorized".to_string()));
        let retry_client = RetryClient::new(mock);

        let request = CompletionRequest {
            messages: vec![LlmMessage::user("test")],
            model: "gpt-4".to_string(),
            max_tokens: Some(100),
            temperature: None,
            reasoning_effort: None,
        };

        let result = retry_client.complete(request).await;
        assert!(result.is_err());
        assert_eq!(retry_client.inner.attempts(), 1); // No retries
    }

    #[test]
    fn test_backoff_duration() {
        assert_eq!(
            RetryClient::<MockClient>::backoff_duration(0),
            Duration::from_millis(1000)
        );
        assert_eq!(
            RetryClient::<MockClient>::backoff_duration(1),
            Duration::from_millis(2000)
        );
        assert_eq!(
            RetryClient::<MockClient>::backoff_duration(2),
            Duration::from_millis(4000)
        );
    }

    #[test]
    fn test_is_retryable() {
        assert!(RetryClient::<MockClient>::is_retryable(
            &LlmError::RateLimit("test".to_string())
        ));
        assert!(RetryClient::<MockClient>::is_retryable(&LlmError::Timeout(
            "test".to_string()
        )));
        assert!(RetryClient::<MockClient>::is_retryable(
            &LlmError::ServerError("test".to_string())
        ));
        assert!(RetryClient::<MockClient>::is_retryable(&LlmError::Network(
            "test".to_string()
        )));

        assert!(!RetryClient::<MockClient>::is_retryable(&LlmError::Auth(
            "test".to_string()
        )));
        assert!(!RetryClient::<MockClient>::is_retryable(
            &LlmError::InvalidRequest("test".to_string())
        ));
        assert!(!RetryClient::<MockClient>::is_retryable(
            &LlmError::ParseError("test".to_string())
        ));
    }
}
