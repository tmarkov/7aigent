# Environment Contract

All environments (built-in and ad-hoc) must implement this protocol.

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

## Environment Loading and Validation

**Loading process**:

1. **Built-in environments**: Loaded from `orchestrator/environments/` package
   - `bash.py` exports `BashEnvironment` class
   - `python.py` exports `PythonEnvironment` class
   - `editor.py` exports `EditorEnvironment` class

2. **Ad-hoc environments**: Loaded from `{project_dir}/env/*.py`
   - Each `.py` file is a module
   - Module name (stem) becomes environment name
   - Module must export a class implementing the Environment protocol
   - Class name conventionally matches module name (e.g., `timer.py` exports `TimerEnvironment`)

**Validation implementation**:

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

def validate_environment_class(cls: type) -> list[str]:
    """
    Validate that a class implements the Environment protocol.

    Uses runtime introspection to check:
    - Required methods exist
    - Method signatures match protocol
    - Type annotations are correct

    Args:
        cls: The class to validate

    Returns:
        List of validation error messages (empty list if valid)
    """
    errors = []

    # Check handle_command exists
    if not hasattr(cls, 'handle_command'):
        errors.append("Missing required method: handle_command")
    else:
        sig = inspect.signature(cls.handle_command)
        params = list(sig.parameters.values())

        # Should be (self, cmd)
        if len(params) != 2:
            errors.append("handle_command must take exactly 2 parameters (self, cmd)")
        elif len(params) == 2:
            param = params[1]  # Skip self
            if param.annotation == inspect.Parameter.empty:
                errors.append("handle_command cmd parameter must have type annotation")
            elif param.annotation != CommandText:
                errors.append(f"handle_command cmd must be CommandText, got {param.annotation}")

        if sig.return_annotation == inspect.Signature.empty:
            errors.append("handle_command must have return type annotation")
        elif sig.return_annotation != CommandResponse:
            errors.append(f"handle_command must return CommandResponse, got {sig.return_annotation}")

    # Check get_screen exists
    if not hasattr(cls, 'get_screen'):
        errors.append("Missing required method: get_screen")
    else:
        sig = inspect.signature(cls.get_screen)
        params = list(sig.parameters.values())

        # Should be (self,)
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

**Error handling for failed validation**:

When an ad-hoc environment fails validation:
1. Log errors to stderr with module name and specific issues
2. Do NOT load the environment (exclude from available environments)
3. Continue loading other environments
4. Optionally: Display validation errors on screen in special section

## Related Documents

- [Orchestrator Overview](overview.md)
- [Bash Environment Design](bash-environment.md)
- [Python Environment Design](python-environment.md)
- [Editor Environment Design](editor-environment.md)
