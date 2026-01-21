# Contributing Guide

A practical guide for contributing to the 7aigent project.

## Getting Started

### Prerequisites

- [Nix package manager](https://nixos.org/download.html) with flakes enabled
- Git for version control
- Familiarity with Rust or Python (depending on component)

### Initial Setup

```bash
# Clone the repository
git clone https://github.com/yourusername/7aigent.git
cd 7aigent

# Enter development shell (provides all tools)
nix develop

# Optional: Use direnv for automatic shell activation
echo "use flake" > .envrc
direnv allow
```

The development shell provides:
- Rust toolchain (rustc, cargo, rustfmt, clippy)
- Python 3.13 with development tools (black, isort, ruff, pytest)
- Build tools and dependencies
- Pre-commit hooks setup

### Pre-commit Hooks

Install pre-commit hooks to run formatters and linters automatically:

```bash
pre-commit install

# Run manually on all files
pre-commit run --all-files
```

Hooks run:
- **Python**: black, isort, ruff
- **Rust**: rustfmt, clippy
- Trailing whitespace cleanup
- File size checks

## Development Workflow

### 1. Check Current Work

Browse [docs/tasks/](../tasks/) to see active and planned work:

```bash
# View task index
cat docs/tasks/README.md

# Review a specific task
cat docs/tasks/implement-bash-environment.md
```

### 2. Define New Tasks

When proposing new work, create a task file:

```bash
# Create task file
vim docs/tasks/fix-memory-leak.md
```

Task structure:
1. **Problem**: 2-3 sentences describing what's wrong or missing
2. **Context**: Affected components, related docs, constraints
3. **Scenarios**: 3-5 concrete situations that must work (WHAT, not HOW)
4. **Initial thoughts**: Optional observations

Stop here. Don't design yet. See [CLAUDE.md](../../CLAUDE.md) for the full task lifecycle.

### 3. Design Phase

Follow the [scenario-driven design workflow](../../CLAUDE.md#scenario-driven-design-workflow):

1. Identify components and read related docs
2. Review scenarios from task file
3. Design to satisfy scenarios
4. Mentally trace implementation of critical paths
5. Simplify and prune unnecessary features
6. Review design against scenarios
7. Iterate until design is grade A or B
8. Document design with rationale

Create design documents in `docs/design/` with concrete examples and trade-off explanations.

### 4. Implementation Phase

Follow these steps strictly to avoid build issues:

```bash
# 1. Always use nix build, not cargo/pytest directly
nix build .#agent      # For Rust changes
nix build .#orchestrator  # For Python changes

# 2. After creating ANY new file, immediately:
git add path/to/new/file.py

# 3. Build after EVERY change to catch issues early
nix build .#orchestrator
```

See [Testing Guide](testing.md) for test requirements and [Build System](build-system.md) for details on how Nix builds work.

### 5. Verification

Before submitting:

```bash
# Clean build with all checks
nix build .#agent        # Runs rustfmt, clippy, cargo test
nix build .#orchestrator # Runs black, isort, ruff, pytest

# Run full flake checks
nix flake check
```

All checks must pass:
- Code formatting (rustfmt, black, isort)
- Linting (clippy, ruff)
- All tests passing
- Type hints complete (Python)
- Documentation present

### 6. Submit Changes

Create a pull request with:

1. **Clear title**: Follow [Conventional Commits](https://www.conventionalcommits.org/)
   - `feat: add environment validation`
   - `fix: handle EOF from orchestrator`
   - `docs: update contributing guide`

2. **Description**:
   - What problem does this solve?
   - What scenarios does this address?
   - What trade-offs were made?
   - Link to task file and design doc

3. **Tests**: All new code must have tests

4. **Documentation**: Update docs if behavior changed

## Code Standards

Follow [Coding Style Guide](../reference/coding-style.md) strictly:

- **Python**: Complete type hints, semantic types, immutable by default
- **Rust**: Compile-time guarantees, explicit error handling, doc comments
- **Both**: Property-based tests for public APIs, explicit over implicit

Key principles:

```python
# Python: Use semantic types, not primitives
@dataclass(frozen=True)
class EnvironmentName:
    value: str

# Rust: Make invalid states unrepresentable
pub struct ValidatedConfig {
    api_key: String,
}
```

## Documentation Standards

- Design docs go in `docs/design/`
- Reference docs go in `docs/reference/`
- Keep files focused and under 150 lines
- Use concrete examples, not abstract descriptions
- Explain WHY decisions were made, not just WHAT was done
- Link liberally to related documents

## Common Pitfalls

1. **Not using nix build**: Running cargo/pytest directly bypasses formatters and linters
2. **Forgetting git add**: Nix builds only see tracked files
3. **Building too infrequently**: Catch issues early by building after each change
4. **Skipping scenarios**: Always define concrete scenarios before designing
5. **Over-engineering**: Prefer simple solutions that solve 80% of cases

## Getting Help

- Read [CLAUDE.md](../../CLAUDE.md) for complete LLM collaboration guidelines
- Review [scenario-driven design workflow](../../CLAUDE.md#scenario-driven-design-workflow)
- Check existing docs in `docs/` for patterns and examples
- Ask questions in issues or pull requests

## Success Criteria

You're doing well if:

- Code compiles/type-checks on first try
- `nix build` succeeds with all checks
- Tests are comprehensive and use property-based testing
- Documentation is clear with concrete examples
- You followed the coding style guide
- Design was accurate (no surprises during implementation)
