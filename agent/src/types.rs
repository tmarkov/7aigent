//! Core type definitions for the 7aigent agent.

use chrono::{DateTime, Utc};
use fs2::FileExt;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Seek, Write};
use std::path::{Path, PathBuf};

use crate::llm::{CompletionRequest, CompletionResponse};

/// Unique identifier for a session (sequential u64)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SessionId(u64);

impl SessionId {
    /// Create a session ID from a u64
    pub fn from_u64(id: u64) -> Self {
        Self(id)
    }

    /// Get the underlying u64
    pub fn as_u64(&self) -> u64 {
        self.0
    }
}

impl std::fmt::Display for SessionId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::str::FromStr for SessionId {
    type Err = std::num::ParseIntError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(SessionId(s.parse()?))
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

/// Session metadata (persisted to session.json)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionMetadata {
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
    pub total_tokens: TokenUsage,

    /// Number of LLM calls made
    pub llm_call_count: usize,

    /// Number of commands executed
    pub command_count: usize,
}

impl SessionMetadata {
    /// Get the session directory path
    pub fn session_dir(&self) -> PathBuf {
        self.project_dir
            .join(".7aigent")
            .join("sessions")
            .join(self.id.to_string())
    }

    /// Save metadata to session.json
    pub fn save(&self) -> crate::session::Result<()> {
        let session_dir = self.session_dir();
        std::fs::create_dir_all(&session_dir)?;

        let metadata_path = session_dir.join("session.json");
        let file = std::fs::File::create(metadata_path)?;
        let mut writer = std::io::BufWriter::new(file);
        serde_json::to_writer_pretty(&mut writer, self)?;
        writer.flush()?;

        Ok(())
    }

    /// Load metadata from session.json
    pub fn load(project_dir: &Path, session_id: SessionId) -> crate::session::Result<Self> {
        use crate::session::SessionError;

        let session_dir = project_dir
            .join(".7aigent")
            .join("sessions")
            .join(session_id.to_string());

        if !session_dir.exists() {
            return Err(SessionError::NotFound(session_id));
        }

        let metadata_path = session_dir.join("session.json");
        let file = std::fs::File::open(metadata_path)?;
        let session: SessionMetadata = serde_json::from_reader(file)?;

        Ok(session)
    }

    /// Append an event to the events.jsonl file
    pub fn append_event(&mut self, event: &Event) -> crate::session::Result<()> {
        let session_dir = self.session_dir();
        let events_path = session_dir.join("events.jsonl");

        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(events_path)?;

        serde_json::to_writer(&mut file, event)?;
        file.write_all(b"\n")?;
        file.flush()?;

        // Update metadata counters
        self.updated_at = Utc::now();
        match event {
            Event::LlmCall { response, .. } => {
                self.llm_call_count += 1;
                self.total_cost += response.cost;
                self.total_tokens.prompt_tokens += response.usage.prompt_tokens as usize;
                self.total_tokens.completion_tokens += response.usage.completion_tokens as usize;
                self.total_tokens.total_tokens += response.usage.total_tokens as usize;
            }
            Event::CommandExecution { .. } => {
                self.command_count += 1;
            }
            Event::SessionEnd { status, .. } => {
                self.status = *status;
            }
            _ => {}
        }

        // Save updated metadata
        self.save()?;

        Ok(())
    }

    /// Load all events from events.jsonl
    pub fn load_events(&self) -> crate::session::Result<Vec<Event>> {
        let session_dir = self.session_dir();
        let events_path = session_dir.join("events.jsonl");

        if !events_path.exists() {
            return Ok(Vec::new());
        }

        let file = std::fs::File::open(events_path)?;
        let reader = BufReader::new(file);
        let mut events = Vec::new();

        for line in reader.lines() {
            let line = line?;
            if !line.trim().is_empty() {
                let event: Event = serde_json::from_str(&line)?;
                events.push(event);
            }
        }

        Ok(events)
    }
}

/// Purpose of an LLM call
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LlmCallPurpose {
    /// Finding overview file during initialization
    Initialization,
    /// Regular agent step in main loop
    MainLoop,
}

/// Screen state at a specific point in time
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScreenState {
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

/// Events that occur during a session
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    SystemPrompt {
        timestamp: DateTime<Utc>,
        content: String,
    },
    TaskMessage {
        timestamp: DateTime<Utc>,
        content: String,
    },
    LlmCall {
        timestamp: DateTime<Utc>,
        call_id: usize,
        purpose: LlmCallPurpose,
        request: CompletionRequest,
        response: CompletionResponse,
    },
    CommandExecution {
        timestamp: DateTime<Utc>,
        environment: String,
        command: String,
        output: String,
        processed: bool,
        screen: ScreenState,
    },
    SessionEnd {
        timestamp: DateTime<Utc>,
        status: SessionStatus,
        reason: Option<String>,
    },
}

