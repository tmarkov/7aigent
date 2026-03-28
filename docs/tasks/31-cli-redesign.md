# Task: CLI Redesign - Improve Output and Inspection Ergonomics

## Description

Redesign the 7aigent CLI to improve the user experience when running the agent and inspecting sessions. The current CLI has two main problems: (1) too much text is printed during execution, making it hard to parse and reason about, and (2) the inspection commands are not ergonomic, requiring explicit session IDs when users typically want to inspect the last session.

## Context

- **Component**: `agent/src/cli.rs` (argument parsing), `agent/src/main.rs` (command handlers), `agent/src/format.rs` (output formatting), `agent/src/ui.rs` (display functions)
- **Design**: See `docs/design/cli-redesign.md` for complete specification
- **Motivation**: Users are overwhelmed by verbose output during agent execution and frustrated by having to specify session IDs when they usually want the most recent one

## Scenarios

### Scenario 1: Running agent with task

**Situation**: User runs `7aigent "Add a README file to the project"`

**Current behavior**: Agent prints full orchestrator responses, making output verbose and hard to follow

**Desired behavior**:
- Agent prints LLM messages (without thoughts)
- Agent prints first 3 lines of each orchestrator response (enough to see errors, but not overwhelming)
- At end, prints summary with session ID

**Success criteria**: User can follow the agent's progress without being overwhelmed by output

### Scenario 2: Running agent in interactive mode

**Situation**: User runs `7aigent` to start interactive session

**Desired behavior**: Same as Scenario 1 - LLM messages + 3 lines of orchestrator response per turn

**Success criteria**: Interactive mode has same clean output as one-shot mode

### Scenario 3: Resume last session

**Situation**: User wants to resume their most recent session

**Current behavior**: Must run `7aigent resume <session_id>`, requiring user to look up the ID first

**Desired behavior**: 
- `7aigent resume` (no ID) resumes the last session
- `7aigent resume 42` resumes specific session 42

**Success criteria**: User can resume last session without looking up session ID

### Scenario 4: Inspect last session output

**Situation**: User wants to see what happened in their last session

**Current behavior**: Must run `7aigent inspect <session_id>` with explicit ID

**Desired behavior**:
- `7aigent inspect` (no ID) shows output from last session
- Output format: LLM messages + first 3 lines of orchestrator responses (same as runtime display)
- Session ID is printed at the end

**Success criteria**: User can inspect last session without looking up session ID

### Scenario 5: Inspect session calls

**Situation**: User wants to see the list of LLM calls from a session

**Current behavior**: `7aigent inspect <session_id>` shows the calls list (different from output display)

**Desired behavior**:
- `7aigent inspect --calls` shows calls from last session
- `7aigent inspect 42 --calls` shows calls from session 42

**Success criteria**: User can list calls without redundant session ID when inspecting last session

### Scenario 6: Inspect specific call context

**Situation**: User wants to see the full context (system message, task message, history, screen) for a specific LLM call

**Current behavior**: `7aigent inspect <session_id> --call N` shows context for call N

**Desired behavior**:
- `7aigent inspect --call 3` shows context for call 3 of last session
- `7aigent inspect 42 --call 3` shows context for call 3 of session 42
- Format: system message, task message, conversation history, screen, then LLM response

**Success criteria**: User can inspect call context with optional session ID

### Scenario 7: Inspect call response

**Situation**: User wants to see the LLM response and orchestrator output for a specific call

**Current behavior**: `7aigent inspect <session_id> --after N` shows the LLM reply + commands + screen after call N

**Desired behavior**:
- `7aigent inspect --call 3 --response` shows LLM message from call 3, then orchestrator response and screen
- Session ID optional (defaults to last)

**Success criteria**: User can see call response with cleaner syntax

### Scenario 8: Inspect specific screen

**Situation**: User wants to see just the screen state after a specific LLM message

**Current behavior**: No direct way to see just the screen

**Desired behavior**:
- `7aigent inspect --screen 3` shows screen after LLM message 3
- Session ID optional (defaults to last)

**Success criteria**: User can view specific screen state easily

## Plan

### Phase 1: Update CLI Argument Structure

- [ ] Modify `agent/src/cli.rs` to make session_id optional for `resume` and `inspect`
  - [ ] `Resume { session_id: Option<u64> }` instead of `Resume { session_id: u64 }`
  - [ ] `Inspect { session_id: Option<u64>, ... }` instead of required session_id
  - [ ] Add `--calls` flag to `inspect` (replaces current default behavior of listing calls)
  - [ ] Add `--screen N` option to `inspect` (new functionality)
  - [ ] Rename `--after N` to `--response` (when combined with `--call N`)
  
