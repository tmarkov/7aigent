# Development Guide

Resources for contributors to the 7aigent project.

## Getting Started

- [Contributing Guide](contributing.md) - How to contribute, development workflow
- [Testing Guide](testing.md) - Testing approach, running tests, writing tests
- [Build System](build-system.md) - Understanding and using Nix builds
- [Technology Choices](technology.md) - Why Rust, Python, and Nix

## Quick Reference

### Development Environment

<bash>
# Enter development shell (has all tools)
nix develop

# Or use direnv for automatic activation
direnv allow
</bash>

### Building and Testing

<bash>
# Build agent (runs rustfmt, clippy, cargo test)
nix build .#agent

# Build orchestrator (runs black, isort, ruff, pytest)
nix build .#orchestrator

# Run all checks
nix flake check
</bash>

### Pre-commit Hooks

<bash>
# Install hooks (formatters and linters)
pre-commit install

# Run manually
pre-commit run --all-files
</bash>

## Project Philosophy

This project is designed for LLM-driven development:

1. **Strong static analysis**: Types catch errors, not code review
2. **"If it compiles, it works"**: Use type systems to prevent bugs
3. **Comprehensive tooling**: Automated formatters and linters
4. **Explicit over implicit**: Code should be obvious
5. **Test thoroughly**: Property-based testing where applicable

See [CLAUDE.md](../../CLAUDE.md) for complete LLM collaboration guidelines.

## Development Workflow

1. **Check tasks**: See [docs/tasks/](../tasks/) for current work
2. **Create task file**: Define problem and scenarios
3. **Design**: Follow scenario-driven design workflow
4. **Implement**: Write code, tests, docs together
5. **Verify**: `nix build` must pass all checks
6. **Submit**: Create PR with description

## Key Principles

### Type Safety First

Use semantic types, not primitives:
- ❌ `session_id: str`
- ✅ `session_id: SessionId` (newtype with validation)

### Graceful Error Handling

Errors should inform, not crash:
- Return error responses that LLM can understand
- Include context and suggestions for recovery
- Don't terminate on recoverable errors

### Test Coverage

- Unit tests for all public APIs
- Property-based tests for complex logic
- Integration tests for component interaction
- All tests must pass in `nix build`

## Documentation Standards

- Design docs in `docs/design/`
- Reference docs in `docs/reference/`
- Keep files focused and under 150 lines
- Use concrete examples, not abstract descriptions
- Link liberally to related docs

See [Contributing Guide](contributing.md) for detailed guidelines.
