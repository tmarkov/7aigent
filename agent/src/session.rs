//! Session management for 7aigent.
//!
//! Sessions are stored in `.7aigent/sessions/<session-id>/` with the following structure:
//! - `metadata.json`: Session metadata (created_at, status, etc.)
//! - `history.jsonl`: Conversation history (NDJSON, one message per line)
//! - `screens.jsonl`: Screen states (NDJSON, one screen per step)
//! - `cost.json`: Cost tracking (total, per-step, token usage)

use crate::types::{LlmConfigSnapshot, Message, ScreenState, Session, SessionId, SessionStatus};
use chrono::Utc;
use rust_decimal::Decimal;
use std::fs;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::PathBuf;
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

/// Session manager handles persistence and lifecycle of sessions
pub struct SessionManager {
    project_dir: PathBuf,
}

impl SessionManager {
    /// Create a new session manager for the given project directory
    pub fn new(project_dir: PathBuf) -> Result<Self> {
        if !project_dir.is_dir() {
            return Err(SessionError::InvalidProjectDir);
        }
        Ok(Self { project_dir })
    }

    /// Get the sessions directory (`.7aigent/sessions/`)
    fn sessions_dir(&self) -> PathBuf {
        self.project_dir.join(".7aigent").join("sessions")
    }

    /// Get the directory for a specific session
    fn session_dir(&self, session_id: SessionId) -> PathBuf {
        self.sessions_dir().join(session_id.to_string())
    }

    /// Create a new session
    pub fn create(&self, task: String, llm_config: LlmConfigSnapshot) -> Result<Session> {
        let session_id = SessionId::new();
        let session_dir = self.session_dir(session_id);

        // Check if session already exists
        if session_dir.exists() {
            return Err(SessionError::AlreadyExists(session_id));
        }

        // Create session directory
        fs::create_dir_all(&session_dir)?;

        let now = Utc::now();
        let session = Session {
            id: session_id,
            project_dir: self.project_dir.clone(),
            task,
            created_at: now,
            updated_at: now,
            status: SessionStatus::Active,
            total_cost: Decimal::ZERO,
            token_usage: Default::default(),
            step_count: 0,
            llm_config,
        };

        // Save initial metadata
        self.save_metadata(&session)?;

        // Create empty files for history, screens, and cost tracking
        fs::File::create(session_dir.join("history.jsonl"))?;
        fs::File::create(session_dir.join("screens.jsonl"))?;

        // Initialize cost tracking
        let cost_data = serde_json::json!({
            "total": session.total_cost,
            "token_usage": session.token_usage,
            "per_step": []
        });
        let mut cost_file = BufWriter::new(fs::File::create(session_dir.join("cost.json"))?);
        serde_json::to_writer_pretty(&mut cost_file, &cost_data)?;
        cost_file.flush()?;

        Ok(session)
    }

    /// Load an existing session by ID
    pub fn load(&self, session_id: SessionId) -> Result<Session> {
        let session_dir = self.session_dir(session_id);

        if !session_dir.exists() {
            return Err(SessionError::NotFound(session_id));
        }

        let metadata_path = session_dir.join("metadata.json");
        let metadata_file = fs::File::open(metadata_path)?;
        let session: Session = serde_json::from_reader(metadata_file)?;

        Ok(session)
    }

    /// Save session metadata (called after each step)
    pub fn save_metadata(&self, session: &Session) -> Result<()> {
        let session_dir = self.session_dir(session.id);
        let metadata_path = session_dir.join("metadata.json");

        let mut file = BufWriter::new(fs::File::create(metadata_path)?);
        serde_json::to_writer_pretty(&mut file, session)?;
        file.flush()?;

        Ok(())
    }

    /// Append a message to the conversation history
    pub fn append_message(&self, session_id: SessionId, message: &Message) -> Result<()> {
        let session_dir = self.session_dir(session_id);
        let history_path = session_dir.join("history.jsonl");

        let mut file = fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(history_path)?;

        serde_json::to_writer(&mut file, message)?;
        writeln!(file)?;

        Ok(())
    }

    /// Append a screen state to the screens log
    pub fn append_screen(&self, session_id: SessionId, screen: &ScreenState) -> Result<()> {
        let session_dir = self.session_dir(session_id);
        let screens_path = session_dir.join("screens.jsonl");

        let mut file = fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(screens_path)?;

        serde_json::to_writer(&mut file, screen)?;
        writeln!(file)?;

        Ok(())
    }

