use clap::{Parser, Subcommand};
use std::path::PathBuf;
use uuid::Uuid;

/// 7aigent - AI agent for software development tasks
#[derive(Parser, Debug)]
#[command(name = "7aigent")]
#[command(about = "AI agent for software development tasks", long_about = None)]
#[command(version)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Commands>,

    /// The task to execute (when no subcommand is given)
    #[arg(value_name = "TASK")]
    pub task: Option<String>,

    /// Project directory (defaults to current directory)
    #[arg(short = 'C', long, value_name = "DIR")]
    pub project_dir: Option<PathBuf>,

    /// Config file to use (defaults to .7aigent.toml in project dir)
    #[arg(short, long, value_name = "FILE")]
    pub config: Option<PathBuf>,
}

#[derive(Subcommand, Debug)]
pub enum Commands {
    /// Resume a paused session
    Resume {
        /// Session ID to resume
        session_id: Uuid,
    },

    /// List all sessions in the project
    List {
        /// Show only sessions with this status
        #[arg(short, long, value_name = "STATUS")]
        status: Option<String>,

        /// Show full session details
        #[arg(short, long)]
        verbose: bool,
    },

    /// Inspect a session's history
    Inspect {
        /// Session ID to inspect
        session_id: Uuid,

        /// Show only this step number (0-indexed)
        #[arg(short, long, value_name = "N")]
        step: Option<usize>,

        /// Show screen states
        #[arg(short = 'S', long)]
        show_screens: bool,
    },

    /// Initialize a new project with a .7aigent.toml config file
    Init {
        /// Overwrite existing config file
        #[arg(short, long)]
        force: bool,
    },
}

impl Cli {
    /// Parse CLI arguments from the environment
    pub fn parse_args() -> Self {
        Cli::parse()
    }

    /// Validate that the CLI arguments are consistent
    pub fn validate(&self) -> anyhow::Result<()> {
        // Either a task or a subcommand must be provided
        if self.task.is_none() && self.command.is_none() {
            anyhow::bail!("Either provide a task or use a subcommand (--help for usage)");
        }

        // Can't provide both a task and a subcommand
        if self.task.is_some() && self.command.is_some() {
            anyhow::bail!("Cannot provide both a task and a subcommand");
        }

        Ok(())
    }

    /// Get the project directory, defaulting to current directory
    pub fn get_project_dir(&self) -> anyhow::Result<PathBuf> {
        if let Some(ref dir) = self.project_dir {
            Ok(dir.clone())
        } else {
            std::env::current_dir()
                .map_err(|e| anyhow::anyhow!("Failed to get current directory: {}", e))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_task() {
        let cli = Cli::parse_from(["7aigent", "implement feature X"]);
        assert_eq!(cli.task, Some("implement feature X".to_string()));
        assert!(cli.command.is_none());
    }

    #[test]
    fn test_parse_resume() {
        let session_id = crate::types::SessionId::new();
        let cli = Cli::parse_from(["7aigent", "resume", &session_id.to_string()]);
        match cli.command {
            Some(Commands::Resume { session_id: id }) => {
                assert_eq!(id, session_id.as_uuid().to_owned())
            }
            _ => panic!("Expected Resume command"),
        }
    }

    #[test]
    fn test_parse_list() {
        let cli = Cli::parse_from(["7aigent", "list"]);
        match cli.command {
            Some(Commands::List { status, verbose }) => {
                assert!(status.is_none());
                assert!(!verbose);
            }
            _ => panic!("Expected List command"),
        }
    }

    #[test]
    fn test_parse_list_with_options() {
        let cli = Cli::parse_from(["7aigent", "list", "--status", "active", "--verbose"]);
        match cli.command {
            Some(Commands::List { status, verbose }) => {
                assert_eq!(status, Some("active".to_string()));
                assert!(verbose);
            }
            _ => panic!("Expected List command"),
        }
    }

    #[test]
    fn test_parse_inspect() {
        let session_id = crate::types::SessionId::new();
        let cli = Cli::parse_from(["7aigent", "inspect", &session_id.to_string()]);
        match cli.command {
            Some(Commands::Inspect {
                session_id: id,
                step,
                show_screens,
            }) => {
                assert_eq!(id, session_id.as_uuid().to_owned());
                assert!(step.is_none());
                assert!(!show_screens);
            }
            _ => panic!("Expected Inspect command"),
        }
    }

    #[test]
    fn test_parse_inspect_with_step() {
        let session_id = crate::types::SessionId::new();
        let cli = Cli::parse_from([
            "7aigent",
            "inspect",
            &session_id.to_string(),
            "--step",
            "5",
            "--show-screens",
        ]);
        match cli.command {
            Some(Commands::Inspect {
                session_id: id,
                step,
                show_screens,
            }) => {
                assert_eq!(id, session_id.as_uuid().to_owned());
                assert_eq!(step, Some(5));
                assert!(show_screens);
            }
            _ => panic!("Expected Inspect command"),
        }
    }

    #[test]
    fn test_parse_init() {
        let cli = Cli::parse_from(["7aigent", "init"]);
        match cli.command {
            Some(Commands::Init { force }) => {
                assert!(!force);
            }
            _ => panic!("Expected Init command"),
        }
    }

    #[test]
    fn test_parse_init_force() {
        let cli = Cli::parse_from(["7aigent", "init", "--force"]);
        match cli.command {
            Some(Commands::Init { force }) => {
                assert!(force);
            }
            _ => panic!("Expected Init command"),
        }
    }

    #[test]
    fn test_validate_no_args_fails() {
        let cli = Cli::parse_from(["7aigent"]);
        assert!(cli.validate().is_err());
    }

    #[test]
    fn test_validate_task_ok() {
        let cli = Cli::parse_from(["7aigent", "some task"]);
        assert!(cli.validate().is_ok());
    }

    #[test]
    fn test_validate_subcommand_ok() {
        let cli = Cli::parse_from(["7aigent", "list"]);
        assert!(cli.validate().is_ok());
    }
}
