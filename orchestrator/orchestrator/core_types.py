"""Core type definitions for the orchestrator."""

from dataclasses import dataclass


@dataclass(frozen=True)
class EnvironmentName:
    """
    Name of an environment (must be valid Python identifier).

    Environment names are used to identify and route commands to specific
    environments. They must be valid Python identifiers to ensure they can be
    used safely in code generation, module imports, and dictionaries.

    Examples:
        >>> EnvironmentName("bash")
        EnvironmentName(value='bash')
        >>> EnvironmentName("python")
        EnvironmentName(value='python')
        >>> EnvironmentName("my_custom_env")
        EnvironmentName(value='my_custom_env')

    Invalid examples:
        >>> EnvironmentName("my-env")  # Hyphens not allowed
        Traceback (most recent call last):
            ...
        ValueError: Invalid environment name: 'my-env' (must be valid Python identifier)
        >>> EnvironmentName("123env")  # Cannot start with digit
        Traceback (most recent call last):
            ...
        ValueError: Invalid environment name: '123env' (must be valid Python identifier)
    """

    value: str

    def __post_init__(self) -> None:
        """Validate that the environment name is a valid Python identifier."""
        if not self.value.isidentifier():
            raise ValueError(
                f"Invalid environment name: {self.value!r} "
                "(must be valid Python identifier)"
            )


@dataclass(frozen=True)
class CommandText:
    """
    The text content of a command to execute.

    Commands are arbitrary strings sent to environments. The environment is
    responsible for parsing and executing the command according to its own
    syntax and semantics.

    Examples:
        >>> CommandText("ls -la")
        CommandText(value='ls -la')
        >>> CommandText("print('hello')")
        CommandText(value="print('hello')")
        >>> CommandText("")  # Empty commands are valid
        CommandText(value='')
    """

    value: str


@dataclass(frozen=True)
class CommandResponse:
    """
    Response from executing a command.

    Contains the output produced by the command and a success flag indicating
    whether the command completed successfully. Environments define their own
    semantics for success/failure.

    Attributes:
        output: Text output from command execution (stdout, stderr, results, etc.)
        success: Whether the command succeeded (environment-specific definition)

    Examples:
        >>> CommandResponse("total 48\\ndrwxr-xr-x...", True)
        CommandResponse(output='total 48\\ndrwxr-xr-x...', success=True)
        >>> CommandResponse("Error: file not found", False)
        CommandResponse(output='Error: file not found', success=False)
    """

    output: str
    success: bool


@dataclass(frozen=True)
class ScreenSection:
    """
    Content to display in an environment's screen section.

    Each environment provides a screen section showing its current state. The
    orchestrator collects these sections and presents them to the agent after
    every command.

    The content will be truncated if it exceeds max_lines. Environments should
    return the most relevant state information within this limit.

    Attributes:
        content: Text content to display (may contain newlines)
        max_lines: Maximum number of lines to display (default: 50)

    Examples:
        >>> ScreenSection("Working directory: /home/user\\nLast exit code: 0")
        ScreenSection(content='Working directory: /home/user\\nLast exit code: 0', max_lines=50)
        >>> ScreenSection("Python REPL (ready)", max_lines=10)
        ScreenSection(content='Python REPL (ready)', max_lines=10)

    Notes:
        - Environments should show minimal content before first use to avoid
          cluttering the screen with information about unused environments
        - Content should be concise and focused on current state
        - Large outputs should be written to files, not displayed on screen
    """

    content: str
    max_lines: int = 50

    def __post_init__(self) -> None:
        """Validate that max_lines is positive."""
        # Use object.__setattr__ since dataclass is frozen
        if self.max_lines <= 0:
            raise ValueError(f"max_lines must be positive, got {self.max_lines}")
