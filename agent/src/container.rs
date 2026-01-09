//! Container management for spawning and communicating with the orchestrator.

use crate::config::SandboxConfig;
use crate::types::{CommandResponse, ScreenSection, ScreenState};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ContainerError {
    #[error("Failed to build container image: {0}")]
    BuildError(String),

    #[error("Failed to spawn container: {0}")]
    SpawnError(#[from] std::io::Error),

    #[error("Failed to send command to container: {0}")]
    SendError(String),

    #[error("Failed to receive response from container: {0}")]
    ReceiveError(String),

    #[error("Orchestrator returned error: {0}")]
    OrchestratorError(String),

    #[error("Invalid message format")]
    InvalidMessage,

    #[error("Container process terminated unexpectedly")]
    ProcessTerminated,
}

pub type Result<T> = std::result::Result<T, ContainerError>;

/// Manages container lifecycle and image building
pub struct ContainerManager;

impl ContainerManager {
    /// Create a new container manager
    pub fn new() -> Self {
        Self
    }

    /// Build the container image from Nix derivation
    ///
    /// Returns the image tag loaded into Podman
    pub fn build_container_image(&self) -> Result<String> {
        // Build the OCI image using Nix
        let output = Command::new("nix")
            .args(["build", ".#orchestratorContainer", "--print-out-paths"])
            .output()
            .map_err(|e| ContainerError::BuildError(format!("nix build failed: {}", e)))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(ContainerError::BuildError(format!(
                "nix build failed: {}",
                stderr
            )));
        }

        let image_path = String::from_utf8(output.stdout)
            .map_err(|e| ContainerError::BuildError(format!("invalid output: {}", e)))?
            .trim()
            .to_string();

        // Load image into Podman
        let load_output = Command::new("podman")
            .args(["load", "-i", &format!("{}/image.tar", image_path)])
            .output()
            .map_err(|e| ContainerError::BuildError(format!("podman load failed: {}", e)))?;

        if !load_output.status.success() {
            let stderr = String::from_utf8_lossy(&load_output.stderr);
            return Err(ContainerError::BuildError(format!(
                "podman load failed: {}",
                stderr
            )));
        }

        Ok("7aigent-orchestrator:latest".to_string())
    }

    /// Spawn a container with the orchestrator
    ///
    /// Returns a handle for communicating with the orchestrator
    pub fn spawn_container(
        &self,
        image: &str,
        project_dir: &Path,
        config: &SandboxConfig,
    ) -> Result<ContainerHandle> {
        let mut cmd = Command::new("podman");

        cmd.args([
            "run",
            "--rm",           // Remove after exit
            "-i",             // Interactive (stdin)
            "--network=none", // No network by default
        ]);

        // Resource limits
        if let Some(mem) = &config.resources.max_memory {
            cmd.args(["--memory", mem]);
        }

        if let Some(cpus) = &config.resources.max_cpus {
            cmd.args(["--cpus", cpus]);
        }

        // Mount project directory
        cmd.args([
            "--mount",
            &format!(
                "type=bind,source={},target=/workspace",
                project_dir.display()
            ),
        ]);

        // Environment variables
        cmd.args(["-e", "PROJECT_DIR=/workspace"]);

        // Image name
        cmd.arg(image);

        // Spawn with stdin/stdout pipes
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;

        let stdin = child.stdin.take().ok_or_else(|| {
            ContainerError::SpawnError(std::io::Error::other("failed to capture stdin"))
        })?;

        let stdout = child.stdout.take().ok_or_else(|| {
            ContainerError::SpawnError(std::io::Error::other("failed to capture stdout"))
        })?;

        Ok(ContainerHandle {
            child,
            stdin: BufWriter::new(stdin),
            stdout: BufReader::new(stdout),
        })
    }
}

impl Default for ContainerManager {
    fn default() -> Self {
        Self::new()
    }
}

/// Handle for communicating with a running container
pub struct ContainerHandle {
    child: Child,
    stdin: BufWriter<std::process::ChildStdin>,
    stdout: BufReader<std::process::ChildStdout>,
}