impl Event {
    pub fn timestamp(&self) -> DateTime<Utc> {
        match self {
            Event::SystemPrompt { timestamp, .. } => *timestamp,
            Event::TaskMessage { timestamp, .. } => *timestamp,
            Event::LlmCall { timestamp, .. } => *timestamp,
            Event::CommandExecution { timestamp, .. } => *timestamp,
            Event::SessionEnd { timestamp, .. } => *timestamp,
        }
    }
}

/// Session manager for allocating sequential IDs
pub struct SessionManager {
    project_dir: PathBuf,
}

impl SessionManager {
    pub fn new(project_dir: PathBuf) -> Self {
        Self { project_dir }
    }

    /// Allocate a new sequential session ID
    pub fn allocate_id(&self) -> crate::session::Result<SessionId> {
        let base_dir = self.project_dir.join(".7aigent");
        std::fs::create_dir_all(&base_dir)?;

        let counter_path = base_dir.join("next_session_id");
        #[allow(clippy::suspicious_open_options)]
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(&counter_path)?;

        // Lock file exclusively
        file.lock_exclusive()?;

        // Read current ID or default to 1
        let current_id = if file.metadata()?.len() == 0 {
            1u64
        } else {
            let mut contents = String::new();
            use std::io::Read;
            file.read_to_string(&mut contents)?;
            contents.trim().parse().unwrap_or(1)
        };

        // Write next ID
        let next_id = current_id + 1;
        file.set_len(0)?; // Truncate
        file.seek(std::io::SeekFrom::Start(0))?;
        writeln!(file, "{}", next_id)?;
        file.flush()?;

        // Unlock file
        file.unlock()?;

        Ok(SessionId(current_id))
    }

    /// Create a new session with allocated ID
    pub fn create_session(&self, task: String) -> crate::session::Result<SessionMetadata> {
        let session_id = self.allocate_id()?;
        let session_dir = self
            .project_dir
            .join(".7aigent")
            .join("sessions")
            .join(session_id.to_string());

        // Create session directory
        std::fs::create_dir_all(&session_dir)?;

        let now = Utc::now();
        let metadata = SessionMetadata {
            id: session_id,
            project_dir: self.project_dir.clone(),
            task,
            created_at: now,
            updated_at: now,
            status: SessionStatus::Active,
            total_cost: Decimal::ZERO,
            total_tokens: Default::default(),
            llm_call_count: 0,
            command_count: 0,
        };

        // Save initial metadata and create empty events file
        metadata.save()?;
        std::fs::File::create(session_dir.join("events.jsonl"))?;

        Ok(metadata)
    }

    /// List all sessions in the project
    pub fn list_sessions(&self) -> crate::session::Result<Vec<SessionMetadata>> {
        let sessions_dir = self.project_dir.join(".7aigent").join("sessions");

        if !sessions_dir.exists() {
            return Ok(Vec::new());
        }

        let mut sessions = Vec::new();

        for entry in std::fs::read_dir(sessions_dir)? {
            let entry = entry?;
            let path = entry.path();

            if path.is_dir() {
                // Try to parse directory name as session ID
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    if let Ok(session_id) = name.parse::<u64>() {
                        if let Ok(session) =
                            SessionMetadata::load(&self.project_dir, SessionId(session_id))
                        {
                            sessions.push(session);
                        }
                    }
                }
            }
        }

        // Sort by ID (which is creation order)
        sessions.sort_by_key(|s| s.id.0);

        Ok(sessions)
    }
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

    /// Whether command was processed successfully
    pub processed: bool,
}

// Internal types for LLM context building
// These are used internally for building LLM request context from events
// and for budget checking. Not part of the primary storage model.

/// Message role in LLM conversation
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageRole {
    System,
    User,
    Assistant,
}

/// A single message in the conversation history (for context building)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_session_id_displays_as_number() {
        // Requirement: SessionId Display trait must format as decimal number.

        let id = SessionId(42);
        assert_eq!(id.to_string(), "42");
    }

    #[test]
    fn test_session_id_parses_from_decimal_string() {
        // Requirement: SessionId must parse from decimal number string.

        let id: SessionId = "123".parse().unwrap();
        assert_eq!(id.as_u64(), 123);
    }

    #[test]
    fn test_token_usage_add_assign_sums_all_fields() {
        // Requirement: TokenUsage += must correctly sum all three token count fields.

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
    fn test_event_timestamp_accessor_returns_event_timestamp() {
        // Requirement: Event::timestamp() must return the timestamp field from the event.

        let now = Utc::now();
        let event = Event::SystemPrompt {
            timestamp: now,
            content: "test".to_string(),
        };
        assert_eq!(event.timestamp(), now);
    }
}
