# Reference Documentation

Technical reference material for implementing and integrating with 7aigent.

## Protocols and Contracts

- [Environment Protocol](environment-protocol.md) - Contract for implementing custom environments
- [Agent-Orchestrator Protocol](agent-orchestrator-protocol.md) - JSON communication protocol

## Configuration

- [Configuration Reference](configuration.md) - All configuration options and formats

## Development Standards

- [Coding Style](coding-style.md) - Code conventions, philosophy, and guidelines

## Using This Reference

### Implementing a Custom Environment

1. Read [Environment Protocol](environment-protocol.md) to understand the contract
2. Look at existing environments in the orchestrator codebase for examples
3. Follow [Coding Style](coding-style.md) conventions
4. See [Orchestrator Design](../design/orchestrator/) for architecture context

### Understanding Communication

The [Agent-Orchestrator Protocol](agent-orchestrator-protocol.md) documents the JSON message format for communication between agent and orchestrator. This is useful for:
- Debugging issues
- Understanding error responses
- Implementing alternative agents or orchestrators

### Configuring the Agent

See [Configuration Reference](configuration.md) for all available options including:
- LLM provider settings (API keys, models, endpoints)
- Sandbox customization (shell_prefix)
- Cost limits and budgets
- Session management
