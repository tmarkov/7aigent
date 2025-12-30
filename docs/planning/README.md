# Tasks

Each task is stored as a markdown file in this directory, with the following sections:

- Description: Describe the task at hand
- Plan: A breakdown of the task into simple items that need to be completed. They should be formatted as a checklist, and updated as the task progresses.
- Other sections as necessary

# Plan:

This section contains a list of all tasks, formatted as a checklist. Tasks are topologically sorted by dependency. Each item also contains a link to the corresponding markdown file for the task.

## Planning Phase

- [x] [Create a plan for the project](file://./plan.md)
- [x] [Design the orchestrator and environment contract](file://./orchestrator-design.md)

## Implementation Phase

### Orchestrator Implementation (Standalone)

The orchestrator can work as a standalone tool without an agent. Focus on these tasks:

- [x] [Implement orchestrator core types](file://./implement-orchestrator-types.md)
- [ ] [Implement bash environment](file://./implement-bash-environment.md)
- [ ] [Implement python environment](file://./implement-python-environment.md)
- [ ] [Implement editor environment](file://./implement-editor-environment.md)
- [ ] [Implement orchestrator core](file://./implement-orchestrator-core.md)

### Agent Integration (Deferred)

These tasks are deferred until orchestrator is complete and tested:

- [ ] [Implement agent core](file://./implement-agent-core.md)
- [ ] [Implement container integration](file://./implement-container-integration.md)
- [ ] [End-to-end testing](file://./end-to-end-testing.md)
