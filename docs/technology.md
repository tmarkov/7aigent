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

**Contract**: See [orchestrator.md](orchestrator.md) for the complete Environment protocol specification

**Validation**: Runtime introspection by orchestrator validates type signatures and method presence

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
- Git with conventional commit messages
- Feature branches for new work

**Build System**:
- Nix flakes for reproducible builds
- All checks (formatting, linting, testing) integrated into Nix build
- Use `nix build .#orchestrator` or `nix build .#agent` to build with all checks

**Testing**:
- Python: pytest with hypothesis for property-based testing
- Rust: Built-in test framework with proptest for property-based testing

## Implemented Design Decisions

See [orchestrator.md](orchestrator.md) for complete specifications of:
- Environment contract (Protocol with handle_command, get_screen, shutdown)
- Agent-Orchestrator communication (NDJSON over stdin/stdout)
- Message formats and schemas
- All three built-in environments (bash, python, editor)

## Future Decisions

The following are deferred for future consideration:

- Editor environment LSP integration (goto_definition, find_references, rename)
- CI/CD pipeline setup
- Deployment and distribution approach
- Multi-LLM provider support details