    /// Update cost tracking for the session
    pub fn update_cost(
        &self,
        session_id: SessionId,
        total_cost: Decimal,
        token_usage: crate::types::TokenUsage,
        step_cost: Option<(usize, Decimal)>,
    ) -> Result<()> {
        let session_dir = self.session_dir(session_id);
        let cost_path = session_dir.join("cost.json");

        // Read existing cost data
        let cost_file = fs::File::open(&cost_path)?;
        let mut cost_data: serde_json::Value = serde_json::from_reader(cost_file)?;

        // Update total and token usage
        cost_data["total"] = serde_json::json!(total_cost);
        cost_data["token_usage"] = serde_json::to_value(token_usage)?;

        // Append per-step cost if provided
        if let Some((step, step_cost_value)) = step_cost {
            if let Some(per_step) = cost_data["per_step"].as_array_mut() {
                per_step.push(serde_json::json!({
                    "step": step,
                    "cost": step_cost_value
                }));
            }
        }

        // Write back
        let mut file = BufWriter::new(fs::File::create(cost_path)?);
        serde_json::to_writer_pretty(&mut file, &cost_data)?;
        file.flush()?;

        Ok(())
    }

    /// Load conversation history for a session
    pub fn load_history(&self, session_id: SessionId) -> Result<Vec<Message>> {
        let session_dir = self.session_dir(session_id);
        let history_path = session_dir.join("history.jsonl");

        if !history_path.exists() {
            return Ok(Vec::new());
        }

        let file = fs::File::open(history_path)?;
        let reader = BufReader::new(file);
        let mut messages = Vec::new();

        for line in reader.lines() {
            let line = line?;
            if !line.trim().is_empty() {
                let message: Message = serde_json::from_str(&line)?;
                messages.push(message);
            }
        }

        Ok(messages)
    }

    /// Load screen states for a session
    pub fn load_screens(&self, session_id: SessionId) -> Result<Vec<ScreenState>> {
        let session_dir = self.session_dir(session_id);
        let screens_path = session_dir.join("screens.jsonl");

        if !screens_path.exists() {
            return Ok(Vec::new());
        }

        let file = fs::File::open(screens_path)?;
        let reader = BufReader::new(file);
        let mut screens = Vec::new();

        for line in reader.lines() {
            let line = line?;
            if !line.trim().is_empty() {
                let screen: ScreenState = serde_json::from_str(&line)?;
                screens.push(screen);
            }
        }

        Ok(screens)
    }

    /// List all sessions in the project
    pub fn list(&self) -> Result<Vec<Session>> {
        let sessions_dir = self.sessions_dir();

        if !sessions_dir.exists() {
            return Ok(Vec::new());
        }

        let mut sessions = Vec::new();

        for entry in fs::read_dir(sessions_dir)? {
            let entry = entry?;
            let path = entry.path();

            if path.is_dir() {
                if let Some(session_id_str) = path.file_name().and_then(|s| s.to_str()) {
                    if let Ok(session_id) = session_id_str.parse::<SessionId>() {
                        match self.load(session_id) {
                            Ok(session) => sessions.push(session),
                            Err(_) => {
                                // Skip invalid sessions
                                continue;
                            }
                        }
                    }
                }
            }
        }

        // Sort by created_at (newest first)
        sessions.sort_by(|a, b| b.created_at.cmp(&a.created_at));

        Ok(sessions)
    }

