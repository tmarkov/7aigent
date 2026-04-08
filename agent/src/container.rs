//! Sandbox management for spawning and communicating with the orchestrator.

use crate::config::SandboxConfig;
use crate::types::{CommandResponse, ScreenSection, ScreenState};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use thiserror::Error;

/// Auxiliary LLM request from orchestrator
#[derive(Debug, Clone)]
pub struct AuxiliaryLlmRequest {
    pub request_id: String,
    pub prompt: String,
    pub context: Option<String>,
}

/// Message from orchestrator
#[derive(Debug)]
pub enum OrchestratorMessage {
    /// Regular command response with screen  state
    CommandResponse(CommandResponse, ScreenState),
    /// Auxiliary LLM query request
    AuxiliaryLlmRequest(AuxiliaryLlmRequest),
}

#[derive(Debug, Error)]
pub enum ContainerError {
    #[error("Failed to spawn sandbox: {0}")]
    SpawnError(#[from] std::io::Error),

    #[error("Failed to send command to sandbox: {0}")]
    SendError(String),

    #[error("Failed to receive response from sandbox: {0}")]
    ReceiveError(String),

    #[error("Orchestrator returned error: {0}")]
    OrchestratorError(String),

    #[error("Invalid message format")]
    InvalidMessage,

    #[error("Sandbox process terminated unexpectedly")]
    ProcessTerminated,

    #[error("Sandbox script not found at {path}")]
    SandboxNotFound { path: PathBuf },
}

pub type Result<T> = std::result::Result<T, ContainerError>;

/// Manages sandbox lifecycle
pub struct ContainerManager {
    sandbox_path: PathBuf,
}

impl ContainerManager {
    /// Create a new container manager
    ///
    /// Reads sandbox path from SANDBOX_PATH environment variable (set by Nix wrapper),
    /// or falls back to looking for "7aigent-sandbox" in PATH.
    pub fn new() -> Result<Self> {
        let sandbox_path = std::env::var("SANDBOX_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("7aigent-sandbox"));

        Ok(Self { sandbox_path })
    }

    /// Spawn the sandbox with the orchestrator
    ///
    /// Returns a handle for communicating with the orchestrator
    pub fn spawn_container(
        &self,
        project_dir: &Path,
        config: &SandboxConfig,
    ) -> Result<ContainerHandle> {
        let mut cmd = Command::new(&self.sandbox_path);

        // First argument: project directory
        cmd.arg(project_dir);

        // Optional: disable network if configured (default: true)
        if config.disable_network.unwrap_or(true) {
            cmd.arg("--unshare-net");
        }

        // Pass shell_prefix to orchestrator via environment variable
        if let Some(prefix) = &config.shell_prefix {
            cmd.env("SHELL_PREFIX", prefix);
        }

        // Spawn with stdin/stdout pipes
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| {
                if e.kind() == std::io::ErrorKind::NotFound {
                    ContainerError::SandboxNotFound {
                        path: self.sandbox_path.clone(),
                    }
                } else {
                    ContainerError::from(e)
                }
            })?;

        let stdin = child.stdin.take().ok_or_else(|| {
            ContainerError::SpawnError(std::io::Error::other("failed to capture stdin"))
        })?;

        let stdout = child.stdout.take().ok_or_else(|| {
            ContainerError::SpawnError(std::io::Error::other("failed to capture stdout"))
        })?;

        Ok(ContainerHandle {
            child: Some(child),
            stdin: Some(BufWriter::new(stdin)),
            stdout: BufReader::new(stdout),
        })
    }
}

impl Default for ContainerManager {
    fn default() -> Self {
        Self::new().expect("failed to create container manager")
    }
}

/// Handle for communicating with a running container
pub struct ContainerHandle {
    child: Option<Child>,
    stdin: Option<BufWriter<std::process::ChildStdin>>,
    stdout: BufReader<std::process::ChildStdout>,
}

impl ContainerHandle {
    /// Send a command to the orchestrator
    pub fn send_command(&mut self, env: &str, command: &str) -> Result<()> {
        let message = serde_json::json!({
            "env": env,
            "command": command,
        });

        let stdin = self.stdin.as_mut().ok_or(ContainerError::SendError(
            "stdin already closed".to_string(),
        ))?;

        serde_json::to_writer(&mut *stdin, &message)
            .map_err(|e| ContainerError::SendError(e.to_string()))?;

        stdin
            .write_all(b"\n")
            .map_err(|e| ContainerError::SendError(e.to_string()))?;

        stdin
            .flush()
            .map_err(|e| ContainerError::SendError(e.to_string()))?;

        Ok(())
    }

