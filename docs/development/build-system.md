# Build System Guide

Understanding and using the Nix-based build system.

## Overview

This project uses [Nix](https://nixos.org/) for reproducible builds and automated verification. Every code change is verified through formatters, linters, and tests in a single command.

## Why Nix?

**Reproducibility and Automation**

Traditional development has several pain points:

1. "Works on my machine" - different tool versions produce different results
2. Forgotten steps - forget to run formatter before commit
3. Tool installation - complex setup for new contributors
4. CI/local divergence - tests pass locally but fail in CI

Nix solves these by:

- **Pinning exact versions**: Everyone uses the same tool versions
- **Hermetic builds**: Builds are isolated from system state
- **Integrated checks**: All verification in one command
- **Reproducible environments**: Same build everywhere

For this LLM-driven project, automation is critical. Nix ensures that if the build succeeds, all quality standards are met.

## Basic Usage

### Building Packages

<bash>
# Build the agent (Rust)
nix build .#agent

# Build the orchestrator (Python)
nix build .#orchestrator

# Build everything
nix flake check
</bash>

Each build runs:

**Agent (Rust)**:
1. `rustfmt --check` - Verify code is formatted
2. `clippy` - Run linter with strict settings
3. `cargo test` - Run all tests
4. `cargo build` - Build the binary

**Orchestrator (Python)**:
1. `black --check` - Verify code is formatted
2. `isort --check` - Verify imports are sorted
3. `ruff check` - Run fast linter
4. `pytest` - Run all tests
5. Package the Python module

### Development Shell

The development shell provides all tools needed for development:

<bash>
# Enter development shell
nix develop

# Shell provides:
# - Rust toolchain (rustc, cargo, rustfmt, clippy)
# - Python 3.11 with pip, pytest
# - Python tools (black, isort, ruff)
# - Build dependencies
# - Pre-commit hooks
</bash>

With direnv:

<bash>
# One-time setup
echo "use flake" > .envrc
direnv allow

# Shell activates automatically when entering directory
cd 7aigent  # Development environment loaded
</bash>

### Why Not Run Tools Directly?

**Critical: Always use `nix build`, not cargo/pytest directly.**

Running tools directly bypasses the build system:

<bash>
# DON'T DO THIS
cargo test        # Might pass locally
pytest           # But skip formatting checks
git commit       # Commit fails in CI

# DO THIS
nix build .#agent         # Runs ALL checks
nix build .#orchestrator  # Guaranteed correctness
</bash>

The build system ensures:
- No step is forgotten
- Same checks as CI
- Tools are correct versions
- Build is reproducible

## Understanding Nix Builds

### What Happens During a Build

<bash>
nix build .#agent
</bash>

1. **Dependency resolution**: Fetch exact versions of all dependencies
2. **Build environment**: Create isolated build environment with tools
3. **Format check**: Run `rustfmt --check` on all code
4. **Lint**: Run `clippy` with strict settings
5. **Test**: Run `cargo test` with all tests
6. **Build**: Compile the binary
7. **Store result**: Put binary in Nix store

If any step fails, the build fails. No partial results.

### Git Integration

**Nix builds only see git-tracked files.**

This is critical to understand:

<bash>
# Create new file
echo "print('hello')" > new_module.py

# Build won't see it yet
nix build .#orchestrator  # File doesn't exist in build

# Add to git
git add new_module.py

# Now build sees it
nix build .#orchestrator  # File exists in build
</bash>

This prevents common issues:
- Tests pass locally but fail in CI (untracked file)
- "Works on my machine" (local file not in git)
- Accidental dependencies on local state

**Always `git add` immediately after creating files.**

### Verifying New Code is in Build

When adding new modules, verify the build sees them:

<bash>
# Create test file that imports new module
cat > tests/test_new_module.py << 'EOF'
from package.new_module import NewClass  # Will fail - doesn't exist yet

def test_placeholder():
    assert True
EOF

# Add to git
git add tests/test_new_module.py

# Build should FAIL with ImportError
nix build .#orchestrator 2>&1 | grep "ModuleNotFoundError"

# If build succeeds, test not in build - investigate!
</bash>

See [Contributing Guide](contributing.md) for the full verification workflow.

## Common Build Issues

### Issue: Build Succeeds But File Not Tested

**Symptom**: Create test file, build succeeds, but test doesn't run.

**Cause**: Test file not added to git.

**Solution**:

<bash>
git add tests/test_new_module.py
nix build .#orchestrator
</bash>

### Issue: Build Fails with Import Error

**Symptom**: Build fails with "ModuleNotFoundError" or "cannot find module".

**Cause**: New module created but not added to git.

**Solution**:

<bash>
git add package/new_module.py
nix build .#orchestrator
</bash>

### Issue: Format Check Fails

**Symptom**: Build fails with "file not formatted" or "imports not sorted".

**Solution**: Run formatters in development shell:

<bash>
nix develop

# Python
black orchestrator/
isort orchestrator/

# Rust
cargo fmt

# Verify
nix build .#orchestrator
nix build .#agent
</bash>

### Issue: Tests Pass Locally, Fail in Build

**Symptom**: `pytest` passes but `nix build .#orchestrator` fails.

**Cause**: Using wrong Python version or missing dependencies.

**Solution**: Always use `nix build` for verification, not direct tool invocation.

## Build Configuration

### Flake Structure

```
flake.nix           # Main build configuration
├── packages
│   ├── agent       # Rust package build
│   └── orchestrator # Python package build
├── devShells
│   └── default     # Development shell
└── checks
    └── all checks  # All verification tests
```

### Adding Dependencies

**Python dependencies** (orchestrator):

Edit `orchestrator/pyproject.toml`:

```toml
[project]
dependencies = [
    "pexpect >= 4.8",
    "hypothesis >= 6.0",
]
```

**Rust dependencies** (agent):

Edit `agent/Cargo.toml`:

```toml
[dependencies]
serde = { version = "1.0", features = ["derive"] }
tokio = { version = "1.0", features = ["full"] }
```

Then rebuild:

<bash>
nix build .#agent         # Fetches new dependencies
nix build .#orchestrator  # Fetches new dependencies
</bash>

## Development Workflow

### Recommended Workflow

<bash>
# 1. Enter development shell
nix develop

# 2. Make changes
vim orchestrator/environments/bash.py

# 3. Git add immediately for new files
git add orchestrator/environments/bash.py

# 4. Build frequently to catch issues early
nix build .#orchestrator

# 5. Iterate on failures
# - Fix format issues
# - Fix lint warnings
# - Fix test failures

# 6. Final verification
nix build .#orchestrator
nix build .#agent
nix flake check
</bash>

### Build Frequency

Build after every significant change:

- Created new file
- Modified function signature
- Changed behavior
- Added test

Don't wait until "done" to build. Catching issues early saves time.

## Advanced Usage

### Checking Specific Derivations

<bash>
# List all checks
nix flake show

# Run specific check
nix build .#checks.x86_64-linux.agent-tests
nix build .#checks.x86_64-linux.orchestrator-tests
</bash>

### Clean Builds

Nix builds are pure, but you can force rebuild:

<bash>
# Clear result symlink
rm -f result

# Rebuild
nix build .#agent --rebuild
</bash>

### Debugging Build Failures

<bash>
# Verbose output
nix build .#agent -L

# Keep build directory on failure
nix build .#agent --keep-failed

# Interactive debugging
nix develop .#agent
cargo test  # Run tests in dev shell
</bash>

## Success Criteria

You're using the build system correctly if:

- You run `nix build` after every change
- You never run cargo/pytest directly for verification
- You `git add` files immediately after creation
- You verify new code is in the build
- All checks pass before committing
- You understand why builds fail

## Further Reading

- [CLAUDE.md](../../CLAUDE.md) - Full development workflow
- [Contributing Guide](contributing.md) - Development practices
- [Testing Guide](testing.md) - Writing and running tests
- [Nix Manual](https://nixos.org/manual/nix/stable/) - Official documentation
