# 7aigent

7aigent is an general autonomous AI agent. It runs an interaction loop where an LLM executes actions in a system, and then receives feedback as a result of these actions, in order to complete a given task.

## Development

This project uses Nix flakes for reproducible development environments.

```bash
# Enter development shell
nix develop

# Or use direnv for automatic loading
direnv allow
```

### Pre-commit Hooks

```bash
pre-commit install
```

Hooks run formatters and linters for Rust and Python code.

### Building

```bash
# Build the agent
nix build .#agent

# Run all checks (formatting, linting, tests)
nix flake check
```

## Contributing

The current tasks are documented in the ./docs/planning/ directory.
