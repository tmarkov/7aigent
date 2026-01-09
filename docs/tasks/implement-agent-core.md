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

- [x] Implement context building (`agent/src/context.rs`)
  - [x] `build_system_prompt()` - construct from config + sandbox rules
  - [x] `build_llm_messages()` - system + task + history + screen
  - [x] `truncate_history()` - keep recent messages within token limit
  - [x] `format_screen()` - convert screen state to user message
  - [x] Tests for message construction

- [x] Implement command parsing (`agent/src/parser.rs`)
  - [x] `parse_commands()` - extract fenced code blocks from LLM response
  - [x] Regex for ```env\ncommand``` pattern
  - [x] `Command` struct (env, command)
  - [x] Tests with example LLM responses

- [x] Implement budget checking (`agent/src/budget.rs`)
  - [x] `BudgetCheckResult` enum (Ok, WarningThreshold, ExceedsPerCall, ExceedsSession)
  - [x] `check_budget()` - verify estimated cost against limits
  - [x] Return appropriate result for prompting user
  - [x] Tests for budget logic

- [x] Implement main loop (`agent/src/agent.rs`)
  - [x] `Agent` struct (session, config, container, llm_client)
  - [x] `run()` - main interaction loop
  - [x] Build LLM context → check budget → call LLM → parse commands
  - [x] For each command: send to orchestrator, receive response
  - [x] Update session history and screen states
  - [x] Save session after each step
  - [x] Loop until no commands returned (task complete)
  - [x] Handle errors (LLM, orchestrator, budget)

### Phase 4.5: Update Design Document ✅ COMPLETE

**Context**: Implementation (Phases 1-4) diverged from design. Need to sync design and implementation.
See: `docs/tasks/agent-refactor-plan.md` for full plan and `docs/agent-complexity-addendum.md` for analysis.

- [x] Add type system section to agent-design.md
  - [x] Document semantic types (LlmConfigSnapshot, TokenUsage, etc.)
  - [x] Explain "avoid primitive obsession" principle
  - [x] Show SessionId as proper newtype
  - [x] Document ValidatedLlmConfig pattern

- [x] Update config structure in design
  - [x] Document specialized config structs (LlmConfig, BudgetConfig, etc.)
  - [x] Show namespacing benefits

- [x] Simplify session persistence in design
  - [x] Remove SessionManager as separate component
  - [x] Show Session owns its persistence: `session.save_step()`
  - [x] Document single atomic save operation
  - [x] Make LlmConfigSnapshot optional in Session

- [x] Update Agent API in design
  - [x] Simple constructor (no SessionManager)
  - [x] Document generic LlmClient trait
  - [x] Show simplified initialization flow

- [x] Review consistency
  - [x] All code examples match new API
  - [x] Types align throughout document
  - [x] Main loop example is correct

### Phase 4.75: Refactor Implementation

**Context**: Simplify implementation to match updated design from Phase 4.5.
See: `docs/tasks/agent-refactor-plan.md` for detailed steps.

- [x] **Step 1: Strengthen type safety**
  - [x] Convert SessionId to proper newtype (not type alias)
  - [x] Rename OpenAiConfig → ValidatedLlmConfig
  - [x] Add LlmConfig::validate() method

- [x] **Step 2: Move persistence into Session**
  - [x] Add save methods to Session (save_metadata, save_step, save_cost)
  - [x] Add load methods to Session (load, load_history, load_screens)
  - [x] Add Session::create() (no SessionManager)
  - [x] Make llm_config: Option<LlmConfigSnapshot>

- [x] **Step 3: Remove SessionManager**
  - [x] Update Agent to not use SessionManager
  - [x] Remove session_manager field from Agent
  - [x] Delete SessionManager type entirely

- [x] **Step 4: Simplify save operations**
  - [x] Replace 3-4 save calls with single save_step()
  - [x] Ensure atomic operation
  - [x] Remove redundant update_cost()

- [x] **Step 5: Update tests**
  - [x] Fix unit tests for new API
  - [x] Fix integration tests
  - [x] Verify all tests pass (67 tests passing)

- [x] **Step 6: Update documentation**
  - [x] Fix inline doc comments
  - [x] Update module documentation

- [x] **Step 7: Verify build**
  - [x] `nix build .#agent` passes all checks

### Phase 5: CLI Interface

- [x] Implement CLI (`agent/src/cli.rs`)
  - [x] Use clap for argument parsing
  - [x] Command: `7aigent <task>` - start new session
  - [x] Command: `7aigent --resume <id>` - resume session
  - [x] Command: `7aigent --list` - list sessions
  - [x] Command: `7aigent --inspect <id> [--step N]` - inspect session
  - [x] Command: `7aigent --init` - create .7aigent.toml template

- [x] Implement user prompts (`agent/src/ui.rs`)
  - [x] Cost confirmation prompt (when exceeding budget)
  - [x] Display progress after each step
  - [x] Display cost summary at end
  - [ ] Handle Ctrl+C gracefully (save session, mark as paused) - deferred to Phase 6

- [x] Implement main entry point (`agent/src/main.rs`)
  - [x] Parse CLI args
  - [x] Load config
  - [x] Create or load session
  - [x] Initialize container and LLM client
  - [x] Run agent loop
  - [x] Cleanup (shutdown container handled by ContainerHandle drop)
  - [x] Error handling and user-friendly error messages
  - [x] Implement all CLI commands (init, list, inspect, resume, new task)
  - [x] Create config template (agent/templates/config.toml)

**Note**: Phase 5 is now complete! The main entry point has been fully implemented and successfully builds with `nix build .#agent`.

### Phase 6: Testing and Polish

- [x] Write unit tests
  - [x] Test all core types (serialization, validation)
  - [x] Test config loading and merging
  - [x] Test session persistence
  - [x] Test LLM client (with mock HTTP)
  - [x] Test command parsing
  - [x] Test budget checking
  - [x] Test context truncation

- [x] Write integration tests
  - [x] Test agent with mock orchestrator (basic tests in agent.rs)
  - [x] Test session save/load/resume (covered by session tests)
  - [x] Test cost tracking across multiple steps (covered by agent tests)
  - [ ] Test error recovery (deferred - basic coverage exists)

- [x] Add to Nix build
  - [x] Create agent Nix derivation
  - [x] Add to flake.nix outputs
  - [x] Ensure `nix build .#agent` runs all checks
  - [x] rustfmt check
  - [x] clippy with strict settings
  - [x] cargo test

**Note**: Phase 6 is substantially complete. The agent has 67 passing tests and successfully builds with all formatters, linters, and tests passing via `nix build .#agent`. Additional integration tests for complex error scenarios can be added in future iterations.

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
