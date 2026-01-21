# Design Specifications

This directory contains complete design specifications for all major components of 7aigent.

## Design Philosophy

All designs follow a scenario-driven approach:
1. Define concrete scenarios (what must work)
2. Design for those scenarios
3. Verify implementation practicality
4. Simplify and prune unnecessary features
5. Review against scenarios

See [CLAUDE.md](../../CLAUDE.md) for the complete design workflow.

## Components

### [Agent](agent/)

The Rust binary that orchestrates LLM interactions:
- [Overview](agent/overview.md) - Purpose, responsibilities, high-level design
- [Architecture](agent/architecture.md) - Components, data flow, interaction patterns
- [Type System](agent/types.md) - Semantic types and why they matter
- [Sandboxing](agent/sandboxing.md) - Security model and isolation
- [Context Management](agent/context-management.md) - How context is tracked and managed
- [Cost Control](agent/cost-control.md) - Token tracking and budget enforcement

### [Orchestrator](orchestrator/)

The Python tool execution environment:
- [Overview](orchestrator/overview.md) - Purpose, use cases, requirements
- [Architecture](orchestrator/architecture.md) - Core components and protocols
- [Environments](orchestrator/environments.md) - Environment contract and built-ins
- [Bash Environment](orchestrator/bash-environment.md) - Shell command execution
- [Python Environment](orchestrator/python-environment.md) - Persistent REPL
- [Editor Environment](orchestrator/editor-environment.md) - File viewing and editing

### [Sandbox](sandbox/)

Bubblewrap-based security isolation:
- [Overview](sandbox/overview.md) - Design decision: bubblewrap over alternatives
- [Bubblewrap Implementation](sandbox/bubblewrap.md) - How bubblewrap is used
- [Customization](sandbox/customization.md) - Shell prefix and tool configuration
- [Security Model](sandbox/security.md) - Threat model and guarantees

### [Help System](help-system/)

Self-documenting capability discovery:
- [Overview](help-system/overview.md) - Problem and design goals
- [Declarative Environments](help-system/declarative-environments.md) - Base class design
- [Progressive Disclosure](help-system/progressive-disclosure.md) - Context-sensitive help

## Cross-Cutting Concerns

Several design principles apply across all components:

**Type Safety**: Use semantic types to make invalid states unrepresentable
- Agent: SessionId, LlmConfigSnapshot, TokenUsage
- Orchestrator: EnvironmentName, CommandOutput, ScreenState

**Graceful Degradation**: Errors inform the LLM, don't crash the system
- Unknown environments → error response with available environments
- Invalid commands → error with help text
- Timeouts → partial output with timeout indication

**Explicit State**: Current state is always visible
- Screen shows all active environment states
- LLM sees what the user would see
- No hidden state that affects behavior

## Design Documentation Guidelines

Each design document should:
- Start with concrete scenarios (what must work)
- Show examples, not just abstract descriptions
- Explain rationale (why decisions were made)
- Document trade-offs and alternatives considered
- Keep files focused and under 150 lines

Split large designs into multiple files rather than creating monolithic documents.
