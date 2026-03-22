"""Declarative environment base class for structured command environments."""

from pathlib import Path
from typing import Callable

from orchestrator.core_types import CommandResponse, CommandText, ScreenSection


def command(
    signature: str,
    examples: list[tuple[str, str]] | None = None,
):
    """
    Decorator for declarative environment commands.

    Marks a method as a command handler and attaches metadata for automatic
    help generation and command discovery. The method's docstring becomes the
    command description in the help template.

    Args:
        signature: Command signature (e.g., "view <file> /<start>/ /<end>/ [label]")
        examples: List of (description, command_text) tuples shown in the help template

    Example usage:
        @command(
            signature="edit <file> <start>-<end>",
            examples=[("Edit lines 45-50", "edit src/main.py 45-50\\n    new code here")],
        )
        def edit(self, filepath: str, line_range: str, content: str):
            '''Replace lines with new content. Content on subsequent lines.'''
            ...

    The decorated method will have a `_command_metadata` attribute containing
    the signature and examples. The method docstring is used as the description.
    """

    def decorator(func: Callable) -> Callable:
        func._command_metadata = {
            "signature": signature,
            "examples": examples or [],
        }
        return func

    return decorator


class DeclarativeEnvironment:
    """
    Base class for environments with structured command sets.

    Provides automatic:
    - Command discovery via @command decorator
    - Command routing to decorated methods
    - Help generation from docstrings and a help.md template

    Subclasses should:
    1. Decorate command handler methods with @command (docstring = description)
    2. Provide a help.md file co-located with their implementation
    3. Implement get_state_display() to provide custom state (optional)
    4. Override _execute_command() for custom command parsing (optional)

    Help template cascade ({{commands}} placeholder is substituted):
    1. project_dir/env/{env_name}/help.md  (project override)
    2. package/environments/{env_name}/help.md  (built-in help)
    3. package/templates/declarative_help.md  (generic fallback)

    Example:
        class TimerEnvironment(DeclarativeEnvironment):
            '''Timer for tracking elapsed time'''

            def __init__(self, project_dir: Path = Path(".")) -> None:
                super().__init__(project_dir=project_dir)
                self._start_time = None

            @command(
                signature="start",
                examples=[("Start timing", "start")],
            )
            def start(self) -> str:
                '''Start the timer from zero or resume after stop.'''
                self._start_time = time.time()
                return "Timer started"

            def get_state_display(self) -> str:
                return "Timer: Running" if self._start_time else "Timer: Stopped"
    """

    def __init__(self, project_dir: Path = Path(".")) -> None:
        """Initialize declarative environment with command discovery."""
        self._project_dir = project_dir
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
        Route command to appropriate method.

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
                processed=False,
            )

        # Route to method
        method, metadata = self._commands[cmd_name]
        try:
            result = self._execute_command(method, cmd.value)
            return CommandResponse(output=result, processed=True)
        except Exception as e:
            return CommandResponse(output=f"Error: {e}", processed=False)

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

    def _env_name(self) -> str:
        """
        Get environment name derived from class name.

        Returns:
            Lowercase name with 'Environment' suffix removed
            (e.g., 'BashEnvironment' -> 'bash')
        """
        return self.__class__.__name__.replace("Environment", "").lower()

    def _load_help_template(self) -> str:
        """
        Load help template with cascade fallback.

        Cascade order:
        1. project_dir/env/{env_name}/help.md  (project override)
        2. package/environments/{env_name}/help.md  (built-in)
        3. package/templates/declarative_help.md  (generic fallback)

        Returns:
            Template content as string
        """
        env_name = self._env_name()
        module_dir = Path(__file__).parent

        # 1. Project-level override
        project_override = self._project_dir / "env" / env_name / "help.md"
        if project_override.exists():
            return project_override.read_text(encoding="utf-8")

        # 2. Package-provided help
        package_help = module_dir / "environments" / env_name / "help.md"
        if package_help.exists():
            return package_help.read_text(encoding="utf-8")

        # 3. Generic fallback
        fallback = module_dir / "templates" / "declarative_help.md"
        return fallback.read_text(encoding="utf-8")

    def _render_commands(self) -> str:
        """
        Generate command reference block from @command metadata and docstrings.

        Returns:
            Markdown-formatted command reference with one section per command
        """
        env_name = self._env_name()
        sections = []

        for cmd_name in sorted(self._commands.keys()):
            method, metadata = self._commands[cmd_name]
            sig = metadata["signature"]
            examples = metadata["examples"]

            # Get description from method docstring
            doc = (method.__doc__ or "").strip()

            parts = [f"### {sig}", "", doc]

            if examples:
                parts.append("")
                parts.append("Examples:")
                for desc, text in examples:
                    parts.append("")
                    parts.append(f"  {desc}:")
                    parts.append("")
                    parts.append(f"    <{env_name}>")
                    for line in text.split("\n"):
                        parts.append(f"    {line}")
                    parts.append(f"    </{env_name}>")

            sections.append("\n".join(parts))

        return "\n\n".join(sections)

    def get_help(self) -> str:
        """
        Render help template with {{commands}} substituted.

        Returns:
            Rendered help text with command reference injected
        """
        template = self._load_help_template()
        return template.replace("{{commands}}", self._render_commands())

    def get_screen(self) -> ScreenSection:
        """
        Generate screen with state display and help.

        Returns:
            Screen section with state and command help
        """
        state = self.get_state_display()
        help_text = self.get_help()
        content = f"{state}\n\n{help_text}" if state.strip() else help_text
        return ScreenSection(content=content)

    def get_state_display(self) -> str:
        """
        Override in subclass to provide custom state display.

        Returns:
            String describing current environment state, or empty string if no state
        """
        return ""

    def shutdown(self) -> None:
        """Clean up environment resources. Override if needed."""
        pass
