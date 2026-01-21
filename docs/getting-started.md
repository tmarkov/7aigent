# Getting Started with 7aigent

7aigent is a general autonomous AI agent that runs an interaction loop where an LLM executes actions in a system and receives feedback to complete tasks.

## What is 7aigent?

7aigent consists of two main components:

1. **Agent** (Rust) - Orchestrates LLM interactions, manages sessions, handles sandboxing
2. **Orchestrator** (Python) - Provides tool execution environments (bash, python, editor)

The agent sends commands to the orchestrator, which executes them and returns results. The LLM sees the results and decides what to do next.

## Quick Start

```bash
# Build the agent
nix build .#agent

# Run the agent
./result/bin/7aigent "your task here"
```

## How It Works

1. **You give a task**: "Debug this Python script" or "Add a feature to this Rust project"
2. **Agent starts LLM loop**: Sends task to LLM (Claude, etc.)
3. **LLM decides actions**: "Read file X", "Run command Y", "Edit file Z"
4. **Orchestrator executes**: Runs commands in isolated environments
5. **LLM sees results**: Gets output, errors, current state
6. **Repeat until done**: LLM continues until task is complete

## Key Features

### Multiple Environments

- **Bash**: Run shell commands, manage files
- **Python**: Execute Python code with persistent REPL
- **Editor**: View and edit files with pattern-based navigation

### Sandboxed Execution

All commands run in a bubblewrap sandbox with:
- Isolated filesystem (only project directory visible)
- No network access by default
- Resource limits
- Custom tool availability via shell_prefix

### Session Management

- Resume interrupted sessions
- Inspect session history
- Track token usage and costs

## Customizing the Sandbox

The agent runs in a minimal environment by default. To add project-specific tools:

**1. Create a dev shell in your project:**

```nix
# flake.nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }: {
    devShells.x86_64-linux.default =
      nixpkgs.legacyPackages.x86_64-linux.mkShell {
        packages = with nixpkgs.legacyPackages.x86_64-linux; [
          cargo rustc
          (python3.withPackages (ps: [ ps.numpy ]))
        ];
      };
  };
}
```

**2. Configure the agent:**

```toml
# .7aigent.toml
[sandbox]
shell_prefix = "nix develop --command"
```

Now the agent can use cargo, rustc, and Python with numpy.

See [Sandbox Customization](design/sandbox/customization.md) for details.

## Next Steps

- [Architecture Overview](architecture.md) - Understand how components interact
- [Agent Design](design/agent/) - Deep dive into agent architecture
- [Orchestrator Design](design/orchestrator/) - How environments work
- [Contributing](development/contributing.md) - Join development
