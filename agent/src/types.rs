//! Core type definitions for the 7aigent agent.

use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use uuid::Uuid;

/// Unique identifier for a session (strong newtype)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SessionId(Uuid);

impl SessionId {
    /// Create a new random session ID
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }

    /// Get the underlying UUID
    pub fn as_uuid(&self) -> &Uuid {
        &self.0
    }

    /// Parse from a string
    pub fn parse_str(s: &str) -> Result<Self, uuid::Error> {
        Uuid::parse_str(s).map(SessionId)
    }
}

impl Default for SessionId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for SessionId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl From<Uuid> for SessionId {
    fn from(uuid: Uuid) -> Self {
        SessionId(uuid)
    }
}

impl From<SessionId> for Uuid {
    fn from(id: SessionId) -> Self {
        id.0
    }
}

impl std::str::FromStr for SessionId {
    type Err = uuid::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Uuid::parse_str(s).map(SessionId)
    }
}

/// Session status
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    /// Session is currently active (agent is running)
    Active,
    /// Session is paused (user stopped agent, can resume)
    Paused,
    /// Session completed successfully
    Completed,
    /// Session failed with an error
    Failed,
}

/// Complete session state (persisted to disk)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    /// Unique session ID
    pub id: SessionId,

    /// Path to project directory
    pub project_dir: PathBuf,

    /// User's task description
    pub task: String,

    /// When session was created
    pub created_at: DateTime<Utc>,

    /// When session was last updated
    pub updated_at: DateTime<Utc>,

    /// Current status
    pub status: SessionStatus,

    /// Total cost so far (in dollars)
    pub total_cost: Decimal,

    /// Token usage statistics
    pub token_usage: TokenUsage,

    /// Number of steps completed
    pub step_count: usize,

    /// LLM configuration snapshot (for resume, recorded on first LLM call)
    pub llm_config: Option<LlmConfigSnapshot>,
}

/// LLM configuration snapshot (stored in session for resume)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmConfigSnapshot {
    pub endpoint: String,
    pub model: String,
}

impl Session {
    /// Create a new session
    pub fn create(project_dir: PathBuf, task: String) -> crate::session::Result<Self> {
        use crate::session::SessionError;

        let session_id = SessionId::new();
        let session_dir = project_dir
            .join(".7aigent")
            .join("sessions")
            .join(session_id.to_string());

        // Check if session already exists
        if session_dir.exists() {
            return Err(SessionError::AlreadyExists(session_id));
        }

        // Create session directory
        std::fs::create_dir_all(&session_dir)?;

        let now = Utc::now();
        let session = Session {
            id: session_id,
            project_dir: project_dir.clone(),
            task,
            created_at: now,
            updated_at: now,
            status: SessionStatus::Active,
            total_cost: Decimal::ZERO,
            token_usage: Default::default(),
            step_count: 0,
            llm_config: None,
        };

        // Save initial metadata and create empty files
        session.save_metadata()?;
        std::fs::File::create(session_dir.join("history.jsonl"))?;
        std::fs::File::create(session_dir.join("screens.jsonl"))?;

        // Initialize cost tracking
        let cost_data = serde_json::json!({
            "total": session.total_cost,
            "token_usage": session.token_usage,
            "per_step": []
        });
        let mut cost_file =
            std::io::BufWriter::new(std::fs::File::create(session_dir.join("cost.json"))?);
        serde_json::to_writer_pretty(&mut cost_file, &cost_data)?;
        use std::io::Write;
        cost_file.flush()?;

        Ok(session)
    }

    /// Load an existing session by ID
    pub fn load(
        project_dir: &std::path::Path,
        session_id: SessionId,
    ) -> crate::session::Result<Self> {
        use crate::session::SessionError;

        let session_dir = project_dir
            .join(".7aigent")
            .join("sessions")
            .join(session_id.to_string());

        if !session_dir.exists() {
            return Err(SessionError::NotFound(session_id));
        }

        let metadata_path = session_dir.join("metadata.json");
        let metadata_file = std::fs::File::open(metadata_path)?;
        let session: Session = serde_json::from_reader(metadata_file)?;

        Ok(session)
    }

    /// Get the session directory path
    fn session_dir(&self) -> PathBuf {
        self.project_dir
            .join(".7aigent")
            .join("sessions")
            .join(self.id.to_string())
    }

    /// Save session metadata
    pub fn save_metadata(&self) -> crate::session::Result<()> {
        let session_dir = self.session_dir();
        let metadata_path = session_dir.join("metadata.json");

        let mut file = std::io::BufWriter::new(std::fs::File::create(metadata_path)?);
        serde_json::to_writer_pretty(&mut file, self)?;
        use std::io::Write;
        file.flush()?;

        Ok(())
    }

    /// Save a complete step (message, screen, and cost update)
    pub fn save_step(&self, message: &Message, screen: &ScreenState) -> crate::session::Result<()> {
        let session_dir = self.session_dir();

        // Append message to history
        let history_path = session_dir.join("history.jsonl");
        let mut history_file = std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(history_path)?;
        serde_json::to_writer(&mut history_file, message)?;
        use std::io::Write;
        writeln!(history_file)?;

        // Append screen to screens
        let screens_path = session_dir.join("screens.jsonl");
        let mut screens_file = std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(screens_path)?;
        serde_json::to_writer(&mut screens_file, screen)?;
        writeln!(screens_file)?;

        // Update metadata (contains updated cost, step_count, etc.)
        self.save_metadata()?;

        // Update cost tracking
        let cost_path = session_dir.join("cost.json");
        let cost_file = std::fs::File::open(&cost_path)?;
        let mut cost_data: serde_json::Value = serde_json::from_reader(cost_file)?;

        cost_data["total"] = serde_json::json!(self.total_cost);
        cost_data["token_usage"] = serde_json::to_value(self.token_usage)?;

        let mut file = std::io::BufWriter::new(std::fs::File::create(cost_path)?);
        serde_json::to_writer_pretty(&mut file, &cost_data)?;
        file.flush()?;

        Ok(())
    }