- [ ] Update CLI help text to reflect new behavior
  - [ ] Document that session_id defaults to last session
  - [ ] Document the `--calls`, `--screen`, and `--response` options

### Phase 2: Implement "Last Session" Resolution

- [ ] Add function to find last session in `agent/src/session.rs` or `agent/src/types.rs`
  - [ ] `fn find_last_session(project_dir: &Path) -> Result<Option<SessionMetadata>>`
  - [ ] Use filesystem to find most recently modified session directory
  - [ ] Consider both active and completed sessions
  
- [ ] Add helper to resolve session_id: Option<u64> to actual session
  - [ ] If Some(id), use that
  - [ ] If None, find last session
  - [ ] Return error if no sessions exist

- [ ] Update `handle_resume` in `agent/src/main.rs`
  - [ ] Resolve session_id using helper
  - [ ] Display clear error if no session found
  
- [ ] Update `handle_inspect` in `agent/src/main.rs`
  - [ ] Resolve session_id using helper
  - [ ] Display clear error if no session found

### Phase 3: Implement Output Truncation

- [ ] Add truncation logic in `agent/src/format.rs` or new module
  - [ ] `fn truncate_orchestrator_response(response: &str, lines: usize) -> String`
  - [ ] Keep first N lines (default 3)
  - [ ] Add "... (N more lines)" indicator if truncated
  - [ ] Preserve error messages (don't truncate errors)

- [ ] Update runtime display in `agent/src/agent.rs` or `agent/src/ui.rs`
  - [ ] Apply truncation to orchestrator responses during execution
  - [ ] Keep LLM messages full (no truncation)
  - [ ] Add session ID to final summary

- [ ] Update `format_llm_call_after` or create new format function
  - [ ] `format_inspect_output(session, session_id)` - for `inspect` without flags
  - [ ] Shows LLM messages + truncated orchestrator responses
  - [ ] Same format as runtime display

### Phase 4: Implement New Inspect Modes

- [ ] Add `format_llm_call_list` (already exists, verify it works with new CLI)
  - [ ] Used for `inspect --calls`
  
- [ ] Verify `format_llm_call_context` works correctly
  - [ ] Used for `inspect --call N`
  - [ ] Shows: system message, task message, conversation history, screen, LLM response

- [ ] Add or modify `format_llm_call_response`
  - [ ] Used for `inspect --call N --response`
  - [ ] Shows: LLM message from call N, orchestrator response, screen

- [ ] Add `format_screen_after_call`
  - [ ] Used for `inspect --screen N`
  - [ ] Shows just the screen state after LLM message N

### Phase 5: Update Main.rs Handlers

- [ ] Refactor `handle_inspect` to handle all modes
  - [ ] Mode 1: No flags → show truncated output (new behavior)
  - [ ] Mode 2: `--calls` → list calls (was default, now explicit)
  - [ ] Mode 3: `--call N` → show full context for call N
  - [ ] Mode 4: `--call N --response` → show LLM reply + orch response + screen
  - [ ] Mode 5: `--screen N` → show screen after LLM message N

- [ ] Update `handle_resume` for optional session_id
  - [ ] Resolve to last session if not provided
  - [ ] Display clear message about which session is being resumed

### Phase 6: Testing

- [ ] Add unit tests for session resolution
  - [ ] Test finding last session
  - [ ] Test session_id resolution (Some vs None)
  
- [ ] Add unit tests for output truncation
  - [ ] Test truncating to 3 lines
  - [ ] Test preserving short responses
  - [ ] Test truncation indicator
  
- [ ] Add integration tests for CLI commands
  - [ ] Test `resume` with and without session_id
  - [ ] Test `inspect` with all flag combinations
  - [ ] Test error cases (no sessions, invalid session_id)

- [ ] Manual testing
  - [ ] Run agent and verify output is clean
  - [ ] Resume last session without ID
  - [ ] Inspect last session without ID
  - [ ] Try all inspect flag combinations

### Phase 7: Documentation

- [ ] Update CLI help text
- [ ] Update any relevant documentation in `docs/`
- [ ] Add examples to task file or user guide

## Dependencies

- None - this is a self-contained CLI improvement task

## Outcome

A cleaner, more ergonomic CLI experience:
1. Running the agent shows concise output (LLM messages + 3 lines of orchestrator response)
2. `resume` and `inspect` default to last session, no need to look up IDs
3. `inspect` has clear modes: default (output), `--calls`, `--call N`, `--call N --response`, `--screen N`
4. Session ID is printed at the end of output for easy reference
5. All existing functionality preserved, just with better defaults and clearer syntax
