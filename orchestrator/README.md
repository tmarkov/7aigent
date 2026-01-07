# 7aigent Orchestrator

The orchestrator is the main process inside the container that manages environments (bash, python, editor) and communicates with the agent.

## Architecture

- **Environments**: Stateful components that handle commands (bash shell, Python REPL, file editor)
- **Protocol**: Defines the contract all environments must implement
- **Communication**: NDJSON over stdin/stdout for agent-orchestrator communication

See [docs/orchestrator.md](../docs/orchestrator.md) for complete architecture and design documentation.

## Development

This project uses Nix for reproducible builds with integrated checks:

```bash
# Build with all checks (formatting, linting, tests)
nix build .#orchestrator

# Development shell with all tools
nix develop

# Run orchestrator directly (for manual testing)
python -m orchestrator
```
