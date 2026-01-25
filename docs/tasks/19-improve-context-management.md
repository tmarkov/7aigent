# Task: Improve Context Management - System Message and Initial Screen

## Description

Enhance the agent's LLM context management by improving the system message to include project awareness, implementing a system environment in the orchestrator to display project context, and generating an intelligent initial demonstration message that triggers the first screen update with relevant project information.

## Context

- **Components**:
  - `agent/src/context.rs` (system message generation)
  - `agent/src/agent.rs` (initial conversation flow)
  - `orchestrator/orchestrator/environments/system.py` (new)
  - `orchestrator/orchestrator/loader.py` (load system environment)
- **Motivation**: Currently, when starting in a project directory (e.g., "Tell me about iptsd" in an iptsd project), the LLM lacks project context and may refer to general knowledge instead of examining the local codebase. The system message doesn't mention the working directory, there's no initial screen before the first LLM call, and the LLM doesn't understand how the screen mechanism works.

## Scenarios

### Scenario 1: Project-specific question gets project-specific answer

**Situation**: User starts agent in `/home/user/projects/iptsd` directory with task "Tell me about iptsd"

**Current behavior**: LLM responds with general knowledge about macOS system daemon

**Desired behavior**:
- System message mentions working directory
- Initial screen shows project structure and git status
- Simulated message searches for "iptsd" in project files using editor
- LLM examines search results and answers based on local project

**Success criteria**: LLM reads README.md and project files instead of using general knowledge

### Scenario 2: AGENTS.md instructions are visible and followed

**Situation**: User has project with `AGENTS.md` file containing project-specific instructions like "Use pytest for testing, not unittest"

**Current behavior**: AGENTS.md is ignored, LLM uses default testing approach

**Desired behavior**:
- System environment includes AGENTS.md content in screen
- Screen updates after every command, keeping AGENTS.md visible
- LLM follows project-specific instructions from AGENTS.md

**Success criteria**: LLM consistently follows AGENTS.md guidelines throughout session

### Scenario 3: Screen mechanism is understood

**Situation**: LLM refers to information that's on screen but not in conversation history (e.g., "I can see from the project structure...")

**Current behavior**: This might seem confusing - where did that information come from?

**Desired behavior**:
- System message explains screen mechanism clearly
- LLM understands that screen updates after each command
- LLM knows what information is available on screen (git status, file tree, environment states)

**Success criteria**: LLM correctly references screen information and understands when to re-run commands vs when to use cached screen state

### Scenario 4: Git repository gets relevant initial action

**Situation**: User starts agent in git repository

**Current behavior**: No initial screen, LLM starts from scratch

**Desired behavior**:
- System screen shows git status and file tree
- Simulated message extracts keyword from task via "simple question"
- Simulated message searches for keyword using editor
- First real LLM response has full context from search results

**Success criteria**: LLM's first action builds on the simulated search rather than starting over

### Scenario 5: Non-git project works correctly

**Situation**: User starts agent in directory that's not a git repo

**Current behavior**: N/A (not implemented yet)

**Desired behavior**:
- System screen shows file tree but no git status
- Simulated message still performs keyword search
- Everything else works the same

**Success criteria**: Agent works smoothly in non-git directories

### Scenario 6: Task with no clear keyword

**Situation**: User provides vague task like "help me" or "what can you do?"

**Current behavior**: N/A (not implemented yet)

**Desired behavior**:
- Simple question to LLM returns generic/invalid keyword
- Fallback: extract meaningful word from task or use safe default
- Simulated message performs reasonable action (e.g., list directory)

**Success criteria**: Agent handles vague tasks without crashing or doing something nonsensical

## Plan

### Phase 1: System Environment (Orchestrator) ✅ COMPLETE

- [x] Create `orchestrator/orchestrator/environments/system.py`
  - [x] `SystemEnvironment` class extending `DeclarativeEnvironment`
  - [x] `__init__(project_dir: Path)` - store project directory
  - [x] `get_screen()` implementation:
    - [x] Show project directory path
    - [x] Include AGENTS.md content if file exists
    - [x] Include git status (if git repo) via subprocess
    - [x] Include file tree (`tree -L 2 -a --dirsfirst`) via subprocess with fallback to `ls -la`
    - [x] Return as ScreenSection with max_lines=100
  - [x] No command handlers yet (DeclarativeEnvironment with no @command decorators)
  - [x] `git add orchestrator/orchestrator/environments/system.py`

