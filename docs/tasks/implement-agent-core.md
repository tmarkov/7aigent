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

- [x] Set up Rust project structure
  - [x] Verify agent is in flake.nix outputs
  - [x] Create `agent/` directory with Cargo.toml
  - [x] Add dependencies: tokio, serde, serde_json, thiserror, toml, uuid, chrono, rust_decimal
  - [x] Configure for async runtime (tokio)
  - [x] `git add agent/Cargo.toml agent/src/main.rs`
  - [x] Verify `nix build .#agent` succeeds with stub

- [x] Implement core types (`agent/src/types.rs`)
  - [x] Create file with all type definitions
  - [x] `Session` struct (id, project_dir, created_at, status, total_cost)
  - [x] `SessionStatus` enum (Active, Paused, Completed, Failed)
  - [x] `Message` struct (role, content, timestamp)
  - [x] `MessageRole` enum (System, User, Assistant)
  - [x] `ScreenState` struct (step, timestamp, sections)
  - [x] `TokenUsage` struct (prompt_tokens, completion_tokens, total_tokens)
  - [x] Property-based tests for serialization/deserialization
  - [x] `git add agent/src/types.rs agent/src/lib.rs`
  - [x] Verify `nix build .#agent` succeeds and tests pass

- [x] Implement configuration system (`agent/src/config.rs`)
  - [x] `Config` struct matching schema in design doc
  - [x] `LlmConfig`, `SandboxConfig`, `BudgetConfig` structs
  - [x] `ConfigLoader::load()` - load global and project configs
  - [x] `ConfigLoader::merge()` - merge with precedence
  - [x] `Config::validate()` - ensure endpoint is set, budget values are sane
  - [x] Tests for config loading and merging
  - [x] `git add agent/src/config.rs agent/src/lib.rs`
  - [x] Verify `nix build .#agent` succeeds and tests pass

- [x] Implement session manager (`agent/src/session.rs`)
  - [x] `Session::create()` - create new session in `.7aigent/sessions/<uuid>/`
  - [x] `Session::load()` - load existing session by ID
  - [x] `Session::save()` - persist metadata, history, screens, cost
  - [x] `Session::list()` - list all sessions in project
  - [x] File format: metadata.json, history.jsonl, screens.jsonl, cost.json
  - [x] Tests for session persistence
  - [x] `git add agent/src/session.rs agent/src/lib.rs`
  - [x] Verify `nix build .#agent` succeeds and tests pass

### Phase 2: LLM Client

- [x] Implement LLM client abstraction (`agent/src/llm/mod.rs`)
  - [x] `LlmClient` trait (complete, estimate_cost, count_tokens)
  - [x] `CompletionResponse` struct (content, usage, cost, finish_reason)
  - [x] `LlmError` enum with thiserror (RateLimit, Timeout, Auth, etc.)

- [x] Implement OpenAI-compatible client (`agent/src/llm/openai.rs`)
  - [x] `OpenAiCompatibleClient` struct
  - [x] HTTP client setup with reqwest
  - [x] `complete()` - POST to /chat/completions endpoint
  - [x] Parse response (content, usage, finish_reason)
  - [x] Calculate actual cost from usage

- [x] Implement retry logic (`agent/src/llm/retry.rs`)
  - [x] Exponential backoff for rate limits
  - [x] Retry on timeout (max 3 retries)
  - [x] Don't retry on auth errors
  - [x] Tests with mock HTTP client

- [x] Implement cost estimation (`agent/src/llm/cost.rs`)
  - [x] Token counting (char-based estimate)
  - [x] `TokenPricing` struct (input_cost_per_1k, output_cost_per_1k)
  - [x] Default pricing for common models (GPT-4, GPT-3.5, Claude)
  - [x] `estimate_cost()` - count tokens, multiply by pricing, add heuristic for completion
  - [x] Tests for cost calculation

### Phase 3: Container Manager (Basic)

- [x] Implement container manager (`agent/src/container.rs`)
  - [x] `ContainerManager` struct
  - [x] `spawn_container()` - run podman with orchestrator
  - [x] Use `--network=none`, `--rm`, `-i` flags
  - [x] Mount project directory to `/workspace`
  - [x] Set `PROJECT_DIR=/workspace` env var
  - [x] Capture stdin/stdout pipes

- [x] Implement orchestrator communication (`agent/src/container.rs`)
  - [x] `ContainerHandle` struct (child process, stdin writer, stdout reader)
  - [x] `send_command()` - write NDJSON message to stdin
  - [x] `receive_response()` - read NDJSON message from stdout
  - [x] Parse response type (response vs error)
  - [x] Extract command output and screen state
  - [x] Tests for screen parsing

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
