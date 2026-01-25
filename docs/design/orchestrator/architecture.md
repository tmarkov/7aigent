# Orchestrator Architecture

The orchestrator is the main process inside the container. It manages environments, routes commands, and communicates with the agent.

## Components

### Main Loop

The orchestrator runs a simple request-response loop:

<python>
def main():
    """Main orchestrator entry point."""
    # Load environments
    environments = load_all_environments(project_dir)

    # Main interaction loop
    while True:
        # Read command from agent (stdin)
        message = read_message()
        if message is None:  # EOF
            break

        # Execute command
        response = execute_command(parse_command(message), environments)

        # Collect screen updates
        screen = collect_screen_updates(environments)

        # Send response back to agent (stdout)
        send_response(response, screen)

    # Cleanup
    shutdown_all_environments(environments)
</python>

### Environment Loading

The orchestrator loads both built-in and custom environments:

<python>
def load_all_environments(project_dir: Path) -> dict[str, Environment]:
    """Load built-in and ad-hoc environments."""
    environments = {}

    # Built-in environments
    environments['bash'] = BashEnvironment()
    environments['python'] = PythonEnvironment()
    environments['editor'] = EditorEnvironment(project_dir)

    # Custom environments from project_dir/env/*.py
    env_dir = project_dir / 'env'
    if env_dir.exists():
        for module_path in env_dir.glob('*.py'):
            name = module_path.stem
            if name.startswith('_'):
                continue

            # Load, validate, and instantiate
            env_class = load_and_validate_environment(module_path)
            if env_class:
                environments[name] = env_class()

    return environments
</python>

See [Environment Contract](../../reference/environment-protocol.md) for validation details.

### Command Execution

Commands are routed to the appropriate environment:

<python>
def execute_command(
    cmd: OrchestratorCommand,
    environments: dict[str, Environment]
) -> CommandResponse:
    """Execute command in specified environment."""
    # Validate environment exists
    if cmd.environment not in environments:
        available = ', '.join(sorted(environments.keys()))
        return CommandResponse(
            output=f"Unknown environment: {cmd.environment}\nAvailable: {available}",
            success=False
        )

    # Execute
    try:
        env = environments[cmd.environment]
        return env.handle_command(cmd.command)
    except Exception as e:
        # Graceful error handling
        return CommandResponse(
            output=f"Environment error: {traceback.format_exc()}",
            success=False
        )
</python>

### Screen Collection

The "screen" shows current state of all environments:

<python>
def collect_screen_updates(environments: dict[str, Environment]) -> dict[str, ScreenSection]:
    """Collect screen updates from all environments."""
    screen = {}

    for name, env in environments.items():
        try:
            screen[name] = env.render_screen()
        except Exception as e:
            # Don't crash if screen rendering fails
            screen[name] = ScreenSection(
                content=f"Error rendering screen: {e}",
                max_lines=5
            )

    return screen
</python>

## Module Structure

```
orchestrator/
├── main.py                  # Entry point, main loop
├── types.py                 # Semantic types (EnvironmentName, CommandText, etc.)
├── protocol.py              # JSON protocol parsing/serialization
├── environments/
│   ├── __init__.py         # Environment base class
│   ├── bash.py             # Bash environment
│   ├── python.py           # Python REPL environment
│   ├── editor.py           # File viewer/editor environment
│   └── declarative.py      # DeclarativeEnvironment base class
└── tests/
    ├── test_bash.py
    ├── test_python.py
    └── test_editor.py
```

## Data Flow

```
Agent (via stdin)
    │
    ├─> JSON command: {"environment": "bash", "command": "ls"}
    │
    ▼
Orchestrator main loop
    │
    ├─> Parse command
    ├─> Route to environment
    ├─> Execute in environment
    ├─> Collect screen updates
    │
    ▼
Agent (via stdout)
    │
    └─> JSON response: {
          "response": {"output": "file1.txt\nfile2.txt", "success": true},
          "screen": {"bash": {...}, "python": {...}}
        }
```

## Error Handling

Orchestrator uses graceful error handling throughout:

1. **Unknown environment**: Return error response with list of available environments
2. **Environment exception**: Catch, format traceback, return as error response
3. **Screen rendering failure**: Show error in that screen section, don't crash
4. **Protocol error**: Send error response, continue loop

**Key principle**: Errors inform the LLM, they don't terminate execution.

## Related Documents

- [Overview](overview.md) - Purpose and responsibilities
- [Environments](environments.md) - Environment contract
- [Environment Protocol](../../reference/environment-protocol.md) - Implementation details
- [Agent-Orchestrator Protocol](../../reference/agent-orchestrator-protocol.md) - Communication protocol
