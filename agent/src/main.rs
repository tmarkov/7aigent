//! Main entry point for the 7aigent CLI.

use agent::{
    cli::{Cli, Commands},
    config::ConfigLoader,
    container::ContainerManager,
    llm::openai::OpenAiCompatibleClient,
    types::{Session, SessionId, SessionStatus},
    ui, Agent,
};
use anyhow::{Context, Result};
use std::path::Path;

#[tokio::main]
async fn main() {
    if let Err(e) = run().await {
        ui::display_error(&e);
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let cli = Cli::parse_args();
    cli.validate()?;

    let project_dir = cli.get_project_dir()?;

    match cli.command {
        Some(Commands::Init { force }) => {
            handle_init(&project_dir, force)?;
        }
        Some(Commands::List { status, verbose }) => {
            handle_list(&project_dir, status, verbose)?;
        }
        Some(Commands::Inspect {
            session_id,
            step,
            show_screens,
        }) => {
            handle_inspect(&project_dir, session_id, step, show_screens)?;
        }
        Some(Commands::Resume { session_id }) => {
            handle_resume(&project_dir, session_id).await?;
        }
        None => {
            // New task
            let task = cli
                .task
                .context("Task is required (this should be caught by CLI validation)")?;
            handle_new_task(&project_dir, &task).await?;
        }
    }

    Ok(())
}

/// Handle the init command - create a .7aigent.toml template
fn handle_init(project_dir: &Path, force: bool) -> Result<()> {
    let config_path = project_dir.join(".7aigent.toml");

    if config_path.exists() && !force {
        anyhow::bail!(
            "Config file already exists at {}. Use --force to overwrite.",
            config_path.display()
        );
    }

    let template = include_str!("../templates/config.toml");
    std::fs::write(&config_path, template).context("Failed to write config template")?;

    println!("✓ Created config file at {}", config_path.display());
    println!();
    println!("Edit this file to configure:");
    println!("  - LLM endpoint and model");
    println!("  - Budget limits");
    println!("  - Sandbox restrictions");
    println!();
    println!("Set your API key:");
    println!("  export OPENAI_API_KEY=your-key-here");

    Ok(())
}

/// Handle the list command - list all sessions
fn handle_list(project_dir: &Path, status_filter: Option<String>, verbose: bool) -> Result<()> {
    let sessions_dir = project_dir.join(".7aigent").join("sessions");

    if !sessions_dir.exists() {
        println!("No sessions found.");
        return Ok(());
    }

    let mut sessions = Vec::new();

    for entry in std::fs::read_dir(&sessions_dir)? {
        let entry = entry?;
        let path = entry.path();

        if path.is_dir() {
            let session_id_str = path
                .file_name()
                .and_then(|n| n.to_str())
                .context("Invalid session directory name")?;

            let session_id = SessionId::parse_str(session_id_str)
                .context("Invalid session ID in directory name")?;

            match Session::load(project_dir, session_id) {
                Ok(session) => {
                    // Apply status filter if provided
                    if let Some(ref filter) = status_filter {
                        let status_matches = match filter.to_lowercase().as_str() {
                            "active" => session.status == SessionStatus::Active,
                            "paused" => session.status == SessionStatus::Paused,
                            "completed" => session.status == SessionStatus::Completed,
                            "failed" => session.status == SessionStatus::Failed,
                            _ => {
                                anyhow::bail!("Invalid status filter: {}", filter);
                            }
                        };

                        if !status_matches {
                            continue;
                        }
                    }

                    sessions.push(session);
                }
                Err(e) => {
                    eprintln!("Warning: Failed to load session {}: {}", session_id, e);
                }
            }
        }
    }

    if sessions.is_empty() {
        println!("No sessions found.");
        return Ok(());
    }

    // Sort by creation time (newest first)
    sessions.sort_by(|a, b| b.created_at.cmp(&a.created_at));

    println!("Sessions:");
    println!();

    for session in sessions {
        if verbose {
            println!("Session ID: {}", session.id);
            println!("  Task: {}", session.task);
            println!("  Status: {:?}", session.status);
            println!("  Created: {}", session.created_at);
            println!("  Updated: {}", session.updated_at);
            println!("  Steps: {}", session.step_count);
            println!("  Total Cost: ${:.6}", session.total_cost);
            println!();
        } else {
            println!(
                "{} [{:?}] {} - ${:.4} ({} steps)",
                session.id, session.status, session.task, session.total_cost, session.step_count
            );
        }
    }

    Ok(())
}

/// Handle the inspect command - show session details
fn handle_inspect(
    project_dir: &Path,
    session_id: uuid::Uuid,
    step: Option<usize>,
    show_screens: bool,
) -> Result<()> {
    let session_id = SessionId::from(session_id);
    let session = Session::load(project_dir, session_id)?;

    println!("Session: {}", session.id);
    println!("Task: {}", session.task);
    println!("Status: {:?}", session.status);
    println!("Created: {}", session.created_at);
    println!("Updated: {}", session.updated_at);
    println!("Steps: {}", session.step_count);
    println!("Total Cost: ${:.6}", session.total_cost);
    println!(
        "Tokens: {} prompt + {} completion = {} total",
        session.token_usage.prompt_tokens,
        session.token_usage.completion_tokens,
        session.token_usage.total_tokens
    );
    println!();

    let history = session.load_history()?;
    let screens = session.load_screens()?;

    if let Some(step_num) = step {
        // Show specific step
        if step_num >= history.len() {
            anyhow::bail!(
                "Step {} not found (only {} messages)",
                step_num,
                history.len()
            );
        }

        let message = &history[step_num];
        println!("=== Step {} ===", step_num);
        println!("Role: {:?}", message.role);
        println!("Time: {}", message.timestamp);
        println!();
        println!("{}", message.content);

        if show_screens && step_num < screens.len() {
            println!();
            ui::display_step_progress(step_num, &screens[step_num]);
        }
    } else {
        // Show all history
        println!("=== History ({} messages) ===", history.len());
        println!();

        for (i, message) in history.iter().enumerate() {
            println!("[{}] {:?} at {}", i, message.role, message.timestamp);
            println!("{}", message.content);
            println!();

            if show_screens && i < screens.len() {
                ui::display_step_progress(i, &screens[i]);
                println!();
            }
        }
    }

    Ok(())
}

/// Handle the resume command - resume a paused session
async fn handle_resume(project_dir: &Path, session_id: uuid::Uuid) -> Result<()> {
    let session_id = SessionId::from(session_id);
    let session = Session::load(project_dir, session_id)?;

    if session.status != SessionStatus::Paused && session.status != SessionStatus::Active {
        anyhow::bail!(
            "Cannot resume session with status {:?}. Only Paused or Active sessions can be resumed.",
            session.status
        );
    }

    println!("Resuming session: {}", session.id);
    println!("Task: {}", session.task);
    println!("Current cost: ${:.6}", session.total_cost);
    println!();

    run_agent(project_dir, session).await
}

/// Handle starting a new task
async fn handle_new_task(project_dir: &Path, task: &str) -> Result<()> {
    println!("Starting new task: {}", task);
    println!();

    let session = Session::create(project_dir.to_path_buf(), task.to_string())?;

    println!("Created session: {}", session.id);
    println!();

    run_agent(project_dir, session).await
}

/// Run the agent with the given session
async fn run_agent(project_dir: &Path, session: Session) -> Result<()> {
    // Change to project directory to load config from the right place
    std::env::set_current_dir(project_dir).context("Failed to change to project directory")?;

    // Load configuration
    let config = ConfigLoader::load()?;

    // Validate LLM configuration and create client
    let validated_config = config.llm.validate()?;
    let llm_client = OpenAiCompatibleClient::new(validated_config)?;

    // Create container manager and spawn sandbox
    let container_manager = ContainerManager::new()?;

    println!("Spawning sandbox...");
    let container_handle = container_manager.spawn_container(project_dir, &config.sandbox)?;
    println!("✓ Sandbox spawned");
    println!();

    // Create agent and run
    let mut agent = Agent::new(session, config, container_handle, llm_client)?;

    match agent.run().await {
        Ok(()) => {
            ui::display_cost_summary(agent.session());
            Ok(())
        }
        Err(e) => {
            // Save session state on error
            if let Err(save_err) = agent.session().save_metadata() {
                eprintln!("Warning: Failed to save session on error: {}", save_err);
            }
            Err(e)
        }
    }
}
