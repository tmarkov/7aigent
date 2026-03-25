# Task: Implement Interactive Mode

## Description

Add an interactive mode to the 7aigent CLI that allows users to have multi-turn conversations with the agent. Currently, the CLI is one-off: it receives a single instruction and exits. Interactive mode will enable users to provide follow-up instructions, ask questions, and iteratively work with the agent without restarting sessions.

## Context

- **Component**: `agent/src/main.rs` (entry point), `agent/src/cli.rs` (argument parsing), `agent/src/agent.rs` (interaction loop)
- **Related**: Session management (agent/src/session.rs), UI module (agent/src/ui.rs)
- **Motivation**: Users often need to iterate on tasks, ask clarifying questions, or provide additional context after seeing initial results. The current one-shot model requires starting a new session each time, losing context and requiring the agent to re-learn the project state.

## Scenarios

### Scenario 1: Iterative code refinement

**Situation**: User wants to add a feature, then refine it based on the results

**Workflow**:
```
$ 7aigent
7aigent> Add a --verbose flag to the list command

[Agent works, shows results, displays updated files]

7aigent> Now also add a --json output format

[Agent builds on previous work, maintains context]

7aigent> Actually, rename it to --format and support json|yaml|table

[Agent refactors based on user feedback]

7aigent> Run the tests to make sure everything works

[Agent runs tests, shows results]

7aigent> exit
Goodbye! Session saved: 12345
$
```

**Success criteria**: Agent maintains full context across turns. Each instruction builds on previous work. Session persists the entire conversation history.

### Scenario 2: Question-driven exploration

**Situation**: User is exploring an unfamiliar codebase and wants to ask questions

**Workflow**:
```
$ 7aigent
7aigent> What does the ContainerManager do?

[Agent explains, shows relevant code]

7aigent> How does it spawn the sandbox?

[Agent explains the spawn process]

7aigent> Show me the tests for that

[Agent finds and displays tests]

7aigent> Are there any edge cases that aren't tested?

[Agent analyzes test coverage, suggests gaps]

7aigent> exit
$
```

**Success criteria**: Agent answers questions accurately. Can navigate between explanation and code exploration. No need to re-explain context with each question.

### Scenario 3: Error recovery and debugging

**Situation**: User's task encounters an error and they want to debug it

**Workflow**:
```
$ 7aigent
7aigent> Add input validation to the config loader

[Agent makes changes, tests fail]

7aigent> The tests are failing. What went wrong?

[Agent analyzes failures, explains the issue]

7aigent> Fix it, but keep the validation

[Agent fixes the implementation]

7aigent> Still failing on edge case with empty strings

[Agent addresses specific edge case]

7aigent> That worked, thanks!
7aigent> exit
$
```

**Success criteria**: Agent can diagnose and fix issues in subsequent turns. User doesn't need to re-explain the task or context. Agent remembers what was tried before.

### Scenario 4: Contextual follow-up after session pause

**Situation**: User resumes a previous session and wants to continue where they left off

**Workflow**:
```
$ 7aigent resume 12345
Resuming session 12345
Task: Add authentication middleware

7aigent> Where were we?

[Agent summarizes progress so far]

7aigent> Continue with the rate limiting part

[Agent continues implementation]

7aigent> Actually, let's switch to interactive mode for testing
7aigent> exit

$ 7aigent
7aigent> Load session 12345 and test the middleware

[Agent loads context, runs tests]
```

**Success criteria**: Seamless transition between resume and interactive mode. Agent can summarize previous work. Context is preserved across mode switches.

### Scenario 5: Multi-task workflow

**Situation**: User completes one task and wants to start another in the same session

**Workflow**:
```
$ 7aigent
7aigent> Add the config validation feature

[Agent completes task, shows summary]

7aigent> Great, now let's work on error messages. Make them more user-friendly

[Agent starts new task, but has context from previous work]

7aigent> Actually, first document what we just did in CHANGELOG

[Agent switches tasks, uses context from earlier]

7aigent> Now back to error messages

[Agent continues with second task]

7aigent> exit
$
```

**Success criteria**: Agent can handle multiple tasks in sequence. Context from earlier tasks informs later work. No need to restart for new tasks.

### Scenario 6: Help and discovery

**Situation**: New user wants to learn how to use the agent

**Workflow**:
```
$ 7aigent
7aigent> help

Available commands:
  <task>    - Give the agent a task to work on
  help      - Show this help message
  status    - Show current session status
  clear     - Clear conversation history (keep session)
  exit      - Exit interactive mode

7aigent> What can you help me with?

[Agent explains capabilities]

7aigent> Show me an example of refactoring

[Agent demonstrates with a simple example]

7aigent> exit
$
```

**Success criteria**: Built-in help system. Agent can explain its own capabilities. New users can discover features interactively.

### Scenario 7: Interrupted work continuation

**Situation**: User's work is interrupted (lunch break, meeting) and they return

