# Task: Implement Agent Core

## Description

Implement the core Rust agent that manages LLM interaction, session persistence, and communication with the containerized orchestrator. This is the main binary that users run.

## Context

- **Component**: `agent/` (Rust crate)
- **Design**: See `docs/agent-design.md` for complete specifications
- **Dependencies**: Orchestrator is implemented and tested

## Plan

### Phase 1: Core Types and Configuration

**IMPORTANT: Use `nix build .#agent` for ALL verification, not `cargo check/test`**

- [ ] Set up Rust project structure
  - [ ] Verify agent is in flake.nix outputs
  - [ ] Create `agent/` directory with Cargo.toml
  - [ ] Add dependencies: tokio, serde, serde_json, thiserror, toml, uuid, chrono, rust_decimal
  - [ ] Configure for async runtime (tokio)
  - [ ] `git add agent/Cargo.toml agent/src/main.rs`
  - [ ] Verify `nix build .#agent` succeeds with stub

- [ ] Implement core types (`agent/src/types.rs`)
  - [ ] Create file with all type definitions
  - [ ] `Session` struct (id, project_dir, created_at, status, total_cost)
  - [ ] `SessionStatus` enum (Active, Paused, Completed, Failed)
  - [ ] `Message` struct (role, content, timestamp)
  - [ ] `MessageRole` enum (System, User, Assistant)
  - [ ] `ScreenState` struct (step, timestamp, sections)
  - [ ] `TokenUsage` struct (prompt_tokens, completion_tokens, total_tokens)
  - [ ] Property-based tests for serialization/deserialization
  - [ ] `git add agent/src/types.rs agent/src/lib.rs`
  - [ ] Verify `nix build .#agent` succeeds and tests pass

- [ ] Implement configuration system (`agent/src/config.rs`)
  - [ ] `Config` struct matching schema in design doc
  - [ ] `LlmConfig`, `SandboxConfig`, `BudgetConfig` structs
  - [ ] `ConfigLoader::load()` - load global and project configs
  - [ ] `ConfigLoader::merge()` - merge with precedence
  - [ ] `Config::validate()` - ensure endpoint is set, budget values are sane
  - [ ] Tests for config loading and merging

- [ ] Implement session manager (`agent/src/session.rs`)
  - [ ] `Session::create()` - create new session in `.7aigent/sessions/<uuid>/`
  - [ ] `Session::load()` - load existing session by ID
  - [ ] `Session::save()` - persist metadata, history, screens, cost
  - [ ] `Session::list()` - list all sessions in project
  - [ ] File format: metadata.json, history.jsonl, screens.jsonl, cost.json
  - [ ] Tests for session persistence

### Phase 2: LLM Client

- [ ] Implement LLM client abstraction (`agent/src/llm/mod.rs`)
  - [ ] `LlmClient` trait (complete, estimate_cost, count_tokens)
  - [ ] `CompletionResponse` struct (content, usage, cost, finish_reason)
  - [ ] `LlmError` enum with thiserror (RateLimit, Timeout, Auth, etc.)

- [ ] Implement OpenAI-compatible client (`agent/src/llm/openai.rs`)
  - [ ] `OpenAiCompatibleClient` struct
  - [ ] HTTP client setup with reqwest
  - [ ] `complete()` - POST to /chat/completions endpoint
  - [ ] Parse response (content, usage, finish_reason)
  - [ ] Calculate actual cost from usage

- [ ] Implement retry logic (`agent/src/llm/retry.rs`)
  - [ ] Exponential backoff for rate limits
  - [ ] Retry on timeout (max 3 retries)
  - [ ] Don't retry on auth errors
  - [ ] Tests with mock HTTP client

- [ ] Implement cost estimation (`agent/src/llm/cost.rs`)
  - [ ] Token counting (use tiktoken or char-based estimate)
  - [ ] `TokenPricing` struct (input_cost_per_1k, output_cost_per_1k)
  - [ ] Default pricing for common models (GPT-4, GPT-3.5, Claude)
  - [ ] `estimate_cost()` - count tokens, multiply by pricing, add heuristic for completion
  - [ ] Tests for cost calculation

### Phase 3: Container Manager (Basic)

- [ ] Implement container manager (`agent/src/container.rs`)
  - [ ] `ContainerManager` struct
  - [ ] `spawn_container()` - run podman with orchestrator
  - [ ] Use `--network=none`, `--rm`, `-i` flags
  - [ ] Mount project directory to `/workspace`
  - [ ] Set `PROJECT_DIR=/workspace` env var
  - [ ] Capture stdin/stdout pipes