    /// Receive a message from the orchestrator
    pub fn receive_message(&mut self) -> Result<OrchestratorMessage> {
        let mut line = String::new();
        let bytes_read = self
            .stdout
            .read_line(&mut line)
            .map_err(|e| ContainerError::ReceiveError(e.to_string()))?;

        if bytes_read == 0 {
            return Err(ContainerError::ProcessTerminated);
        }

        let message: serde_json::Value = serde_json::from_str(&line)
            .map_err(|e| ContainerError::ReceiveError(format!("invalid JSON: {}", e)))?;

        // Check message type
        match message["type"].as_str() {
            Some("error") => Err(ContainerError::OrchestratorError(
                message["message"]
                    .as_str()
                    .ok_or(ContainerError::InvalidMessage)?
                    .to_string(),
            )),
            Some("auxiliary_llm_request") => {
                // Parse auxiliary request
                let request_id = message["request_id"]
                    .as_str()
                    .ok_or(ContainerError::InvalidMessage)?
                    .to_string();
                let prompt = message["prompt"]
                    .as_str()
                    .ok_or(ContainerError::InvalidMessage)?
                    .to_string();
                let context = message["context"].as_str().map(|s| s.to_string());

                Ok(OrchestratorMessage::AuxiliaryLlmRequest(
                    AuxiliaryLlmRequest {
                        request_id,
                        prompt,
                        context,
                    },
                ))
            }
            _ => {
                // Parse regular command response
                let response = CommandResponse {
                    output: message["response"]["output"]
                        .as_str()
                        .ok_or(ContainerError::InvalidMessage)?
                        .to_string(),
                    processed: message["response"]["processed"]
                        .as_bool()
                        .ok_or(ContainerError::InvalidMessage)?,
                    exit_code: message["response"]["exit_code"].as_i64().map(|v| v as i32),
                };

                let screen = parse_screen(&message["screen"])?;

                Ok(OrchestratorMessage::CommandResponse(response, screen))
            }
        }
    }

    /// Send auxiliary LLM response back to orchestrator
    pub fn send_auxiliary_response(
        &mut self,
        request_id: &str,
        response: std::result::Result<String, String>,
    ) -> Result<()> {
        let message = match response {
            Ok(text) => serde_json::json!({
                "type": "auxiliary_llm_response",
                "request_id": request_id,
                "response": text,
            }),
            Err(error) => serde_json::json!({
                "type": "auxiliary_llm_response",
                "request_id": request_id,
                "error": error,
            }),
        };

        let stdin = self.stdin.as_mut().ok_or(ContainerError::SendError(
            "stdin already closed".to_string(),
        ))?;

        serde_json::to_writer(&mut *stdin, &message)
            .map_err(|e| ContainerError::SendError(e.to_string()))?;

        stdin
            .write_all(b"\n")
            .map_err(|e| ContainerError::SendError(e.to_string()))?;

        stdin
            .flush()
            .map_err(|e| ContainerError::SendError(e.to_string()))?;

        Ok(())
    }

    /// Receive a response from the orchestrator
    ///
    /// This is a simple wrapper that expects only command responses.
    /// The agent itself handles auxiliary requests properly via receive_with_aux_handling.
    pub fn receive_response(&mut self) -> Result<(CommandResponse, ScreenState)> {
        match self.receive_message()? {
            OrchestratorMessage::CommandResponse(response, screen) => Ok((response, screen)),
            OrchestratorMessage::AuxiliaryLlmRequest(_request) => {
                // In tests, we don't expect auxiliary requests
                // The agent handles these properly via receive_with_aux_handling
                Err(ContainerError::InvalidMessage)
            }
        }
    }

    /// Shutdown the sandbox gracefully
    pub fn shutdown(mut self) -> Result<()> {
        // Close stdin to send EOF to orchestrator
        // Must happen BEFORE waiting for process to exit
        self.stdin = None;

        // Wait for process to exit
        if let Some(mut child) = self.child.take() {
            let status = child.wait().map_err(|e| {
                ContainerError::SendError(format!("failed to wait for sandbox: {}", e))
            })?;

            if !status.success() {
                eprintln!("Warning: sandbox exited with status: {}", status);
            }
        }

        Ok(())
    }
}

impl Drop for ContainerHandle {
    fn drop(&mut self) {
        // Ensure child process is killed if dropped without explicit shutdown
        if let Some(child) = &mut self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// Parse screen state from JSON value
///
/// Note: The orchestrator doesn't send step and timestamp in the screen message.
/// These are added by the agent when saving to session.
/// The raw format is: {"bash": {"content": "..."}, ...}
fn parse_screen(screen_value: &serde_json::Value) -> Result<ScreenState> {
    let sections_obj = screen_value
        .as_object()
        .ok_or(ContainerError::InvalidMessage)?;

    let mut sections = HashMap::new();
    for (env_name, section_value) in sections_obj {
        let content = section_value["content"]
            .as_str()
            .ok_or(ContainerError::InvalidMessage)?
            .to_string();

        sections.insert(env_name.clone(), ScreenSection { content });
    }

    // Create ScreenState with timestamp (step field removed in new design)
    Ok(ScreenState {
        timestamp: chrono::Utc::now(),
        sections,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_screen() {
        let screen_json = serde_json::json!({
            "bash": {
                "content": "$ ls\nfile1.txt\nfile2.txt\n"
            }
        });

        let screen = parse_screen(&screen_json).unwrap();
        assert_eq!(screen.sections.len(), 1);
        assert!(screen.sections.contains_key("bash"));

        let bash_section = &screen.sections["bash"];
        assert_eq!(bash_section.content, "$ ls\nfile1.txt\nfile2.txt\n");
    }

    #[test]
    fn test_parse_screen_invalid_format() {
        let screen_json = serde_json::json!("not an object");

        let result = parse_screen(&screen_json);
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_screen_missing_content() {
        let screen_json = serde_json::json!({
            "bash": {}
        });

        let result = parse_screen(&screen_json);
        assert!(result.is_err());
    }
}
