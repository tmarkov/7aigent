# Task: End-to-End Testing and Validation

## Description

Implement comprehensive end-to-end testing of the complete 7aigent system with real LLM integration, validate against design scenarios, and document performance characteristics.

## Context

- **Component**: Integration tests for full system
- **Design**: Validate scenarios from `docs/tasks/design-agent.md`
- **Requirements**: Test with real LLM, measure costs, verify all major workflows

## Plan

### Phase 1: Test Infrastructure

- [ ] Create test project structures
  - [ ] Simple project (README, src/ with a few files)
  - [ ] Multi-language project (Rust backend, Python scripts)
  - [ ] Content project (markdown chapters, no code)
  - [ ] Data analysis project (CSV files, notebooks)

- [ ] Implement test harness (`tests/e2e/harness.rs`)
  - [ ] `TestSession` struct - wrapper around agent session
  - [ ] `run_task()` - run agent with task, capture output
  - [ ] `verify_completion()` - check session status is Completed
  - [ ] `verify_files_created()` - check expected files exist
  - [ ] `verify_cost_under()` - check total cost is below threshold
  - [ ] `get_history()` - access session history for inspection

- [ ] Setup test configuration
  - [ ] `.7aigent-test.toml` - test-specific config
  - [ ] Lower budget limits for tests
  - [ ] Use cheaper model for basic tests (GPT-3.5-turbo)
  - [ ] Environment variable for API key
  - [ ] Skip tests if API key not set

### Phase 2: Core Functionality Tests

- [ ] Test simple bash task
  - [ ] Task: "List all Python files and count total lines"
  - [ ] Verify: Correct output, bash commands used
  - [ ] Verify: Session completes successfully
  - [ ] Measure: Cost, time, LLM calls

- [ ] Test python task
  - [ ] Task: "Load data.csv and calculate mean of 'value' column"
  - [ ] Create test data.csv with known mean
  - [ ] Verify: Correct result computed
  - [ ] Verify: Python environment used
  - [ ] Check screen shows variables (df, mean)

- [ ] Test editor task
  - [ ] Task: "Find the main() function and add a comment"
  - [ ] Verify: File modified correctly
  - [ ] Verify: Editor views used
  - [ ] Verify: Comment added at right location

- [ ] Test multi-environment task
  - [ ] Task: "Create Python script, run it, show output"
  - [ ] Verify: File created with editor
  - [ ] Verify: Script executed with bash
  - [ ] Verify: Multiple environments coordinated

### Phase 3: Session Management Tests

- [ ] Test session creation
  - [ ] Create new session
  - [ ] Verify session directory created (`.7aigent/sessions/<uuid>/`)
  - [ ] Verify metadata.json has correct structure
  - [ ] Verify history.jsonl exists and is valid NDJSON

- [ ] Test session pause and resume
  - [ ] Start task, run 3 steps, pause (Ctrl+C)
  - [ ] Verify session saved with status=Paused
  - [ ] Resume session
  - [ ] Verify history loaded correctly
  - [ ] Verify task continues from where it left off
  - [ ] Note: Container state not preserved (expected)

- [ ] Test session listing
  - [ ] Create 3 sessions with different tasks
  - [ ] Run `7aigent --list`
  - [ ] Verify all sessions shown
  - [ ] Verify metadata (task, status, cost) displayed

- [ ] Test session inspection
  - [ ] Run task with 5+ steps
  - [ ] Inspect at step 3: `7aigent --inspect <id> --step 3`
  - [ ] Verify screen state from step 3 shown
  - [ ] Verify full context option shows messages

### Phase 4: Cost Management Tests

- [ ] Test cost estimation
  - [ ] Run task with cost logging
  - [ ] Verify estimated vs actual cost within 30%
  - [ ] Check cost displayed after each step

- [ ] Test budget warning
  - [ ] Set `max_cost_per_session = 0.50`
  - [ ] Run task that approaches limit
  - [ ] Verify warning at 80% threshold ($0.40)
  - [ ] Verify informative message

- [ ] Test budget enforcement
  - [ ] Set `max_cost_per_session = 0.20`
  - [ ] Run task that would exceed limit
  - [ ] Verify user prompted for confirmation
  - [ ] Test both confirming and aborting

- [ ] Test per-call limit
  - [ ] Set `max_cost_per_call = 0.10`
  - [ ] Trigger large context (estimate >$0.10)
  - [ ] Verify warning and confirmation prompt

### Phase 5: Configuration Tests

- [ ] Test config loading
  - [ ] Create global config with defaults
  - [ ] Create project config with overrides
  - [ ] Verify project config takes precedence
  - [ ] Verify merged config is correct

- [ ] Test file access advisory
  - [ ] Set `sandbox.files.read_only = ["tests/**"]`
  - [ ] Run task, check system prompt includes restriction
  - [ ] Verify LLM doesn't modify tests/ (usually)
  - [ ] Note: Advisory only, not enforced

