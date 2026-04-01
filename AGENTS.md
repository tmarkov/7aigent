# Instructions for LLM Agents

When working on this project, follow these guidelines:

## Project Philosophy

**This project is designed for LLM-driven development.** The entire codebase will be written by LLMs, with minimal human review. This shapes our core principles:

1. **Strong static analysis and type safety**: We rely on compilers and type checkers to catch errors, not human code review
2. **"If it compiles, it works"**: Use type systems to make invalid states unrepresentable
3. **Comprehensive tooling**: Formatters and linters enforce conventions automatically
4. **Explicit over implicit**: Code should be clear and obvious, not clever
5. **Test thoroughly**: Property-based testing ensures correctness across input space

See [docs/reference/testing.md](docs/reference/testing.md) for testing strategy.

See [docs/reference/conventions/general.md](docs/reference/conventions/general.md) for detailed conventions that support these principles.

## Build System

**This project uses Nix for reproducible builds and automated verification.**

All code verification (formatting, linting, testing) is integrated into the Nix build:

```bash
# Build the agent (Rust) with all checks
nix build .#agent
# Runs: rustfmt check, clippy, cargo test

# Build the orchestrator (Python) with all checks
nix build .#orchestrator
# Runs: black check, isort check, ruff check, pytest

# Development shell with all tools
nix develop
```

**Important**: Don't run formatters and linters directly during implementation. Instead:
- Make your changes
- Run `nix build .#<package>` to verify everything
- The build will fail if any check fails
- This ensures you never forget a step

This approach guarantees that if the build succeeds, all code meets quality standards.

---

## Project Organization

Understanding where different types of work belong:

### Documentation (docs/)

`docs/` contains reference documentation, design decisions, and architecture:
- **Purpose**: Explains HOW things work and WHY decisions were made
- **Audience**: Anyone trying to understand the system
- **Lifecycle**: Long-term reference material
- **Examples**: `docs/design/orchestrator/`, `docs/reference/conventions/general.md`, `docs/development/technology.md`

### Tasks (docs/tasks/)

`docs/tasks/` contains task definitions and work tracking:
- **Purpose**: Describes WHAT needs to be done
- **Audience**: Whoever is doing the work (human or LLM)
- **Lifecycle**: Active during work, kept as historical record when completed
- **Examples**: `docs/tasks/implement-bash-environment.md`, `docs/tasks/improve-tool-discoverability.md`
- **Format**: Each task has description, scenarios, plan checklist, dependencies, and outcome

**Key distinction**: Documentation explains existing systems. Tasks describe work to be done.

---

## Task Lifecycle

Work proceeds in three distinct phases:

### 1. Task Definition

**Goal**: Clearly define the problem without jumping to solutions.

**Outputs**:
- New file in `docs/tasks/` (e.g., `docs/tasks/fix-memory-leak.md`)
- Entry in `docs/tasks/README.md` checklist
- Problem description and context
- 3-5 concrete scenarios (WHAT needs to work, not HOW)
- Initial thoughts on constraints (optional)

**Stop here** - don't design yet. Creating a task file is about articulating the problem clearly, not solving it.

**Example task file structure**:
```markdown
# Task: Fix Memory Leak in Python Environment

## Problem
Python environment consumes unbounded memory over long sessions...

## Context
- Component: orchestrator/environments/python.py
- Related: Issue #42, Performance requirements in docs/design/orchestrator/

## Scenarios
1. Agent runs 1000 small Python commands - memory usage should stay bounded
2. Agent creates large DataFrame, then deletes it - memory should be freed
3. Agent imports heavy library - memory increase is one-time, not cumulative

## Initial Thoughts
- Likely in variable tracking or REPL output buffering
- Need to profile to confirm root cause
```

### 2. Design

**Goal**: Work through the 8-step scenario-driven design workflow to create a solution.

**When**: After task is defined and you're ready to start solving it.

**Outputs**:
- Design decisions and rationale
- Concrete examples of the solution
- Trade-offs and alternatives considered
- Design document in `docs/` (e.g., `docs/capability-discovery.md`)

**Process**: Follow the full Scenario-Driven Design Workflow. See [docs/reference/design-workflow.md](docs/reference/design-workflow.md) for details.

### 3. Implementation

**Goal**: Write the code, tests, and update documentation.

**When**: After design is complete and reviewed.

**Outputs**:
- Working code that passes all checks (`nix build` succeeds)
- Comprehensive tests
- Updated documentation if design changed during implementation
- Checked-off items in task file's plan checklist

**Process**: Follow the Implementation Task checklist. See [docs/reference/implementation-checklist.md](docs/reference/implementation-checklist.md) for details.

---

## Design Workflow

For detailed guidance on scenario-driven design, see [docs/reference/design-workflow.md](docs/reference/design-workflow.md).

Key principles:
- Start with concrete scenarios before designing
- Mentally trace implementation of critical paths
- Simplify and prune features
- Iterate until design is solid

---

## Implementation Checklist

For detailed implementation guidance, see [docs/reference/implementation-checklist.md](docs/reference/implementation-checklist.md).

Key principles:
- Always use `nix build` to verify changes
- `git add` files immediately after creation
- Write tests as you go
- Build frequently to catch issues early

---

## Common Pitfalls

For common design and implementation pitfalls, see [docs/reference/common-pitfalls.md](docs/reference/common-pitfalls.md).

Key pitfalls to avoid:
- Designing without scenarios
- Solution-focused scenarios
- Not tracing implementation
- Over-engineering
- Bypassing existing abstractions

---

## When You're Stuck

### If Unsure About Requirements

1. Review related documentation in ./docs/
2. Write example scenarios to clarify what's needed
3. Ask user with specific options and trade-offs
4. Don't guess - wrong assumptions waste more time than questions

### If Design Seems Too Complex

1. Go back to scenarios - what do they actually need?
2. Question every feature - can it be removed or simplified?
3. Look for simpler approaches that solve 80% of cases
4. Consider deferring features to future version
5. Ask if trade-off (less features, more simplicity) is acceptable

### If Finding Implementation Issues

1. Don't paper over them - go back and redesign
2. The implementation issues are telling you something about the design
3. Simpler design → simpler implementation
4. If something feels impossible, it probably is

### If Design Review Reveals Problems

1. This is good - better to find now than during implementation
2. Grade the current design honestly
3. Identify specific improvements
4. Iterate - good design takes multiple passes
5. Ask for feedback on refined design

---

## Success Criteria

### For Design Work

You're doing well if:
- **Started with concrete scenarios** before designing
- **Mentally traced implementation** of critical paths
- **Identified and confirmed assumptions** early
- **Design is simple** - pruned unnecessary features
- **Scenarios work well** with your design
- **Contradictions resolved** or acknowledged as conscious trade-offs
- **Rationale documented** - why decisions were made
- **Grade is A or B** when reviewing against scenarios

### For Implementation Work

You're doing well if:
- Code compiles/type-checks on first try (or after minimal fixes)
- `nix build .#agent` or `nix build .#orchestrator` succeeds
  - This verifies formatters (rustfmt, black, isort) pass
  - This verifies linters (clippy, ruff) pass
  - This verifies all tests pass
- Tests are comprehensive and use property-based testing where applicable
- Documentation is clear and up-to-date
- You followed reference/coding-style.md strictly
- You found no surprises (design was accurate)

### For Overall Collaboration

You're doing well if:
- You ask questions when assumptions are unclear
- You present options with trade-offs, not unilateral decisions
- You iterate based on feedback
- You're honest about design quality (not defensive)
- You learn from reviews and improve next time
- You follow the scenario-driven workflow
