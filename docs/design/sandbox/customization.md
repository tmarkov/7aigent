# Sandbox Customization

This document describes how users customize the sandbox environment for project-specific tooling.

## Design Philosophy

Users customize their environment AFTER agent installation using standard Nix workflows. The agent ships with a minimal sandbox containing only essentials (Python, bash, coreutils, nix). Users add project-specific tools through their project's `flake.nix`.

## Shell Prefix Customization (Implemented)

The `shell_prefix` approach allows post-install customization without rebuilding the agent.

### How Shell Prefix Works

1. **Agent reads config** and passes `shell_prefix` to orchestrator via `SHELL_PREFIX` environment variable
2. **Orchestrator's interactive environments** (Python, etc.) check for `SHELL_PREFIX` on startup
3. **If set**, they wrap their process spawn: `nix develop --command python` instead of just `python`
4. **Python REPL** starts inside the devshell with custom packages available
5. **Bash environment** ignores `SHELL_PREFIX` - agent controls bash shell directly via commands

### User Setup

**Step 1: Create development shell in project**

```nix
# flake.nix in project directory
{
  description = "My Rust Project";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.mkShell {
      packages = with nixpkgs.legacyPackages.x86_64-linux; [
        # Rust toolchain
        cargo rustc clippy rust-analyzer

        # Python packages
        (python3.withPackages (ps: [ ps.numpy ps.pandas ]))
      ];
    };
  };
}
```

**Step 2: Configure agent**

```toml
# .7aigent.toml
[sandbox]
shell_prefix = "nix develop --command"
```

### Example Session

<python>
# Agent uses Python environment
>>> import numpy as np  # Works! Python started in devshell
>>> arr = np.array([1, 2, 3])
</python>

<bash>
# Agent controls bash directly
$ nix develop  # Agent can enter devshell
(devshell) $ cargo build
(devshell) $ exit
</bash>

### Alternative Shell Wrappers

```toml
# Poetry projects
[sandbox]
shell_prefix = "poetry run"

# Conda environments
[sandbox]
shell_prefix = "conda run -n myenv"

# No customization (default minimal environment)
[sandbox]
# shell_prefix not set
```

### Benefits

✅ **Post-install customization**: Edit flake.nix, no agent rebuild
✅ **One agent binary**: Works for all project types
✅ **Standard workflow**: Uses familiar `nix develop`
✅ **Encapsulated**: Agent → sandbox → orchestrator boundary maintained
✅ **Extensible**: Works with any shell wrapper

## Alternative: extraPackages Approach (Not Implemented)

This approach was considered but not implemented in V1. It would require rebuilding the agent with custom packages.

### Project-Specific Customization

Users create a custom Nix file in their project: `.7aigent/sandbox.nix`:

```nix
{ pkgs }:

# Extra packages to add to the sandbox
with pkgs; [
  # Rust toolchain
  cargo
  rustc
  clippy
  rust-analyzer

  # Node.js
  nodejs_20

  # Project-specific tools
  postgresql
  redis
]
```

Then reference it in `.7aigent.toml`:

```toml
[sandbox]
# Path to Nix file that returns a list of packages
extra_packages = ".7aigent/sandbox.nix"
```

**Agent behavior**:

```rust
// Simplified logic in agent
fn build_sandbox(config: &Config) -> Result<PathBuf> {
    let extra_packages = if let Some(nix_file) = &config.sandbox.extra_packages {
        // Build agent with custom packages
        let expr = format!(
            r#"
            let
              pkgs = import <nixpkgs> {{}};
              orchestrator = pkgs.callPackage ./orchestrator {{}};
              extraPackages = import {} {{ inherit pkgs; }};
            in
              pkgs.callPackage ./agent {{
                inherit orchestrator;
                sandboxExtraPackages = extraPackages;
              }}
            "#,
            nix_file
        );

        run_nix_build(&expr)?
    } else {
        // Use default agent
        run_nix_build(".#agent")?
    };

    Ok(extra_packages)
}
```

### Overlay Approach (Simpler)

For V1, this could be simplified by just rebuilding the sandbox with a user-provided package list:

<bash>
# User runs this once when they add dependencies
nix build --impure --expr '
  let
    pkgs = import <nixpkgs> {};
    flake = builtins.getFlake (toString ./.);
    extraPkgs = import ./.7aigent/sandbox.nix { inherit pkgs; };
  in
    flake.packages.${builtins.currentSystem}.agent.override {
      sandboxExtraPackages = extraPkgs;
    }
'

# This builds a custom agent with custom sandbox
# Result link is used by agent
</bash>

Then `.7aigent.toml` just points to the result:

```toml
[sandbox]
# Use custom-built sandbox
sandbox_path = ".7aigent/result/bin/7aigent-sandbox"
```

**Much simpler for V1**: User rebuilds when they change dependencies, agent just uses the specified path.

## Scenario Examples

### Rust Project Development

**Setup:**
```nix
# flake.nix
{
  devShells.x86_64-linux.default = pkgs.mkShell {
    packages = with pkgs; [ cargo rustc clippy rust-analyzer ];
  };
}
```

```toml
# .7aigent.toml
[sandbox]
shell_prefix = "nix develop --command"
```

**Result**: Rust toolchain available in orchestrator's bash environment

### Python Poetry Project

```nix
# flake.nix
{
  devShells.x86_64-linux.default = pkgs.mkShell {
    packages = [ pkgs.poetry ];
  };
}
```

Now `poetry install`, `poetry run` work in orchestrator's bash environment.

### Multi-Language Monorepo

```nix
# flake.nix
{
  devShells.x86_64-linux.default = pkgs.mkShell {
    packages = with pkgs; [
      # TypeScript/JavaScript
      nodejs_20

      # Python
      poetry

      # Rust
      cargo rustc
    ];
  };
}
```

All toolchains available simultaneously.

## Related Documents

- [Sandbox Overview](./) - Design rationale and principles
- [Bubblewrap Implementation](bubblewrap.md) - Architecture details
- [Security Model](security.md) - What customization can and cannot do
