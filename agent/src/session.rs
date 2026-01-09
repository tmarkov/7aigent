//! Session error types for 7aigent.
//!
//! Sessions are now self-contained and handle their own persistence.
//! See `types::Session` for session creation, loading, and saving.

use crate::types::SessionId;
use thiserror::Error;

/// Error type for session operations
#[derive(Debug, Error)]
pub enum SessionError {
    #[error("Session not found: {0}")]
    NotFound(SessionId),

    #[error("Session directory already exists: {0}")]
    AlreadyExists(SessionId),

    #[error("Invalid session directory structure")]
    InvalidStructure,

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("Invalid project directory")]
    InvalidProjectDir,
}

pub type Result<T> = std::result::Result<T, SessionError>;