- [ ] Implement orchestrator communication (`agent/src/container.rs`)
  - [ ] `ContainerHandle` struct (child process, stdin writer, stdout reader)
  - [ ] `send_command()` - write NDJSON message to stdin
  - [ ] `receive_response()` - read NDJSON message from stdout
  - [ ] Parse response type (response vs error)
  - [ ] Extract command output and screen state
  - [ ] Tests with mock orchestrator (stdin/stdout simulation)

### Phase 4: Agent Core Loop

- [ ] Implement context building (`agent/src/context.rs`)
  - [ ] `build_system_prompt()` - construct from config + sandbox rules
  - [ ] `build_llm_messages()` - system + task + history + screen
  - [ ] `truncate_history()` - keep recent messages within token limit
  - [ ] `format_screen()` - convert screen state to user message
  - [ ] Tests for message construction

- [ ] Implement command parsing (`agent/src/parser.rs`)
  - [ ] `parse_commands()` - extract fenced code blocks from LLM response
  - [ ] Regex for ```env\ncommand``` pattern
  - [ ] `Command` struct (env, command)
  - [ ] Tests with example LLM responses

- [ ] Implement budget checking (`agent/src/budget.rs`)
  - [ ] `BudgetCheckResult` enum (Ok, WarningThreshold, ExceedsPerCall, ExceedsSession)
  - [ ] `check_budget()` - verify estimated cost against limits
  - [ ] Return appropriate result for prompting user
  - [ ] Tests for budget logic

- [ ] Implement main loop (`agent/src/agent.rs`)
  - [ ] `Agent` struct (session, config, container, llm_client)
  - [ ] `run()` - main interaction loop
  - [ ] Build LLM context → check budget → call LLM → parse commands
  - [ ] For each command: send to orchestrator, receive response
  - [ ] Update session history and screen states
  - [ ] Save session after each step
  - [ ] Loop until no commands returned (task complete)
  - [ ] Handle errors (LLM, orchestrator, budget)

### Phase 5: CLI Interface

- [ ] Implement CLI (`agent/src/cli.rs`)
  - [ ] Use clap for argument parsing
  - [ ] Command: `7aigent <task>` - start new session
  - [ ] Command: `7aigent --resume <id>` - resume session
  - [ ] Command: `7aigent --list` - list sessions
  - [ ] Command: `7aigent --inspect <id> [--step N]` - inspect session
  - [ ] Command: `7aigent --init` - create .7aigent.toml template

- [ ] Implement user prompts (`agent/src/ui.rs`)
  - [ ] Cost confirmation prompt (when exceeding budget)
  - [ ] Display progress after each step
  - [ ] Display cost summary at end
  - [ ] Handle Ctrl+C gracefully (save session, mark as paused)

- [ ] Implement main entry point (`agent/src/main.rs`)
  - [ ] Parse CLI args
  - [ ] Load config
  - [ ] Create or load session
  - [ ] Initialize container and LLM client
  - [ ] Run agent loop
  - [ ] Cleanup (shutdown container)
  - [ ] Error handling and user-friendly error messages

### Phase 6: Testing and Polish

- [ ] Write unit tests
  - [ ] Test all core types (serialization, validation)
  - [ ] Test config loading and merging
  - [ ] Test session persistence
  - [ ] Test LLM client (with mock HTTP)
  - [ ] Test command parsing
  - [ ] Test budget checking
  - [ ] Test context truncation

- [ ] Write integration tests
  - [ ] Test agent with mock orchestrator
  - [ ] Test session save/load/resume
  - [ ] Test cost tracking across multiple steps
  - [ ] Test error recovery

- [ ] Add to Nix build
  - [ ] Create agent Nix derivation
  - [ ] Add to flake.nix outputs
  - [ ] Ensure `nix build .#agent` runs all checks
  - [ ] rustfmt check
  - [ ] clippy with strict settings
  - [ ] cargo test

## Dependencies

- Orchestrator implemented and tested
- Agent design completed (`docs/agent-design.md`)

## Outcome

A working Rust agent binary that:
- Loads configuration from TOML files
- Creates and manages sessions with persistence
- Calls OpenAI-compatible LLM APIs with cost tracking
- Communicates with containerized orchestrator
- Implements main interaction loop
- Provides CLI interface for users
- Handles errors gracefully
- Has comprehensive tests
- Builds successfully with `nix build .#agent`
