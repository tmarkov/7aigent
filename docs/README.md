# 7aigent Documentation

Welcome to the 7aigent documentation. This guide will help you navigate the project's documentation.

## Quick Start

- **New to 7aigent?** Start with [Getting Started](getting-started.md)
- **Want to understand the architecture?** See [Architecture Overview](architecture.md)
- **Contributing code?** Check [Development Guide](development/contributing.md)

## Documentation Structure

### [Design Specifications](design/)

Complete design documents for all major components:
- [Agent](design/agent/) - The Rust binary that orchestrates LLM interactions
- [Orchestrator](design/orchestrator/) - Python tool execution environment
- [Sandbox](design/sandbox/) - Bubblewrap-based security isolation
- [Help System](design/help-system/) - Self-documenting capability discovery

### [Reference](reference/)

Technical reference documentation:
- [Environment Protocol](reference/environment-protocol.md) - Contract for implementing environments
- [Agent-Orchestrator Protocol](reference/agent-orchestrator-protocol.md) - Communication protocol
- [Configuration](reference/configuration.md) - All configuration options
- [Coding Style](reference/coding-style.md) - Code conventions and philosophy

### [Development](development/)

Guides for contributors:
- [Contributing](development/contributing.md) - How to contribute
- [Testing](development/testing.md) - Testing approach and guidelines
- [Technology Choices](development/technology.md) - Why Rust, Python, Nix
- [Build System](development/build-system.md) - Nix build details

### [Tasks](tasks/)

Active and historical task tracking:
- [Task Overview](tasks/README.md) - Master task checklist
- Individual task files track work from definition through completion

### [Analysis](analysis/)

Historical analysis and review documents:
- [Analysis Archive](analysis/README.md) - Design reviews and complexity analyses

## Finding What You Need

**I want to...**
- Understand what 7aigent does → [Getting Started](getting-started.md)
- See how components fit together → [Architecture Overview](architecture.md)
- Implement a new environment → [Environment Protocol](reference/environment-protocol.md)
- Customize the sandbox → [Sandbox Customization](design/sandbox/customization.md)
- Understand design decisions → Check relevant [Design](design/) subdirectory
- Contribute code → [Contributing Guide](development/contributing.md)
- See project status → [Tasks](tasks/README.md)

## Project Philosophy

This project is designed for LLM-driven development with:
- Strong static analysis and type safety
- "If it compiles, it works" mentality
- Comprehensive tooling (formatters, linters, tests)
- Explicit over implicit code
- Scenario-driven design

See [CLAUDE.md](../CLAUDE.md) for complete LLM collaboration guidelines.