    /// Delete a session (useful for cleanup/testing)
    pub fn delete(&self, session_id: SessionId) -> Result<()> {
        let session_dir = self.session_dir(session_id);

        if !session_dir.exists() {
            return Err(SessionError::NotFound(session_id));
        }

        fs::remove_dir_all(session_dir)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{LlmConfigSnapshot, Message, TokenUsage};
    use std::collections::HashMap;
    use tempfile::TempDir;

    fn create_test_manager() -> (SessionManager, TempDir) {
        let temp_dir = TempDir::new().unwrap();
        let manager = SessionManager::new(temp_dir.path().to_path_buf()).unwrap();
        (manager, temp_dir)
    }

    #[test]
    fn test_create_session() {
        let (manager, _temp) = create_test_manager();

        let llm_config = LlmConfigSnapshot {
            endpoint: "https://api.openai.com/v1".to_string(),
            model: "gpt-4".to_string(),
        };

        let session = manager.create("Test task".to_string(), llm_config).unwrap();

        assert_eq!(session.task, "Test task");
        assert_eq!(session.status, SessionStatus::Active);
        assert_eq!(session.step_count, 0);
        assert_eq!(session.total_cost, Decimal::ZERO);

        // Verify files were created
        let session_dir = manager.session_dir(session.id);
        assert!(session_dir.join("metadata.json").exists());
        assert!(session_dir.join("history.jsonl").exists());
        assert!(session_dir.join("screens.jsonl").exists());
        assert!(session_dir.join("cost.json").exists());
    }

    #[test]
    fn test_load_session() {
        let (manager, _temp) = create_test_manager();

        let llm_config = LlmConfigSnapshot {
            endpoint: "https://api.openai.com/v1".to_string(),
            model: "gpt-4".to_string(),
        };

        let created = manager.create("Test task".to_string(), llm_config).unwrap();
        let loaded = manager.load(created.id).unwrap();

        assert_eq!(created.id, loaded.id);
        assert_eq!(created.task, loaded.task);
        assert_eq!(created.status, loaded.status);
    }

    #[test]
    fn test_load_nonexistent_session() {
        let (manager, _temp) = create_test_manager();
        let nonexistent_id = SessionId::new();

        let result = manager.load(nonexistent_id);
        assert!(matches!(result, Err(SessionError::NotFound(_))));
    }

    #[test]
    fn test_append_message() {
        let (manager, _temp) = create_test_manager();

        let llm_config = LlmConfigSnapshot {
            endpoint: "https://api.openai.com/v1".to_string(),
            model: "gpt-4".to_string(),
        };

        let session = manager.create("Test task".to_string(), llm_config).unwrap();

        let msg1 = Message::user("Hello".to_string());
        let msg2 = Message::assistant("Hi there".to_string());

        manager.append_message(session.id, &msg1).unwrap();
        manager.append_message(session.id, &msg2).unwrap();

        let history = manager.load_history(session.id).unwrap();
        assert_eq!(history.len(), 2);
        assert_eq!(history[0].content, "Hello");
        assert_eq!(history[1].content, "Hi there");
    }

    #[test]
    fn test_append_screen() {
        let (manager, _temp) = create_test_manager();

        let llm_config = LlmConfigSnapshot {
            endpoint: "https://api.openai.com/v1".to_string(),
            model: "gpt-4".to_string(),
        };

        let session = manager.create("Test task".to_string(), llm_config).unwrap();

        let screen = ScreenState {
            step: 1,
            timestamp: Utc::now(),
            sections: HashMap::new(),
        };

        manager.append_screen(session.id, &screen).unwrap();

        let screens = manager.load_screens(session.id).unwrap();
        assert_eq!(screens.len(), 1);
        assert_eq!(screens[0].step, 1);
    }

    #[test]
    fn test_update_cost() {
        let (manager, _temp) = create_test_manager();

        let llm_config = LlmConfigSnapshot {
            endpoint: "https://api.openai.com/v1".to_string(),
            model: "gpt-4".to_string(),
        };

        let session = manager.create("Test task".to_string(), llm_config).unwrap();

        let total_cost = Decimal::new(150, 2); // $1.50
        let token_usage = TokenUsage {
            prompt_tokens: 100,
            completion_tokens: 50,
            total_tokens: 150,
        };

        manager
            .update_cost(
                session.id,
                total_cost,
                token_usage,
                Some((1, Decimal::new(50, 2))),
            )
            .unwrap();

        // Verify cost was written
        let cost_path = manager.session_dir(session.id).join("cost.json");
        let cost_file = fs::File::open(cost_path).unwrap();
        let cost_data: serde_json::Value = serde_json::from_reader(cost_file).unwrap();

        assert_eq!(cost_data["total"], serde_json::json!(total_cost));
    }

    #[test]
    fn test_list_sessions() {
        let (manager, _temp) = create_test_manager();

        let llm_config = LlmConfigSnapshot {
            endpoint: "https://api.openai.com/v1".to_string(),
            model: "gpt-4".to_string(),
        };

        // Create multiple sessions
        manager
            .create("Task 1".to_string(), llm_config.clone())
            .unwrap();
        manager
            .create("Task 2".to_string(), llm_config.clone())
            .unwrap();
        manager.create("Task 3".to_string(), llm_config).unwrap();

        let sessions = manager.list().unwrap();
        assert_eq!(sessions.len(), 3);

        // Verify sorted by created_at (newest first)
        assert!(sessions[0].created_at >= sessions[1].created_at);
        assert!(sessions[1].created_at >= sessions[2].created_at);
    }

    #[test]
    fn test_delete_session() {
        let (manager, _temp) = create_test_manager();

        let llm_config = LlmConfigSnapshot {
            endpoint: "https://api.openai.com/v1".to_string(),
            model: "gpt-4".to_string(),
        };

        let session = manager.create("Test task".to_string(), llm_config).unwrap();

        manager.delete(session.id).unwrap();

        let result = manager.load(session.id);
        assert!(matches!(result, Err(SessionError::NotFound(_))));
    }

    #[test]
    fn test_save_metadata() {
        let (manager, _temp) = create_test_manager();

        let llm_config = LlmConfigSnapshot {
            endpoint: "https://api.openai.com/v1".to_string(),
            model: "gpt-4".to_string(),
        };

        let mut session = manager.create("Test task".to_string(), llm_config).unwrap();

        // Modify session
        session.status = SessionStatus::Completed;
        session.step_count = 10;
        session.total_cost = Decimal::new(250, 2); // $2.50

        manager.save_metadata(&session).unwrap();

        // Load and verify
        let loaded = manager.load(session.id).unwrap();
        assert_eq!(loaded.status, SessionStatus::Completed);
        assert_eq!(loaded.step_count, 10);
        assert_eq!(loaded.total_cost, Decimal::new(250, 2));
    }
}