**Workflow**:
```
$ 7aigent
7aigent> Refactor the database layer to use connection pooling

[Agent makes progress, user's lunch break starts]

[... 1 hour later ...]

7aigent> What's the current status?

[Agent summarizes what was done, what remains]

7aigent> Continue from where you left off

[Agent continues implementation]

7aigent> exit
$
```

**Success criteria**: Agent maintains state during long sessions. Can provide status summaries. Can continue work seamlessly after interruptions.

### Scenario 8: Clarification and refinement

**Situation**: User provides vague instructions and refines them through conversation

**Workflow**:
```
$ 7aigent
7aigent> Make the code faster

[Agent asks clarifying questions or makes reasonable assumptions and asks for confirmation]

7aigent> Specifically the config loading, it's slow on large projects

[Agent focuses on config loading performance]

7aigent> I measured it, takes 2 seconds. Should be under 500ms

[Agent has specific target, works on optimization]

7aigent> Try caching the parsed config

[Agent implements suggestion]

7aigent> exit
$
```

**Success criteria**: Agent can handle vague initial requests. Conversation allows refinement without restarting. Agent incorporates feedback naturally.

## Plan

### Phase 1: CLI Changes

- [ ] Update `agent/src/cli.rs`
  - [ ] Remove validation that requires task or subcommand
  - [ ] Allow running with no arguments (triggers interactive mode)
  - [ ] Add `--interactive` flag for explicit interactive mode

- [ ] Update `agent/src/main.rs`
  - [ ] Add `handle_interactive()` function
  - [ ] Route to interactive mode when no task and no subcommand
  - [ ] Handle Ctrl+C gracefully (save session, exit cleanly)

### Phase 2: Interactive Loop

- [ ] Implement interactive prompt in `agent/src/interactive.rs` (new file)
  - [ ] Read-eval-print loop (REPL) for user input
  - [ ] Prompt display with session info
  - [ ] Command parsing (task, meta-commands, exit)
  - [ ] Handle empty input gracefully
  - [ ] Support multi-line input (optional, for complex tasks)

- [ ] Implement meta-commands
  - [ ] `help` - show available commands
  - [ ] `status` - show session status (cost, turns, task summary)
  - [ ] `clear` - clear conversation history
  - [ ] `exit` or `quit` - exit interactive mode
  - [ ] `save` - explicitly save session (auto-save on exit too)

### Phase 3: Session Continuity

- [ ] Update session management
  - [ ] Support appending to existing session in interactive mode
  - [ ] Track conversation turns separately from LLM calls
  - [ ] Persist conversation history across interactive turns
  - [ ] Handle session limits (max turns, max cost, max time)

- [ ] Update agent interaction
  - [ ] Reuse agent instance across turns (maintain container)
  - [ ] Pass conversation history to LLM on each turn
  - [ ] Update screen state after each turn
  - [ ] Handle agent errors without exiting interactive mode

### Phase 4: User Experience

- [ ] Implement UI improvements
  - [ ] Clear visual separation between turns
  - [ ] Show session info in prompt (e.g., `7aigent[12345]> `)
  - [ ] Progress indicators during agent work
  - [ ] Summary display after each turn (cost, tokens, time)

- [ ] Add readline support (optional enhancement)
  - [ ] Command history (up/down arrows)
  - [ ] Line editing
  - [ ] Tab completion for meta-commands

### Phase 5: Testing

- [ ] Write unit tests
  - [ ] Test command parsing (task vs meta-command)
  - [ ] Test session continuity across turns
  - [ ] Test meta-command behavior
  - [ ] Test graceful exit and cleanup

- [ ] Write integration tests
  - [ ] Test full interactive session with multiple turns
  - [ ] Test session save/restore
  - [ ] Test cost tracking across turns
  - [ ] Test error recovery without exiting

- [ ] Manual testing
  - [ ] Test all scenarios defined above
  - [ ] Test edge cases (empty input, very long input, special characters)
  - [ ] Test Ctrl+C handling
  - [ ] Test resource cleanup

### Phase 6: Documentation

- [ ] Update README.md
  - [ ] Document interactive mode usage
  - [ ] Add examples of multi-turn workflows

- [ ] Update docs/development/
  - [ ] Document interactive mode architecture
  - [ ] Document meta-command interface

## Dependencies

- Requires: Agent core (task 14) ✅
- Requires: Session management (task 14) ✅
- Requires: Container management (task 16) ✅

## Outcome

A fully functional interactive mode that:
1. Starts automatically when running `7aigent` with no arguments
2. Maintains context across multiple user inputs
3. Supports meta-commands for session control
4. Persists conversation history in session files
5. Handles errors gracefully without exiting
6. Provides clear visual feedback during operation
7. Exits cleanly with session preservation

Users can have natural, multi-turn conversations with the agent, enabling iterative development, debugging sessions, and exploratory workflows that are not possible with the current one-shot model.