- [x] Update `orchestrator/orchestrator/loader.py`
  - [x] Import SystemEnvironment
  - [x] Add to built-in environments: `environments[EnvironmentName("system")] = SystemEnvironment(project_dir)`
  - [x] Place system first in dict (so it appears first in screen)
  - [x] `git add orchestrator/orchestrator/loader.py`

- [x] Test system environment
  - [x] Create `orchestrator/tests/test_system_environment.py`
  - [x] Test get_screen with and without AGENTS.md
  - [x] Test get_screen with and without git repo
  - [x] Test file tree generation
  - [x] `git add orchestrator/tests/test_system_environment.py`
  - [x] Verify `nix build .#orchestrator` succeeds

### Phase 2: Enhanced System Message (Agent) ✅ COMPLETE

- [x] Update `agent/src/context.rs::build_system_prompt()`
  - [x] Add section about working directory
  - [x] Add section explaining screen mechanism:
    - [x] Screen updates after each command
    - [x] System section shows project context
    - [x] Environment sections show state
    - [x] Screen content is not in conversation history
  - [x] Keep existing sections (environments, file restrictions, guidelines)
  - [x] `git add agent/src/context.rs`

- [x] Test system message
  - [x] Tests automatically updated (existing tests still pass)
  - [x] Verify `nix build .#agent` succeeds

### Phase 3: Simulated Initial Message (Agent) ✅ COMPLETE

- [x] Implement keyword extraction via "simple question"
  - [x] Add `extract_search_keyword()` function in `agent/src/agent.rs`
  - [x] Create separate LLM request with generic system message
  - [x] User message: "Given this task: '{task}'. What is the single most important keyword to search for? Respond with ONLY the keyword."
  - [x] Use max_tokens=20, temperature=0.3
  - [x] Parse response, extract first word, trim whitespace
  - [x] Fallback: extract first meaningful word from task (>3 chars, not common words)
  - [x] Fallback: use "main" as last resort

- [x] Generate simulated message
  - [x] Add `generate_simulated_message()` function in `agent/src/agent.rs`
  - [x] Format: "I can see the project structure and git status on screen. Let me search for '{keyword}' to find relevant files.\n\n```editor\nsearch \"{keyword}\" **/*\n```"
  - [x] Returns string (converted to Message::assistant in caller)

- [x] Update agent initialization in `run()`
  - [x] Before main loop, on first run (history.is_empty()):
    - [x] Save system prompt to history (already done)
    - [x] Save task message to history (already done)
    - [x] Extract keyword via simple question (NEW)
    - [x] Generate simulated message (NEW)
    - [x] Save simulated message to history (NEW)
    - [x] Send command to orchestrator (NEW)
    - [x] Receive response and screen (NEW)
    - [x] Save orchestrator response to history (NEW)
    - [x] Save screen to screens list (NEW)
  - [x] Main loop starts with real LLM seeing full context

- [x] Handle edge cases
  - [x] If simple question fails, use fallback keyword
  - [x] If keyword is empty/invalid, use fallback
  - [x] If orchestrator command fails, error propagates (user sees what happened)

- [x] `git add agent/src/agent.rs`
- [x] Verify `nix build .#agent` succeeds

### Phase 4: Testing and Verification

- [x] Test system environment screen content
  - [x] Created comprehensive unit tests in `test_system_environment.py`
  - [x] Tests verify AGENTS.md handling, git status, file tree with fallback
  - [x] All tests pass in `nix build .#orchestrator`

- [x] Test simulated message generation
  - [x] Functions implemented with proper fallback logic
  - [x] Edge cases handled (empty keyword, failed LLM call)
  - [x] Message format verified in implementation

- [ ] Test complete initialization flow (manual testing recommended)
  - [ ] Run agent with real task in test project
  - [ ] Verify system message includes project context explanation
  - [ ] Verify initial screen contains system section with tree/git
  - [ ] Verify simulated message executes search
  - [ ] Verify LLM sees search results in first real turn

- [x] Update documentation
  - [x] Added comments in code explaining simulated message purpose
  - [x] Task file updated with implementation status
  - [ ] Could add to orchestrator/agent design docs (optional future work)

## Dependencies

- Orchestrator implementation (complete)
- Agent core implementation (complete)
- DeclarativeEnvironment base class (complete)
- Editor search command (already exists)

## Outcome

Enhanced context management that enables the LLM to:
- Understand it's working in a specific project directory
- See project structure, git status, and AGENTS.md on every screen update
- Have an intelligent starting point (keyword search) before its first action
- Understand how the screen mechanism works and use it effectively

This improves the quality of LLM responses for project-specific questions and establishes patterns for future context management improvements.
