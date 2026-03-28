use clap::{Parser, Subcommand};
use std::path::PathBuf;

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
        /// Session ID to resume (defaults to last session if not provided)
        #[arg(value_name = "SESSION_ID")]
        session_id: Option<u64>,
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
        /// Session ID to inspect (defaults to last session if not provided)
        #[arg(value_name = "SESSION_ID")]
        session_id: Option<u64>,

        /// Show full input context + LLM reply for call N
        #[arg(long, value_name = "N")]
        call: Option<usize>,

        /// Show all LLM replies in sequence
        #[arg(long)]
        replies: bool,

        /// Show LLM reply + commands + screen after call N (use with --call N)
        #[arg(long, value_name = "N")]
        after: Option<usize>,

        /// List all LLM calls in the session
        #[arg(long)]
        calls: bool,

        /// Show screen state after LLM message N
        #[arg(long, value_name = "N")]
        screen: Option<usize>,
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

    /// Validate that the CLI arguments are consistent.
    ///
    /// Running with no arguments is valid and enters interactive mode.
    pub fn validate(&self) -> anyhow::Result<()> {
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
        let cli = Cli::parse_from(["7aigent", "resume", "42"]);
        match cli.command {
            Some(Commands::Resume { session_id }) => {
                assert_eq!(session_id, Some(42))
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
    fn test_parse_inspect_defaults_to_no_flags() {
        let cli = Cli::parse_from(["7aigent", "inspect", "42"]);
        match cli.command {
            Some(Commands::Inspect {
                session_id,
                call,
                replies,
                after,
                calls,
                screen,
            }) => {
                assert_eq!(session_id, Some(42));
                assert!(call.is_none());
                assert!(!replies);
                assert!(after.is_none());
                assert!(!calls);
                assert!(screen.is_none());
            }
            _ => panic!("Expected Inspect command"),
        }
    }

    #[test]
    fn test_parse_inspect_with_call() {
        let cli = Cli::parse_from(["7aigent", "inspect", "42", "--call", "3"]);
        match cli.command {
            Some(Commands::Inspect {
                session_id,
                call,
                replies,
                after,
                calls,
                screen,
            }) => {
                assert_eq!(session_id, Some(42));
                assert_eq!(call, Some(3));
                assert!(!replies);
                assert!(after.is_none());
                assert!(!calls);
                assert!(screen.is_none());
            }
            _ => panic!("Expected Inspect command"),
        }
    }

    #[test]
    fn test_parse_inspect_replies() {
        let cli = Cli::parse_from(["7aigent", "inspect", "42", "--replies"]);
        match cli.command {
            Some(Commands::Inspect {
                session_id,
                replies,
                ..
            }) => {
                assert_eq!(session_id, Some(42));
                assert!(replies);
            }
            _ => panic!("Expected Inspect command"),
        }
    }

    #[test]
    fn test_parse_inspect_with_after() {
        let cli = Cli::parse_from(["7aigent", "inspect", "42", "--after", "3"]);
        match cli.command {
            Some(Commands::Inspect {
                session_id, after, ..
            }) => {
                assert_eq!(session_id, Some(42));
                assert_eq!(after, Some(3));
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
    fn test_parse_resume_without_session_id() {
        let cli = Cli::parse_from(["7aigent", "resume"]);
        match cli.command {
            Some(Commands::Resume { session_id }) => {
                assert!(session_id.is_none());
            }
            _ => panic!("Expected Resume command"),
        }
    }

    #[test]
    fn test_parse_inspect_without_session_id() {
        let cli = Cli::parse_from(["7aigent", "inspect"]);
        match cli.command {
            Some(Commands::Inspect {
                session_id,
                call,
                replies,
                after,
                calls,
                screen,
            }) => {
                assert!(session_id.is_none());
                assert!(call.is_none());
                assert!(!replies);
                assert!(after.is_none());
                assert!(!calls);
                assert!(screen.is_none());
            }
            _ => panic!("Expected Inspect command"),
        }
    }

    #[test]
    fn test_parse_inspect_with_calls() {
        let cli = Cli::parse_from(["7aigent", "inspect", "42", "--calls"]);
        match cli.command {
            Some(Commands::Inspect {
                session_id, calls, ..
            }) => {
                assert_eq!(session_id, Some(42));
                assert!(calls);
            }
            _ => panic!("Expected Inspect command"),
        }
    }

    #[test]
    fn test_parse_inspect_with_screen() {
        let cli = Cli::parse_from(["7aigent", "inspect", "42", "--screen", "3"]);
        match cli.command {
            Some(Commands::Inspect {
                session_id, screen, ..
            }) => {
                assert_eq!(session_id, Some(42));
                assert_eq!(screen, Some(3));
            }
            _ => panic!("Expected Inspect command"),
        }
    }

    #[test]
    fn test_parse_inspect_calls_without_session_id() {
        let cli = Cli::parse_from(["7aigent", "inspect", "--calls"]);
        match cli.command {
            Some(Commands::Inspect {
                session_id, calls, ..
            }) => {
                assert!(session_id.is_none());
                assert!(calls);
            }
            _ => panic!("Expected Inspect command"),
        }
    }
    #[test]
    fn test_validate_no_args_succeeds_for_interactive_mode() {
        // Requirement: Running with no arguments must succeed (enters interactive mode).
        let cli = Cli::parse_from(["7aigent"]);
        assert!(cli.validate().is_ok());
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
