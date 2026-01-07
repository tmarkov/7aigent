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
2. **Design**: Work through design workflow, add design section to task file
3. **Implementation**: Write code, update plan checklist as you go
4. **Completion**: Mark task as complete in the master task list below

Completed tasks remain in this directory as historical record.

See [CLAUDE.md](../../CLAUDE.md) for detailed workflow guidance.

---

# Master Task List

This section contains a list of all tasks, formatted as a checklist. Tasks are topologically sorted by dependency. Each item also contains a link to the corresponding markdown file for the task.

## Planning Phase

- [x] [Create a plan for the project](file://./plan.md)
- [x] [Design the orchestrator and environment contract](file://./orchestrator-design.md)

## Implementation Phase

### Orchestrator Implementation (Standalone)

The orchestrator can work as a standalone tool without an agent. Focus on these tasks:

- [x] [Implement orchestrator core types](file://./implement-orchestrator-types.md)
- [x] [Implement bash environment](file://./implement-bash-environment.md)
- [x] [Implement minimal orchestrator](file://./implement-minimal-orchestrator.md) - Get bash working end-to-end first
- [x] [Implement python environment](file://./implement-python-environment.md)
- [x] [Implement editor environment](file://./implement-editor-environment.md)
- [x] [Implement orchestrator core](file://./implement-orchestrator-core.md) - Full version with all environments
- [ ] [Improve tool discoverability](file://./improve-tool-discoverability.md) - Allow agents to discover environment capabilities

### Agent Integration (Deferred)

These tasks are deferred until orchestrator is complete and tested:

- [ ] [Implement agent core](file://./implement-agent-core.md)
- [ ] [Implement container integration](file://./implement-container-integration.md)
- [ ] [End-to-end testing](file://./end-to-end-testing.md)
