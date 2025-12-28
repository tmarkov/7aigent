# Technology Choices

This document outlines the technologies chosen for 7aigent.

For coding conventions and style guidelines, see [coding-style.md](coding-style.md).

## Technology Stack

### Agent (Outside Container)

**Language**: Rust

**Rationale**:
- Strongest compile-time guarantees ("if it compiles, it works")
- Excellent for LLM-driven development due to strict type system and borrow checker
- Catches memory safety, null references, and data races at compile time
- Strong tooling for enforcing conventions (rustfmt, clippy)

**Key Dependencies**:
- **Async runtime**: tokio (industry standard, huge ecosystem, excellent documentation)
- **LLM API clients**: Provider SDKs (e.g., anthropic-sdk for Claude, async-openai for OpenAI)
  - Multi-provider support: Design to work with multiple LLM providers
- **Error handling**: thiserror (for defining specific error types to enable pattern matching)
  - Define specific error enums for `LLMError` and `OrchestratorError`
  - Use pattern matching to handle different error cases:
    - LLM rate limits, timeouts, server errors → exponential backoff retry
    - LLM auth errors, invalid requests → graceful crash with diagnostics
    - Orchestrator EOF/parse errors → graceful crash
- **HTTP client**: reqwest (for any additional HTTP needs)

### Orchestrator (Inside Container)

**Language**: Python 3.13

**Rationale**:
- Ease of creating and loading environment modules (primary requirement)
- Excellent subprocess management with pexpect
- Dynamic module loading via importlib
- Runtime contract validation via Protocol and introspection
- Trade-off: Weaker compile-time guarantees, but runtime validation compensates
- Simpler for the orchestrator's role as glue code

**Key Dependencies**:
- **pexpect**: For expect-like subprocess communication with environment child processes
- **Type checking**: Runtime validation using `typing.Protocol` and introspection
  - Validate environment modules implement required contract at load time
  - Display diagnostic messages on screen for invalid modules
- **Standard library**: importlib, subprocess, asyncio, json

### Environments

**Language**: Python modules

**Contract**: To be designed (future task)

**Validation**: Runtime introspection by orchestrator

### Containerization

**Technology**: Podman

**Rationale**:
- Daemonless architecture (better security model)
- Rootless containers by default
- Compatible with Docker tooling
- Better for sandboxed execution

**Configuration**:
- Container only has access to project directory
- Whitelisted internet resources (to be defined)
- Orchestrator runs as main container process

## Development Workflow

**Version Control**:
- Git for version control (to be initialized)
- Conventional commits for commit messages
- Feature branches for new work

**Testing**:
- Python: pytest with hypothesis for property-based testing
- Rust: Built-in test framework with proptest for property-based testing
- To be further defined in development environment setup

**CI/CD**:
- To be defined in development environment setup

## Future Decisions

The following decisions are deferred to specific design tasks:

- Environment contract specification
- Agent-Orchestrator communication protocol details
- Editor environment LSP integration approach
- Specific message formats and schemas
- Testing strategy and framework choices
- Deployment and distribution approach
