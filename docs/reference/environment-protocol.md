# Environment Protocol Reference

This document specifies the contract that all environments (built-in and custom) must implement.

## Type Definitions

<python>
from dataclasses import dataclass
from typing import Protocol

@dataclass(frozen=True)
class EnvironmentName:
    """Name of an environment (must be valid Python identifier)."""
    value: str

    def __post_init__(self):
        if not self.value.isidentifier():
            raise ValueError(f"Invalid environment name: {self.value}")

@dataclass(frozen=True)
class CommandText:
    """The text content of a command to execute."""
    value: str

@dataclass(frozen=True)
class CommandResponse:
    """Response from executing a command."""
    output: str
    success: bool

@dataclass(frozen=True)
class ScreenSection:
    """Content to display in this environment's screen section."""
    content: str
    max_lines: int = 50
</python>

## Environment Protocol

<python>
from typing import Protocol

class Environment(Protocol):
    """
    Protocol that all environment modules must implement.

    Environments are stateful and handle commands within their domain
    (bash, python, editor, etc.). They maintain state across commands
    and provide a screen section showing current state.
    """

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        """
        Execute a command in this environment.

        This is the main entry point for command execution. The environment
        should parse the command, execute it, update internal state, and
        return a response.

        Args:
            cmd: The command to execute

        Returns:
            Response containing output and success status

        Notes:
            - This method MUST be synchronous (blocking)
            - Timeouts are the environment's responsibility
            - Long-running commands will block the interaction loop
            - Exceptions should be caught and returned as failed response
        """
        ...

    def get_screen(self) -> ScreenSection:
        """
        Get current screen content for this environment.

        This is called after every command (from any environment) to update
        the screen. Should return quickly with current state.

        Returns:
            Screen section showing current environment state

        Notes:
            - Called frequently, must be fast (no expensive computation)
            - Content will be truncated if exceeds max_lines
            - Should show the most relevant state information
        """
        ...

    def shutdown(self) -> None:
        """
        Clean up resources before environment is stopped.

        Called when orchestrator is shutting down. Use this to:
        - Kill child processes
        - Close file handles
        - Save state if needed

        This method is OPTIONAL to implement.
        """
        ...
</python>

## Environment Loading

### Built-in Environments

Loaded from `orchestrator/environments/` package:
- `bash.py` exports `BashEnvironment` class
- `python.py` exports `PythonEnvironment` class
- `editor/` package exports `EditorEnvironment` class (query-based pipeline system, v2 redesign March 2026)

### Custom Environments

Loaded from `{project_dir}/env/*.py`:
- Each `.py` file is a module
- Module name (stem) becomes environment name
- Module must export a class implementing the Environment protocol
- Class name conventionally matches module name (e.g., `timer.py` exports `TimerEnvironment`)

## Validation

### Finding Environment Class

<python>
import inspect
from typing import Any

def find_environment_class(module: Any) -> type | None:
    """
    Find the environment class in a module.

    Looks for a class that implements the Environment protocol.
    By convention, class name should match module name (e.g., TimerEnvironment in timer.py).

    Returns:
        The environment class, or None if not found
    """
    # Look for classes that have handle_command and get_screen methods
    for name in dir(module):
        obj = getattr(module, name)
        if inspect.isclass(obj) and hasattr(obj, 'handle_command') and hasattr(obj, 'get_screen'):
            return obj
    return None
</python>

### Validation Rules

The environment class must satisfy these requirements:

**handle_command method:**
- Must take exactly 2 parameters: `self` and `cmd`
- `cmd` parameter must have type annotation `CommandText`
- Must have return type annotation `CommandResponse`

**get_screen method:**
- Must take only `self` parameter
- Must have return type annotation `ScreenSection`

**shutdown method (optional):**
- Must take only `self` parameter
- Must return `None` or have no return annotation

### Validation Implementation

<python>
def validate_environment_class(cls: type) -> list[str]:
    """
    Validate that a class implements the Environment protocol.

    Args:
        cls: The class to validate

    Returns:
        List of validation error messages (empty list if valid)
    """
    errors = []

    # Check handle_command
    if not hasattr(cls, 'handle_command'):
        errors.append("Missing required method: handle_command")
    else:
        sig = inspect.signature(cls.handle_command)
        params = list(sig.parameters.values())

        if len(params) != 2:
            errors.append("handle_command must take exactly 2 parameters (self, cmd)")
        elif len(params) == 2:
            param = params[1]
            if param.annotation == inspect.Parameter.empty:
                errors.append("handle_command cmd parameter must have type annotation")
            elif param.annotation != CommandText:
                errors.append(f"handle_command cmd must be CommandText, got {param.annotation}")

        if sig.return_annotation == inspect.Signature.empty:
            errors.append("handle_command must have return type annotation")
        elif sig.return_annotation != CommandResponse:
            errors.append(f"handle_command must return CommandResponse, got {sig.return_annotation}")

    # Check get_screen
    if not hasattr(cls, 'get_screen'):
        errors.append("Missing required method: get_screen")
    else:
        sig = inspect.signature(cls.get_screen)
        params = list(sig.parameters.values())

        if len(params) != 1:
            errors.append("get_screen must take only self parameter")

        if sig.return_annotation == inspect.Signature.empty:
            errors.append("get_screen must have return type annotation")
        elif sig.return_annotation != ScreenSection:
            errors.append(f"get_screen must return ScreenSection, got {sig.return_annotation}")

    # Check shutdown (optional)
    if hasattr(cls, 'shutdown'):
        sig = inspect.signature(cls.shutdown)
        params = list(sig.parameters.values())

        if len(params) != 1:
            errors.append("shutdown must take only self parameter")
        if sig.return_annotation not in (inspect.Signature.empty, None):
            errors.append("shutdown must return None")

    return errors
</python>

## Error Handling

When an environment fails validation:
1. Log errors to stderr with module name and specific issues
2. Do NOT load the environment (exclude from available environments)
3. Continue loading other environments

## Example: Simple Timer Environment

<python>
# project_dir/env/timer.py

from orchestrator.core_types import CommandText, CommandResponse, ScreenSection
import time

class TimerEnvironment:
    """Simple timer environment for tracking elapsed time."""

    def __init__(self):
        self._start_time = None
        self._elapsed = 0.0

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        command = cmd.value.strip()

        if command == "start":
            self._start_time = time.time()
            return CommandResponse("Timer started", success=True)
        elif command == "stop":
            if self._start_time is None:
                return CommandResponse("Timer not running", success=False)
            self._elapsed = time.time() - self._start_time
            self._start_time = None
            return CommandResponse(f"Elapsed: {self._elapsed:.2f}s", success=True)
        elif command == "reset":
            self._start_time = None
            self._elapsed = 0.0
            return CommandResponse("Timer reset", success=True)
        else:
            return CommandResponse(f"Unknown command: {command}", success=False)

    def get_screen(self) -> ScreenSection:
        if self._start_time is not None:
            current_elapsed = time.time() - self._start_time
            status = f"Running: {current_elapsed:.2f}s"
        else:
            status = f"Stopped: {self._elapsed:.2f}s"

        return ScreenSection(content=f"Timer: {status}")

    def shutdown(self) -> None:
        pass
</python>

## See Also

- [Agent-Orchestrator Protocol](agent-orchestrator-protocol.md) - JSON message formats between agent and orchestrator
- [Configuration Reference](configuration.md) - Agent configuration options
