//! Main entry point for the 7aigent CLI.

use agent::{
    cli::{Cli, Commands},
    config::ConfigLoader,
    container::ContainerManager,
    format::{
        format_event_with_context, format_llm_call_list, format_session_summary, DisplayMode,
    },
    llm::openai::OpenAiCompatibleClient,
    llm::retry::RetryClient,
    types::{Event, SessionId, SessionManager, SessionMetadata, SessionStatus},
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
            call,
            raw,
            list_calls,
            context,
        }) => {
            handle_inspect(&project_dir, session_id, call, raw, list_calls, context)?;
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
    let session_manager = SessionManager::new(project_dir.to_path_buf());
    let sessions = session_manager.list_sessions()?;

    if sessions.is_empty() {
        println!("No sessions found.");
        return Ok(());
    }

    // Parse status filter if provided
    let filter_status = status_filter
        .as_ref()
        .and_then(|s| match s.to_lowercase().as_str() {
            "active" => Some(SessionStatus::Active),
            "paused" => Some(SessionStatus::Paused),
            "completed" => Some(SessionStatus::Completed),
            "failed" => Some(SessionStatus::Failed),
            _ => None,
        });

    // Filter sessions
    let filtered: Vec<_> = sessions
        .iter()
        .filter(|s| filter_status.is_none() || Some(s.status) == filter_status)
        .collect();

    if filtered.is_empty() {
        println!("No sessions found with status: {:?}", filter_status);
        return Ok(());
    }

    println!("Found {} session(s):\n", filtered.len());

    for session in filtered {
        if verbose {
            print!("{}", format_session_summary(session));
            println!("---");
        } else {
            println!(
                "[{}] {:?} - {} (${:.4}, {} LLM calls)",
                session.id,
                session.status,
                session.task,
                session.total_cost,
                session.llm_call_count
            );
        }
    }

    Ok(())
}

/// Handle the inspect command - show session details
fn handle_inspect(
    project_dir: &Path,
    session_id: u64,
    call: Option<usize>,
    raw: bool,
    list_calls: bool,
    context: bool,
) -> Result<()> {
    let session_id = SessionId::from_u64(session_id);
    let session = SessionMetadata::load(project_dir, session_id)?;
    let events = session.load_events()?;

    if list_calls {
        // List all LLM calls
        println!("{}", format_session_summary(&session));
        println!("\n=== LLM Calls ===\n");
        print!("{}", format_llm_call_list(&events));
    } else if let Some(call_id) = call {
        // Show specific LLM call
        let llm_call = events
            .iter()
            .find(|e| matches!(e, Event::LlmCall { call_id: id, .. } if *id == call_id));

        if let Some(event) = llm_call {
            let mode = if raw {
                DisplayMode::Raw
            } else {
                DisplayMode::Inspect
            };
            print!("{}", format_event_with_context(event, mode, context));
        } else {
            anyhow::bail!("LLM call {} not found", call_id);
        }
    } else {
        // Default: show full conversation
        println!("{}", format_session_summary(&session));
        println!("\n=== Conversation ===\n");

        for event in &events {
            print!(
                "{}",
                format_event_with_context(event, DisplayMode::Inspect, context)
            );
        }
    }

    Ok(())
}

/// Handle the resume command - resume a paused session
async fn handle_resume(project_dir: &Path, session_id: u64) -> Result<()> {
    let session_id = SessionId::from_u64(session_id);
    let mut session = SessionMetadata::load(project_dir, session_id)?;

    if session.status == SessionStatus::Completed {
        anyhow::bail!("Session {} is already completed", session.id);
    }

    if session.status == SessionStatus::Failed {
        anyhow::bail!("Session {} has failed and cannot be resumed", session.id);
    }

    // Update status to active
    session.status = SessionStatus::Active;
    session.save()?;

    println!("Resuming session {}", session.id);
    println!("Task: {}", session.task);
    println!();

    // Load config
    let config = ConfigLoader::load()?;

    // Create LLM client
    let llm_config = config.llm.validate()?;
    let base_client = OpenAiCompatibleClient::new(llm_config)?;
    let llm_client = RetryClient::new(base_client);

    // Start container
    let container_manager = ContainerManager::new()?;
    let container = container_manager
        .spawn_container(project_dir, &config.sandbox)
        .context("Failed to start container")?;

    // Create agent and run
    let mut agent = Agent::new(session, config, container, llm_client)?;
    agent.run().await?;

    Ok(())
}

/// Handle a new task - create a new session and run agent
async fn handle_new_task(project_dir: &Path, task: &str) -> Result<()> {
    // Load config
    let config = ConfigLoader::load()?;

    // Create session
    let session_manager = SessionManager::new(project_dir.to_path_buf());
    let session = session_manager.create_session(task.to_string())?;

    println!("Created session {}", session.id);
    println!();

    // Create LLM client
    let llm_config = config.llm.validate()?;
    let base_client = OpenAiCompatibleClient::new(llm_config)?;
    let llm_client = RetryClient::new(base_client);

    // Start container
    let container_manager = ContainerManager::new()?;
    let container = container_manager
        .spawn_container(project_dir, &config.sandbox)
        .context("Failed to start container")?;

    // Create agent and run
    let mut agent = Agent::new(session, config, container, llm_client)?;
    agent.run().await?;

    Ok(())
}
