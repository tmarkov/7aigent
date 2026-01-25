# Declarative Environments

This document describes the `DeclarativeEnvironment` base class for creating structured command environments with automatic help generation.

## Purpose

The `DeclarativeEnvironment` base class provides:
- Automatic command discovery via `@command` decorator
- Per-command usage tracking
- Progressive help generation (detailed help for unused commands, compact help for used commands)
- Command routing and error handling

## When to Use

Use `DeclarativeEnvironment` when:
- Your environment has a specific set of commands (not freeform like bash/python)
- You want automatic progressive disclosure
- Commands can be described with signature, description, and example

Don't use when:
- Environment accepts arbitrary input (use freeform pattern like Bash/Python)
- You need full control over help rendering (implement Environment protocol directly)

## Command Decorator

<python>
def command(signature: str, description: str, example: str):
    """
    Decorator for declarative environment commands.

    Args:
        signature: Command signature (e.g., "view <file> /<start>/ /<end>/ [label]")
        description: Multi-line detailed description
        example: Raw command invocation (will be wrapped in markdown fence)

    Example usage:
        @command(
            signature="edit <file> <start>-<end>",
            description="Replace lines with new content.\nContent on subsequent lines.",
            example="edit src/main.py 45-50\n    new code here"
        )
        def edit(self, filepath: str, line_range: str, content: str):
            ...
    """
    def decorator(func):
        func._command_metadata = {
            'signature': signature,
            'description': description,
            'example': example,
        }
        return func
    return decorator
</python>

## Base Class API

<python>
class DeclarativeEnvironment:
    """
    Base class for environments with structured command sets.

    Provides automatic:
    - Command discovery via @command decorator
    - Per-command usage tracking
    - Progressive help generation
    - Command routing
    """

    def __init__(self):
        self._command_usage = set()  # Track which commands have been used
        self._commands = self._discover_commands()

    def _discover_commands(self) -> dict[str, tuple[callable, dict]]:
        """Find all @command decorated methods."""
        commands = {}
        for name in dir(self):
            attr = getattr(self, name)
            if hasattr(attr, '_command_metadata'):
                # Extract command name from signature (first word)
                sig = attr._command_metadata['signature']
                cmd_name = sig.split()[0]
                commands[cmd_name] = (attr, attr._command_metadata)
        return commands

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        """Route command to appropriate method and track usage."""
        # Parse command name
        cmd_name = cmd.value.strip().split()[0] if cmd.value.strip() else ""

        if cmd_name not in self._commands:
            available = ', '.join(sorted(self._commands.keys()))
            return CommandResponse(
                output=f"Unknown command: {cmd_name}\nAvailable: {available}",
                success=False
            )

        # Mark as used
        self._command_usage.add(cmd_name)

        # Route to method
        method, metadata = self._commands[cmd_name]
        try:
            result = self._execute_command(method, cmd.value)
            return CommandResponse(output=result, success=True)
        except Exception as e:
            return CommandResponse(output=f"Error: {e}", success=False)

    def _execute_command(self, method: callable, cmd_text: str) -> str:
        """
        Parse command and execute method. Override for custom parsing.
        Default: pass entire command text to method.
        """
        return method(cmd_text)

    def get_screen(self) -> ScreenSection:
        """Generate screen with state + progressive help."""
        # Get state from subclass
        if hasattr(self, 'get_state_display'):
            state = self.get_state_display()
        else:
            state = self.__class__.__doc__ or "Environment ready"

        # Build command help (progressive disclosure)
        commands_help = []
        for cmd_name in sorted(self._commands.keys()):
            method, metadata = self._commands[cmd_name]
            sig = metadata['signature']
            desc = metadata['description']
            example = metadata['example']

            if cmd_name in self._command_usage:
                # SHORT help: signature - one-line description
                short_desc = desc.split('\n')[0]  # First line only
                commands_help.append(f"  {sig} - {short_desc}")
            else:
                # LONG help: signature, description, example
                env_name = self.__class__.__name__.replace('Environment', '').lower()
                example_formatted = f"    
</python>{env_name}\n"
                for line in example.split('\n'):
                    example_formatted += f"    {line}\n"
                example_formatted += "    ```"

                commands_help.append(
                    f"  {sig}\n"
                    f"    {desc.replace('\n', '\n    ')}\n"
                    f"    Example:\n{example_formatted}"
                )

        content = state + "\n\nCommands:\n" + "\n\n".join(commands_help)
        return ScreenSection(content=content, max_lines=100)

    def get_state_display(self) -> str:
        """
        Override in subclass to provide custom state display.

        Returns:
            String describing current environment state
        """
        raise NotImplementedError("Subclass should implement get_state_display()")
```

## Example: Timer Environment

<python>
from orchestrator.declarative import DeclarativeEnvironment, command
import time

class TimerEnvironment(DeclarativeEnvironment):
    """Timer for tracking elapsed time"""

    def __init__(self):
        super().__init__()
        self._start_time = None
        self._elapsed = 0.0

    @command(
        signature="start",
        description="Start the timer from zero or resume after stop.",
        example="start"
    )
    def start(self):
        self._start_time = time.time()
        return "Timer started"

    @command(
        signature="stop",
        description="Stop the timer and record elapsed time.",
        example="stop"
    )
    def stop(self):
        if not self._start_time:
            raise ValueError("Timer not running")
        self._elapsed = time.time() - self._start_time
        self._start_time = None
        return f"Elapsed: {self._elapsed:.2f}s"

    @command(
        signature="reset",
        description="Reset timer to zero.",
        example="reset"
    )
    def reset(self):
        self._start_time = None
        self._elapsed = 0.0
        return "Timer reset"

    def get_state_display(self) -> str:
        """Custom state display."""
        if self._start_time:
            current = time.time() - self._start_time
            return f"Timer: Running ({current:.2f}s)"
        return f"Timer: Stopped ({self._elapsed:.2f}s)"
</python>

### Screen Output Before Any Commands

```
Timer: Stopped (0.00s)

Commands:
  start
    Start the timer from zero or resume after stop.
    Example:
      ```timer
      start
      ```

  stop
    Stop the timer and record elapsed time.
    Example:
      ```timer
      stop
      ```

  reset
    Reset timer to zero.
    Example:
      ```timer
      reset
      ```
```

### Screen Output After Using `start`

```
Timer: Running (5.23s)

Commands:
  start - Start the timer from zero or resume after stop

  stop
    Stop the timer and record elapsed time.
    Example:
      ```timer
      stop
      ```

  reset
    Reset timer to zero.
    Example:
      ```timer
      reset
      ```
```

## Implementation Notes

- The `@command` decorator metadata drives help generation
- Base class automatically wraps examples in markdown code fences with environment name
- Authors only provide raw command text in examples
- Per-command usage tracking is automatic
- Framework extracts environment name from class name (removes "Environment" suffix)

## Protocol Compliance

`DeclarativeEnvironment` implements the standard `Environment` protocol:

<python>
class Environment(Protocol):
    def handle_command(self, cmd: CommandText) -> CommandResponse: ...
    def get_screen(self) -> ScreenSection: ...
    def shutdown(self) -> None: ...  # Optional
</python>

All orchestrator features work with `DeclarativeEnvironment` subclasses automatically.

## Related Documents

- [Help System Overview](overview.md) - Overall design and principles
- [Progressive Disclosure](progressive-disclosure.md) - How per-command tracking works
- [Orchestrator Architecture](../orchestrator/) - Environment protocol details
