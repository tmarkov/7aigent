# Rust Conventions

This document defines coding conventions for Rust code in the 7aigent project (the agent component).

## Core Principles

1. **Compile-time guarantees**: Leverage type system to prevent errors
2. **Explicit error handling**: No `.unwrap()` in production code
3. **Documentation**: Doc comments for all public APIs
4. **Idiomatic Rust**: Follow Rust conventions and best practices

## Type Safety

Use the type system to make invalid states unrepresentable:

```rust
// Use type system to make invalid states unrepresentable
#[derive(Debug, Clone)]
pub struct ValidatedConfig {
    api_key: String,
    timeout: Duration,
}

impl ValidatedConfig {
    // Constructor validates, so struct always contains valid data
    pub fn new(api_key: String, timeout: Duration) -> Result<Self, ConfigError> {
        if api_key.is_empty() {
            return Err(ConfigError::EmptyApiKey);
        }
        Ok(Self { api_key, timeout })
    }
}

// Use newtypes for semantic distinction
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvironmentName(String);

#[derive(Debug, Clone)]
pub struct CommandText(String);
```

## Error Handling

Define specific error types with thiserror:

```rust
use thiserror::Error;

// Define specific error types with thiserror
#[derive(Error, Debug)]
pub enum LLMError {
    #[error("Rate limit exceeded")]
    RateLimit,

    #[error("Request timeout after {0:?}")]
    Timeout(Duration),

    #[error("Authentication failed: {0}")]
    AuthError(String),

    #[error("HTTP error: {0}")]
    HttpError(#[from] reqwest::Error),
}

// Pattern match on specific errors for different handling
async fn call_llm_with_retry(request: Request) -> Result<Response, LLMError> {
    match call_llm(request).await {
        Err(LLMError::RateLimit | LLMError::Timeout(_) | LLMError::ServerError) => {
            exponential_backoff_retry(request).await
        }
        Err(LLMError::AuthError(msg)) => {
            eprintln!("Authentication failed: {msg}");
            std::process::exit(1);
        }
        Ok(response) => Ok(response),
        Err(e) => Err(e),
    }
}

// Use ? for error propagation
pub async fn process_task(task: Task) -> Result<TaskResult, AgentError> {
    let response = call_llm(task.into_request()).await?;
    let command = parse_command(&response)?;
    let result = execute_command(command).await?;
    Ok(result)
}
```

## Documentation

Document all public APIs with doc comments:

```rust
/// Execute a command in the orchestrator and wait for response.
///
/// This function sends the command to the orchestrator via stdin,
/// then reads the response from stdout. It handles serialization
/// and deserialization of messages.
///
/// # Arguments
///
/// * `command` - The command to execute
///
/// # Returns
///
/// The response from the orchestrator
///
/// # Errors
///
/// Returns `OrchestratorError::EOF` if orchestrator process died
/// Returns `OrchestratorError::ParseError` if response is invalid
///
/// # Example
///
/// ```
/// let cmd = Command::new(EnvironmentName("bash"), CommandText("ls"));
/// let response = execute_command(cmd).await?;
/// ```
pub async fn execute_command(command: Command) -> Result<Response, OrchestratorError> {
    // Implementation
}
```

## Tooling

**Formatting:**
- `rustfmt` with default configuration
- Run on all code before commits

**Linting:**
- `clippy` with strict settings
- Treat warnings as errors in CI: `#![deny(clippy::all)]`

**Testing:**
- Unit tests in same file as code: `#[cfg(test)] mod tests { ... }`
- Integration tests in `tests/` directory
- Property-based testing with `proptest` where applicable

## Related Files

- [General Conventions](./general.md) - Project-wide conventions
- [Python Conventions](./python.md) - Python-specific style guidelines
- [Testing](../testing.md) - Testing strategy and guidelines
