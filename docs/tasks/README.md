# Tasks

This directory contains task definitions and work tracking for the 7aigent project.

## What is a Task?

A task is a discrete piece of work to be done - designing a component, implementing a feature, fixing a bug, or making an improvement. Each task is tracked in its own markdown file.

**Tasks are NOT documentation.** For design documents, architecture decisions, and reference material, see `../` (the docs/ directory).

**Key distinction**:
- **Documentation** (`docs/*.md`): Explains HOW things work and WHY decisions were made
- **Tasks** (`docs/tasks/*.md`): Describes WHAT needs to be done and tracks progress

## Task File Structure

Each task file contains:

- **Description**: What needs to be done and why (2-3 sentences)
- **Scenarios** (optional but recommended): 3-5 concrete situations that must work (describes WHAT, not HOW)
- **Plan**: Checklist of steps, updated as work progresses
- **Dependencies**: What must be complete before starting this task
- **Outcome**: What success looks like

## Task Lifecycle

1. **Task Definition**: Create task file with problem, context, scenarios. Stop here.
- [x] 28. Add project documentation README
3. **Implementation**: Write code, update plan checklist as you go
4. **Completion**: Mark task as complete in the master task list below

Completed tasks remain in this directory as historical record.

See [CLAUDE.md](../../CLAUDE.md) for detailed workflow guidance.

---

# Master Task List

This section contains a list of all tasks, formatted as a checklist. Tasks are topologically sorted by dependency. Each item also contains a link to the corresponding markdown file for the task.

## Planning Phase

- [x] [01 - Create a plan for the project](./01-plan.md)
- [x] [02 - Design the orchestrator and environment contract](./02-orchestrator-design.md)

## Implementation Phase

### Orchestrator Implementation (Standalone)

The orchestrator can work as a standalone tool without an agent. Focus on these tasks:

- [x] [03 - Implement orchestrator core types](./03-implement-orchestrator-types.md)
- [x] [04 - Implement bash environment](./04-implement-bash-environment.md)
- [x] [05 - Implement minimal orchestrator](./05-implement-minimal-orchestrator.md) - Get bash working end-to-end first
- [x] [06 - Implement python environment](./06-implement-python-environment.md)
- [x] [07 - Implement editor environment](./07-implement-editor-environment.md)
- [x] [08 - Implement orchestrator core](./08-implement-orchestrator-core.md) - Full version with all environments
- [x] [09 - Design help system](./09-design-help-system.md) - Design self-documenting capability discovery
- [x] [10 - Implement DeclarativeEnvironment base class](./10-implement-declarative-environment.md) - Base class for structured command environments with auto-help
- [x] [11 - Implement help system](./11-implement-help-system.md) - Implement the designed help system
- [x] [12 - Review orchestrator implementation](./12-review-orchestrator-implementation.md) - Comprehensive review of design, code, tests, and documentation
- [x] [25 - Implement InteractiveEnvironment base class](./25-implement-interactive-environment.md) - Create base class for interactive processes, refactor bash and python environments ✅ Completed
- [x] [27 - Implement auxiliary LLM query protocol](./27-implement-auxiliary-llm-queries.md) - Extend protocol for environments to request AI assistance through agent (isolated orchestrator)
- [x] [26 - Reimplement editor environment with query-based pipeline system](./26-reimplement-editor-environment.md) - Replace snapshot-based views with procedural queries, enable hypothesis testing and multi-file refactoring ✅ Completed

### Agent Design and Implementation

These tasks are for designing and implementing the agent:

- [x] [13 - Design the agent](./13-design-agent.md) - Define scenarios, requirements, and architecture
- [x] [14 - Implement agent core](./14-implement-agent-core.md)
- [x] [15 - Design sandbox container](./15-design-sandbox-container.md) - Design bubblewrap-based sandbox to replace Podman
- [x] [16 - Implement sandbox container](./16-implement-sandbox-container.md) - Bubblewrap-based sandbox with integrated tests
- [-] [~~17 - End-to-end testing~~](./17-end-to-end-testing.md) - **DROPPED** - Replaced by tasks 22-24

### Context Management

- [x] [19 - Improve context management](./19-improve-context-management.md) - Enhance system message, add system environment, implement simulated initial message

### Documentation

- [ ] [18 - Refactor documentation structure](./18-refactor-documentation-structure.md) - Reorganize docs for better navigation

### User Experience

- [ ] [28 - Implement init command](./28-implement-init-command.md) - Replace outdated init with interactive setup that creates proper directory structure and uses agent to configure project-specific settings
- [ ] [29 - Implement interactive mode](./29-implement-interactive-mode.md) - Add interactive REPL mode for multi-turn conversations with the agent

### Testing

- [x] [20 - Rework testing strategy](./20-rework-testing-strategy.md) - Replace superficial tests with substantive requirement-based tests ✅ Completed
- [x] [21 - Fix orchestrator error handling](./21-fix-orchestrator-error-handling.md) - Replace success field with processed field, add exit_code for bash ✅ Completed
- [ ] [22 - Add LLM integration tests (Tier 2)](./22-llm-integration-tests.md) - Test with real LLM API, validate session management and cost tracking
- [ ] [23 - Create example sessions](./23-example-sessions.md) - Create example projects demonstrating agent capabilities
- [ ] [24 - Performance benchmarking](./24-performance-benchmarking.md) - Measure baselines and stress test long sessions
