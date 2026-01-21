# Bubblewrap Implementation

This document describes the architecture and implementation of 7aigent's bubblewrap-based sandbox.

## Architecture

### Three-Part Nix Build

```
┌─────────────────────────────────────────────────────────────┐
│  Nix Flake Outputs                                          │
│                                                              │
│  1. orchestrator (Python package)                           │
│     └─ Python 3.13 + orchestrator + environments           │
│                                                              │
│  2. sandbox (shell script + dependencies)                   │
│     └─ bubblewrap + Python + coreutils + orchestrator      │
│     └─ customizable with extra packages                     │
│                                                              │
│  3. agent (Rust binary)                                     │
│     └─ depends on sandbox derivation                        │
│     └─ runs sandbox script to spawn orchestrator           │
└─────────────────────────────────────────────────────────────┘
```

### Runtime Architecture

```
Host System
┌──────────────────────────────────────────────────────────────┐
│                                                               │
│  ┌─────────────────┐                                         │
│  │  Agent (Rust)   │                                         │
│  │  (Unprivileged) │                                         │
│  └────────┬────────┘                                         │
│           │ spawns                                           │
│           │                                                   │
│  ┌────────▼─────────────────────────────────────────────┐   │
│  │  Sandbox Script (from Nix)                           │   │
│  │                                                        │   │
│  │  #!/usr/bin/env bash                                  │   │
│  │  exec bubblewrap \                                    │   │
│  │    --unshare-all \                                    │   │
│  │    --share-net \                                      │   │
│  │    --bind /nix/store /nix/store \                    │   │
│  │    --bind "$PROJECT_DIR" /workspace \                │   │
│  │    --ro-bind /etc/resolv.conf /etc/resolv.conf \     │   │
│  │    ... \                                              │   │
│  │    python -m orchestrator                             │   │
│  └────────┬─────────────────────────────────────────────┘   │
│           │ spawns bubblewrap                                │
│           │                                                   │
│  ┌────────▼─────────────────────────────────────────────┐   │
│  │ Bubblewrap Sandbox (Linux Namespaces)                │   │
│  │                                                        │   │
│  │  ┌──────────────────────────────────────────────┐    │   │
│  │  │ Orchestrator (Python)                        │    │   │
│  │  │  - Python environments (bash, python, editor)│    │   │
│  │  │  - Reads commands from stdin (NDJSON)        │    │   │
│  │  │  - Writes responses to stdout (NDJSON)       │    │   │
│  │  └──────────────────────────────────────────────┘    │   │
│  │                                                        │   │
│  │  Mount namespace:                                     │   │
│  │    /nix/store      (ro-bind, all packages available) │   │
│  │    /workspace      (bind, project directory)          │   │
│  │    /tmp            (tmpfs)                            │   │
│  │    /dev            (dev filesystem)                   │   │
│  │    /proc           (proc filesystem)                  │   │
│  │                                                        │   │
│  │  Network namespace: shared with host (--share-net)   │   │
│  │  PID namespace: isolated                              │   │
│  │  IPC namespace: isolated                              │   │
│  └───────────────────────────────────────────────────────┘   │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

**Communication**: Agent ↔ Sandbox uses stdin/stdout pipes (NDJSON protocol, see [../orchestrator/](../orchestrator/))

## Nix Derivation Structure

### 1. Orchestrator Package

Located in `orchestrator/default.nix`:

```nix
{ pkgs, python3Packages }:

python3Packages.buildPythonApplication {
  pname = "7aigent-orchestrator";
  version = "0.1.0";

  src = ./.;

  propagatedBuildInputs = with python3Packages; [
    pexpect
    # ... other deps
  ];

  # Tests, formatting, linting already configured
}
```

### 2. Sandbox Script and Environment

New file: `sandbox/default.nix`:

```nix
{ pkgs
, orchestrator
, extraPackages ? []  # Customization point
}:

let
  # All packages available in the sandbox
  sandboxPackages = with pkgs; [
    # Essential for orchestrator
    python313
    bash
    coreutils
    findutils
    procps

    # For FHS compatibility
    glibc

    # The orchestrator itself
    orchestrator
  ] ++ extraPackages;  # User customizations added here

  # Build an FHS-like environment
  sandboxEnv = pkgs.buildEnv {
    name = "7aigent-sandbox-env";
    paths = sandboxPackages;
    pathsToLink = [ "/bin" "/lib" "/share" "/etc" ];
  };

