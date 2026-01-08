"""Declarative environment base class for structured command environments."""

from typing import Callable

from orchestrator.core_types import CommandResponse, CommandText, ScreenSection


def command(signature: str, description: str, example: str):
    """
    Decorator for declarative environment commands.

    Marks a method as a command handler and attaches metadata for automatic
    help generation and command discovery.

    Args:
        signature: Command signature (e.g., "view <file> /<start>/ /<end>/ [label]")
        description: Multi-line detailed description of what the command does
        example: Raw command invocation (will be wrapped in markdown fence)

    Example usage:
        @command(
            signature="edit <file> <start>-<end>",
            description="Replace lines with new content.\\nContent on subsequent lines.",
            example="edit src/main.py 45-50\\n    new code here"
        )
        def edit(self, filepath: str, line_range: str, content: str):
            ...

    The decorated method will have a `_command_metadata` attribute containing
    the signature, description, and example.
    """

    def decorator(func: Callable) -> Callable:
        func._command_metadata = {
            "signature": signature,
            "description": description,
            "example": example,
        }
        return func

    return decorator


class DeclarativeEnvironment:
    """
    Base class for environments with structured command sets.

    Provides automatic:
    - Command discovery via @command decorator
    - Per-command usage tracking
    - Progressive help generation (LONG for unused, SHORT for used commands)
    - Command routing to decorated methods

    Subclasses should:
    1. Decorate command handler methods with @command
    2. Implement get_state_display() to provide custom state (optional)
    3. Override _execute_command() for custom command parsing (optional)

    Example:
        class TimerEnvironment(DeclarativeEnvironment):
            '''Timer for tracking elapsed time'''

            def __init__(self):
                super().__init__()
                self._start_time = None

            @command(
                signature="start",
                description="Start the timer from zero or resume after stop.",
                example="start"
            )
            def start(self):
                self._start_time = time.time()
                return "Timer started"

            def get_state_display(self) -> str:
                return "Timer: Running" if self._start_time else "Timer: Stopped"
    """

    def __init__(self):
        """Initialize declarative environment with command discovery and usage tracking."""
        self._command_usage: set[str] = set()  # Track which commands have been used
        self._commands: dict[str, tuple[Callable, dict]] = self._discover_commands()

    def _discover_commands(self) -> dict[str, tuple[Callable, dict]]:
        """
        Find all @command decorated methods.

        Returns:
            Dictionary mapping command names to (method, metadata) tuples
        """
        commands = {}
        for name in dir(self):
            attr = getattr(self, name)
            if hasattr(attr, "_command_metadata"):
                # Extract command name from signature (first word)
                sig = attr._command_metadata["signature"]
                cmd_name = sig.split()[0]
                commands[cmd_name] = (attr, attr._command_metadata)
        return commands

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        """
        Route command to appropriate method and track usage.

        Args:
            cmd: The command to execute

        Returns:
            Command response with output and success status
        """
        # Parse command name from first line
        cmd_lines = cmd.value.split("\n")
        first_line = cmd_lines[0].strip()
        cmd_name = first_line.split()[0] if first_line else ""

        if cmd_name not in self._commands:
            available = ", ".join(sorted(self._commands.keys()))
            return CommandResponse(
                output=f"Unknown command: {cmd_name}\nAvailable: {available}",
                success=False,
            )

        # Mark command as used
        self._command_usage.add(cmd_name)

        # Route to method
        method, metadata = self._commands[cmd_name]
        try:
            # Subclass can override _execute_command for custom parsing
            result = self._execute_command(method, cmd.value)
            return CommandResponse(output=result, success=True)
        except Exception as e:
            return CommandResponse(output=f"Error: {e}", success=False)

    def _execute_command(self, method: Callable, cmd_text: str) -> str:
        """
        Parse command and execute method.

        Subclasses can override this for custom command parsing.
        Default implementation passes the entire command text to the method.

        Args:
            method: The command handler method to execute
            cmd_text: The full command text

        Returns:
            Command result string

        Raises:
            Exception: Any exception from the command handler
        """
        return method(cmd_text)

    def get_screen(self) -> ScreenSection:
        """
        Generate screen with state display and progressive help.

        Returns:
            Screen section with state and command help
        """
        # Get state from subclass (optional)
        # Check if get_state_display was overridden in subclass
        if type(self).get_state_display is not DeclarativeEnvironment.get_state_display:
            state = self.get_state_display()
        else:
            # Default: use class docstring
            state = self.__class__.__doc__ or "Environment ready"
            # Clean up docstring formatting (remove leading/trailing whitespace)
            state = state.strip()

        # Build command help with progressive disclosure
        commands_help = []
        for cmd_name in sorted(self._commands.keys()):
            method, metadata = self._commands[cmd_name]
            sig = metadata["signature"]
            desc = metadata["description"]
            example = metadata["example"]

            if cmd_name in self._command_usage:
                # SHORT help: signature - one-line description
                short_desc = desc.split("\n")[0]  # First line only
                commands_help.append(f"  {sig} - {short_desc}")
            else:
                # LONG help: signature, description, example
                # Indent multi-line descriptions
                desc_indented = desc.replace("\n", "\n    ")

                # Wrap example in markdown code fence with environment name
                env_name = self.__class__.__name__.replace("Environment", "").lower()
                example_lines = example.split("\n")
                example_formatted = f"    ```{env_name}\n"
                for line in example_lines:
                    example_formatted += f"    {line}\n"
                example_formatted += "    ```"

                commands_help.append(
                    f"  {sig}\n    {desc_indented}\n    Example:\n{example_formatted}"
                )

        content = state + "\n\nCommands:\n" + "\n\n".join(commands_help)
        return ScreenSection(content=content, max_lines=100)

    def get_state_display(self) -> str:
        """
        Override in subclass to provide custom state display.

        Returns:
            String describing current environment state

        Raises:
            NotImplementedError: If subclass doesn't implement this and needs it
        """
        raise NotImplementedError("Subclass should implement get_state_display()")

    def shutdown(self) -> None:
        """Clean up environment resources. Override if needed."""
        pass
