# 7aigent

7aigent is a general autonomous AI agent. It runs an interaction loop where an LLM executes actions in a system, and then receives feedback as a result of these actions, in order to complete a given task.

## Quick Start

<bash>
# Build the agent
nix build .#agent

# Run the agent
./result/bin/7aigent "your task here"
</bash>

## Customizing the Environment

The agent runs in a minimal sandbox by default (Python, bash, coreutils). To add project-specific tools (Rust, npm, Python packages, etc.):

**1. Create a development shell in your project:**

```nix
# flake.nix in your project
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }: {
    devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {
      packages = with nixpkgs.legacyPackages.x86_64-linux; [
        cargo rustc  # Rust toolchain
        (python3.withPackages (ps: [ ps.numpy ps.pandas ]))
      ];
    };
  };
}
```

**2. Configure the agent:**

```toml
# .7aigent/config.toml in your project
[sandbox]
shell_prefix = "nix develop --command"
```

Now the agent's Python environment will have numpy and pandas available, and bash can use cargo/rustc.

See [docs/design/sandbox/](./docs/design/sandbox/) for details.

## Development

This project uses Nix flakes for reproducible development environments.

<bash>
# Enter development shell
nix develop

# Or use direnv for automatic loading
direnv allow
</bash>

### Pre-commit Hooks

<bash>
pre-commit install
</bash>

Hooks run formatters and linters for Rust and Python code.

### Building

<bash>
# Build the agent (Rust)
nix build .#agent

# Build the orchestrator (Python) with all checks
# This runs: black, isort, ruff, and pytest
nix build .#orchestrator

# Run all checks (formatting, linting, tests)
nix flake check
</bash>

## Contributing

Current tasks are tracked in [docs/tasks/](./docs/tasks/).
