# General Conventions

This document defines project-wide conventions that apply across all languages and components.

## Version Control

### Commit Messages

Follow Conventional Commits format:

- `feat: add environment validation`
- `fix: handle EOF from orchestrator`
- `docs: update API documentation`
- `refactor: simplify command parsing`
- `test: add property-based tests for types`

### Branching

- Feature branches for new work
- Descriptive branch names: `feature/environment-validation`, `fix/llm-retry-logic`
- Keep branches focused and short-lived

## Code Review

When reviewing code, focus on:

1. **Correctness**: Does it do what it's supposed to?
2. **Clarity**: Is it easy to understand?
3. **Conventions**: Does it follow the language-specific guidelines?
4. **Type hints**: Are they complete (Python)?
5. **Error handling**: Is it explicit (Rust)?
6. **Documentation**: Are public APIs documented and tested?

## Related Files

- [Rust Conventions](./rust.md) - Rust-specific style guidelines
- [Python Conventions](./python.md) - Python-specific style guidelines
- [Documentation Conventions](./documentation.md) - How to write documentation
- [Testing](../testing.md) - Testing strategy and guidelines