    /// Record LLM configuration (called on first LLM use)
    pub fn record_llm_config(&mut self, snapshot: LlmConfigSnapshot) -> crate::session::Result<()> {
        self.llm_config = Some(snapshot);
        self.save_metadata()
    }

    /// Load conversation history for this session
    pub fn load_history(&self) -> crate::session::Result<Vec<Message>> {
        let history_path = self.session_dir().join("history.jsonl");

        if !history_path.exists() {
            return Ok(Vec::new());
        }

        let file = std::fs::File::open(history_path)?;
        let reader = std::io::BufReader::new(file);
        let mut messages = Vec::new();

        use std::io::BufRead;
        for line in reader.lines() {
            let line = line?;
            if !line.trim().is_empty() {
                let message: Message = serde_json::from_str(&line)?;
                messages.push(message);
            }
        }

        Ok(messages)
    }

    /// Load screen states for this session
    pub fn load_screens(&self) -> crate::session::Result<Vec<ScreenState>> {
        let screens_path = self.session_dir().join("screens.jsonl");

        if !screens_path.exists() {
            return Ok(Vec::new());
        }

        let file = std::fs::File::open(screens_path)?;
        let reader = std::io::BufReader::new(file);
        let mut screens = Vec::new();

        use std::io::BufRead;
        for line in reader.lines() {
            let line = line?;
            if !line.trim().is_empty() {
                let screen: ScreenState = serde_json::from_str(&line)?;
                screens.push(screen);
            }
        }

        Ok(screens)
    }
}

/// Token usage statistics
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct TokenUsage {
    pub prompt_tokens: usize,
    pub completion_tokens: usize,
    pub total_tokens: usize,
}

impl std::ops::AddAssign for TokenUsage {
    fn add_assign(&mut self, rhs: Self) {
        self.prompt_tokens += rhs.prompt_tokens;
        self.completion_tokens += rhs.completion_tokens;
        self.total_tokens += rhs.total_tokens;
    }
}

/// Message role in LLM conversation
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageRole {
    System,
    User,
    Assistant,
}

/// A single message in the conversation history
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: MessageRole,
    pub content: String,
    pub timestamp: DateTime<Utc>,
}

impl Message {
    pub fn system(content: String) -> Self {
        Self {
            role: MessageRole::System,
            content,
            timestamp: Utc::now(),
        }
    }

    pub fn user(content: String) -> Self {
        Self {
            role: MessageRole::User,
            content,
            timestamp: Utc::now(),
        }
    }

    pub fn assistant(content: String) -> Self {
        Self {
            role: MessageRole::Assistant,
            content,
            timestamp: Utc::now(),
        }
    }
}

/// Screen state at a specific step
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScreenState {
    /// Step number
    pub step: usize,

    /// When this screen was captured
    pub timestamp: DateTime<Utc>,

    /// Screen sections by environment name
    pub sections: HashMap<String, ScreenSection>,
}

/// Content for one environment's screen section
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScreenSection {
    pub content: String,
    pub max_lines: usize,
}

/// Command to execute in orchestrator
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    /// Environment name (bash, python, editor, etc.)
    pub env: String,

    /// Command text to execute
    pub command: String,
}

/// Response from executing a command
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandResponse {
    /// Command output
    pub output: String,

    /// Whether command succeeded
    pub success: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_token_usage_add_assign() {
        let mut usage1 = TokenUsage {
            prompt_tokens: 100,
            completion_tokens: 50,
            total_tokens: 150,
        };

        let usage2 = TokenUsage {
            prompt_tokens: 200,
            completion_tokens: 75,
            total_tokens: 275,
        };

        usage1 += usage2;

        assert_eq!(usage1.prompt_tokens, 300);
        assert_eq!(usage1.completion_tokens, 125);
        assert_eq!(usage1.total_tokens, 425);
    }

    #[test]
    fn test_message_creation() {
        let msg = Message::system("Test system message".to_string());
        assert_eq!(msg.role, MessageRole::System);
        assert_eq!(msg.content, "Test system message");

        let msg = Message::user("Test user message".to_string());
        assert_eq!(msg.role, MessageRole::User);

        let msg = Message::assistant("Test assistant message".to_string());
        assert_eq!(msg.role, MessageRole::Assistant);
    }

    #[test]
    fn test_session_serialization() {
        let session = Session {
            id: SessionId::new(),
            project_dir: PathBuf::from("/test/project"),
            task: "Test task".to_string(),
            created_at: Utc::now(),
            updated_at: Utc::now(),
            status: SessionStatus::Active,
            total_cost: Decimal::new(123, 2), // $1.23
            token_usage: TokenUsage::default(),
            step_count: 5,
            llm_config: Some(LlmConfigSnapshot {
                endpoint: "https://api.openai.com/v1".to_string(),
                model: "gpt-4".to_string(),
            }),
        };

        // Test that it can be serialized and deserialized
        let json = serde_json::to_string(&session).unwrap();
        let deserialized: Session = serde_json::from_str(&json).unwrap();

        assert_eq!(session.id, deserialized.id);
        assert_eq!(session.task, deserialized.task);
        assert_eq!(session.status, deserialized.status);
    }
}