in pkgs.writeShellScriptBin "7aigent-sandbox" ''
  set -euo pipefail

  # Arguments: PROJECT_DIR [EXTRA_BWRAP_ARGS...]
  PROJECT_DIR="''${1:?PROJECT_DIR required}"
  shift

  # Build bubblewrap command
  exec ${pkgs.bubblewrap}/bin/bwrap \
    --unshare-all \
    --share-net \
    --new-session \
    --die-with-parent \
    \
    `# Mount /nix/store read-only (all packages available)` \
    --ro-bind /nix/store /nix/store \
    \
    `# Mount project directory read-write` \
    --bind "''${PROJECT_DIR}" /workspace \
    --chdir /workspace \
    \
    `# Set up essential filesystems` \
    --tmpfs /tmp \
    --proc /proc \
    --dev /dev \
    \
    `# FHS compatibility symlinks` \
    --symlink usr/bin /bin \
    --symlink usr/lib /lib \
    --symlink usr/lib64 /lib64 \
    \
    `# Minimal /usr from our env` \
    --ro-bind ${sandboxEnv}/bin /usr/bin \
    --ro-bind ${sandboxEnv}/lib /usr/lib \
    \
    `# Resolve DNS` \
    --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
    --ro-bind-try /etc/hosts /etc/hosts \
    \
    `# Environment variables` \
    --setenv PATH "/usr/bin:${sandboxEnv}/bin" \
    --setenv PYTHONPATH "${orchestrator}/lib/python3.13/site-packages" \
    --setenv HOME "/tmp/home" \
    --unsetenv SESSION_MANAGER \
    \
    `# User-provided extra arguments` \
    "''$@" \
    \
    `# Execute orchestrator` \
    ${orchestrator}/bin/orchestrator
''
```

**Key features:**
- `extraPackages`: Customization point for user dependencies
- `--unshare-all --share-net`: Isolate everything except network
- `--ro-bind /nix/store`: All Nix packages available read-only
- `--bind PROJECT_DIR /workspace`: Project directory read-write
- `--die-with-parent`: Cleanup if agent crashes
- FHS symlinks: Makes Python and tools findable at standard paths

### 3. Agent with Embedded Sandbox

Updated `agent/default.nix`:

```nix
{ pkgs
, rustPlatform
, orchestrator
, makeWrapper
, sandboxExtraPackages ? []  # Expose customization
}:

let
  sandbox = pkgs.callPackage ../sandbox {
    inherit orchestrator;
    extraPackages = sandboxExtraPackages;
  };
in
rustPlatform.buildRustPackage {
  pname = "7aigent";
  version = "0.1.0";

  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    # Wrap agent binary with SANDBOX_PATH
    wrapProgram $out/bin/7aigent \
      --set SANDBOX_PATH ${sandbox}/bin/7aigent-sandbox
  '';

  # ... clippy, rustfmt, tests
}
```

## Sandbox Execution

### Agent Integration

**Agent Rust code** uses environment variable:

```rust
// agent/src/container/manager.rs

pub struct ContainerManager {
    sandbox_path: PathBuf,
}

impl ContainerManager {
    pub fn new() -> Result<Self> {
        let sandbox_path = std::env::var("SANDBOX_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                // Fallback: look in PATH
                PathBuf::from("7aigent-sandbox")
            });

        Ok(Self { sandbox_path })
    }

    pub fn spawn(
        &self,
        project_dir: &Path,
        config: &SandboxConfig,
    ) -> Result<ContainerHandle> {
        let mut cmd = Command::new(&self.sandbox_path);

        // First argument: project directory
        cmd.arg(project_dir);

        // Optional: extra bwrap args from config
        if config.disable_network {
            cmd.arg("--unshare-net");  // Override --share-net
        }

        // Spawn with stdin/stdout pipes
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;

        Ok(ContainerHandle {
            child,
            stdin: BufWriter::new(child.stdin.take().unwrap()),
            stdout: BufReader::new(child.stdout.take().unwrap()),
        })
    }
}
```

### Performance

**Startup time:**
- Bubblewrap: ~10ms overhead
- Python import orchestrator: ~100-200ms
- Total: ~200-300ms (acceptable)

**Comparison:**
- Podman container: ~1-2s (image loading, networking setup)
- VM: ~5-30s (boot time)

## Related Documents

- [Sandbox Overview](overview.md) - Design rationale and principles
- [Customization](customization.md) - How users add dependencies
- [Security Model](security.md) - Isolation boundaries and threat model