- [ ] Test resource limits
  - [ ] Set `sandbox.resources.max_memory = "512M"`
  - [ ] Verify podman spawned with --memory flag
  - [ ] Verify container respects limit (try to allocate 1G, should fail)

- [ ] Test custom system prompt
  - [ ] Set `system_prompt_suffix = "Explain every step."`
  - [ ] Run task
  - [ ] Verify LLM responses are verbose

### Phase 6: Error Handling Tests

- [ ] Test LLM API failure
  - [ ] Mock API to return 503 error
  - [ ] Verify retry logic activates (3 attempts)
  - [ ] Verify exponential backoff
  - [ ] Verify session saved on failure

- [ ] Test orchestrator error
  - [ ] Send invalid command to orchestrator
  - [ ] Verify error message returned
  - [ ] Verify agent handles gracefully
  - [ ] Verify session can continue

- [ ] Test malformed LLM response
  - [ ] Mock LLM to return invalid code blocks
  - [ ] Verify parser handles gracefully
  - [ ] Verify error message to user

- [ ] Test container crash
  - [ ] Kill container process mid-task
  - [ ] Verify agent detects crash
  - [ ] Verify error message to user
  - [ ] Verify session saved

### Phase 7: Scenario Validation

Test representative scenarios from the design (scenarios that don't need network):

- [ ] Scenario 1: Out-of-box app creation
  - [ ] Fresh project directory, no .7aigent.toml
  - [ ] Task: "Create a simple TODO app in Python"
  - [ ] Verify: App files created, minimal setup needed

- [ ] Scenario 3: Constrained feature addition
  - [ ] Config: `read_only = ["tests/**"]`
  - [ ] Task: "Add new feature to src/app.py"
  - [ ] Verify: src/ modified, tests/ not touched

- [ ] Scenario 6: Data science iteration
  - [ ] Task: "Load sales.csv, create histogram, save as plot.png"
  - [ ] Verify: Matplotlib plot created
  - [ ] Verify: Python variables preserved across steps

- [ ] Scenario 10: LLM API failure recovery
  - [ ] Inject API failure after 2 steps
  - [ ] Resume after "API restored"
  - [ ] Verify: Task continues without redoing work

- [ ] Scenario 14: Multi-session project
  - [ ] Day 1: Start task, pause after 5 steps
  - [ ] Day 2: Resume, continue for 5 more steps
  - [ ] Verify: Context preserved, task completes

- [ ] Scenario 29: Book editing
  - [ ] Project: 5 markdown chapter files
  - [ ] Task: "Edit chapter 3 to reference events from chapter 1"
  - [ ] Verify: Editor views used for both chapters
  - [ ] Verify: Chapter 3 modified appropriately

### Phase 8: Performance and Stress Testing

- [ ] Measure baseline performance
  - [ ] Container startup time (cold and warm)
  - [ ] Time per LLM call (network latency)
  - [ ] Screen update time
  - [ ] Session save time

- [ ] Test long sessions
  - [ ] Run task with 20+ steps
  - [ ] Verify context truncation works
  - [ ] Verify session files don't grow unbounded
  - [ ] Check memory usage stays reasonable

- [ ] Test large outputs
  - [ ] Generate large bash output (10MB log file)
  - [ ] Verify truncation works
  - [ ] Verify system doesn't crash

- [ ] Test many files
  - [ ] Project with 1000+ files
  - [ ] Task: "Find all TODOs in Python files"
  - [ ] Verify performance acceptable (<30s)

### Phase 9: Documentation and Examples

- [ ] Document test findings
  - [ ] Successful workflows (what works well)
  - [ ] Common failure modes (what goes wrong)
  - [ ] Performance characteristics (timing, costs)
  - [ ] Known limitations (confirm design limitations)

- [ ] Create example sessions
  - [ ] Simple bash automation
  - [ ] Python data analysis
  - [ ] Multi-file code refactoring
  - [ ] Content creation (blog post)
  - [ ] Export session history as examples

- [ ] Write user guide
  - [ ] Getting started tutorial
  - [ ] Configuration guide
  - [ ] Common patterns
  - [ ] Troubleshooting guide

- [ ] Update README
  - [ ] Installation instructions
  - [ ] Quick start example
  - [ ] Link to docs
  - [ ] Link to example sessions

## Dependencies

- Complete agent implementation (core + container)
- Working orchestrator in container
- LLM API access (API key configured)
- Test project structures

## Outcome

A thoroughly tested system with:
- Comprehensive test suite covering all major features
- Validation against 20+ design scenarios
- Performance benchmarks and cost estimates
- Documented failure modes and limitations
- Example sessions for users
- User guide and troubleshooting documentation
- Confidence that the system works as designed
