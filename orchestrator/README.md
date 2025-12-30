# 7aigent Orchestrator

The orchestrator is the main process inside the container that manages environments (bash, python, editor) and communicates with the agent.

## Architecture

- **Environments**: Stateful components that handle commands (bash shell, Python REPL, file editor)
- **Protocol**: Defines the contract all environments must implement
- **Communication**: NDJSON over stdin/stdout for agent-orchestrator communication

## Running

```bash
# Run the orchestrator
python -m orchestrator

# Or if installed as a package
orchestrator
```

## Testing

```bash
# Run all tests
pytest tests/ -v

# Run with coverage
pytest tests/ --cov=orchestrator
```

## Development

```bash
# Format code
black orchestrator/ tests/
isort orchestrator/ tests/

# Lint code
ruff check orchestrator/ tests/

# Type check (optional)
mypy orchestrator/
```

## Building with Nix

```bash
# Build the orchestrator package with all checks
nix build .#orchestrator

# This will:
# - Run black formatter check
# - Run isort import check
# - Run ruff linter
# - Run all pytest tests
```

See the [orchestrator design documentation](../docs/orchestrator.md) for detailed information about the architecture and design decisions.