impl ContainerHandle {
    /// Send a command to the orchestrator
    pub fn send_command(&mut self, env: &str, command: &str) -> Result<()> {
        let message = serde_json::json!({
            "type": "command",
            "environment": env,
            "command": command,
        });

        serde_json::to_writer(&mut self.stdin, &message)
            .map_err(|e| ContainerError::SendError(e.to_string()))?;

        self.stdin
            .write_all(b"\n")
            .map_err(|e| ContainerError::SendError(e.to_string()))?;

        self.stdin
            .flush()
            .map_err(|e| ContainerError::SendError(e.to_string()))?;

        Ok(())
    }

    /// Receive a response from the orchestrator
    pub fn receive_response(&mut self) -> Result<(CommandResponse, ScreenState)> {
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

        match message["type"].as_str() {
            Some("response") => {
                let response = CommandResponse {
                    output: message["response"]["output"]
                        .as_str()
                        .ok_or(ContainerError::InvalidMessage)?
                        .to_string(),
                    success: message["response"]["success"]
                        .as_bool()
                        .ok_or(ContainerError::InvalidMessage)?,
                };

                let screen = parse_screen(&message["screen"])?;

                Ok((response, screen))
            }
            Some("error") => Err(ContainerError::OrchestratorError(
                message["message"]
                    .as_str()
                    .ok_or(ContainerError::InvalidMessage)?
                    .to_string(),
            )),
            _ => Err(ContainerError::InvalidMessage),
        }
    }

    /// Shutdown the container gracefully
    pub fn shutdown(mut self) -> Result<()> {
        // Send shutdown command if orchestrator supports it
        // For now, just kill the process
        self.child
            .kill()
            .map_err(|e| ContainerError::SendError(format!("failed to kill container: {}", e)))?;

        self.child.wait().map_err(|e| {
            ContainerError::SendError(format!("failed to wait for container: {}", e))
        })?;

        Ok(())
    }
}

/// Parse screen state from JSON value
fn parse_screen(screen_value: &serde_json::Value) -> Result<ScreenState> {
    let step = screen_value["step"]
        .as_u64()
        .ok_or(ContainerError::InvalidMessage)? as usize;

    let timestamp_str = screen_value["timestamp"]
        .as_str()
        .ok_or(ContainerError::InvalidMessage)?;

    let timestamp = chrono::DateTime::parse_from_rfc3339(timestamp_str)
        .map_err(|_| ContainerError::InvalidMessage)?
        .with_timezone(&chrono::Utc);

    let sections_obj = screen_value["sections"]
        .as_object()
        .ok_or(ContainerError::InvalidMessage)?;

    let mut sections = HashMap::new();
    for (env_name, section_value) in sections_obj {
        let content = section_value["content"]
            .as_str()
            .ok_or(ContainerError::InvalidMessage)?
            .to_string();

        let max_lines = section_value["max_lines"]
            .as_u64()
            .ok_or(ContainerError::InvalidMessage)? as usize;

        sections.insert(env_name.clone(), ScreenSection { content, max_lines });
    }

    Ok(ScreenState {
        step,
        timestamp,
        sections,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_screen() {
        let screen_json = serde_json::json!({
            "step": 1,
            "timestamp": "2026-01-09T10:00:00Z",
            "sections": {
                "bash": {
                    "content": "$ ls\nfile1.txt\nfile2.txt\n",
                    "max_lines": 50
                }
            }
        });

        let screen = parse_screen(&screen_json).unwrap();
        assert_eq!(screen.step, 1);
        assert_eq!(screen.sections.len(), 1);
        assert!(screen.sections.contains_key("bash"));

        let bash_section = &screen.sections["bash"];
        assert_eq!(bash_section.content, "$ ls\nfile1.txt\nfile2.txt\n");
        assert_eq!(bash_section.max_lines, 50);
    }

    #[test]
    fn test_parse_screen_invalid_step() {
        let screen_json = serde_json::json!({
            "step": "not a number",
            "timestamp": "2026-01-09T10:00:00Z",
            "sections": {}
        });

        let result = parse_screen(&screen_json);
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_screen_invalid_timestamp() {
        let screen_json = serde_json::json!({
            "step": 1,
            "timestamp": "invalid timestamp",
            "sections": {}
        });

        let result = parse_screen(&screen_json);
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_screen_missing_sections() {
        let screen_json = serde_json::json!({
            "step": 1,
            "timestamp": "2026-01-09T10:00:00Z"
        });

        let result = parse_screen(&screen_json);
        assert!(result.is_err());
    }
}
