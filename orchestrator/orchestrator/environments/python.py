"""Python REPL environment implementation."""

import ast
import os
import re
import sys

from orchestrator.interactive import InteractiveEnvironment


class PythonEnvironment(InteractiveEnvironment):
    """
    Python REPL environment for executing Python code.

    Provides a persistent Python interpreter that maintains namespace state
    across commands, with variable tracking and display.

    Design:
        - Extends InteractiveEnvironment for process management
        - Uses custom prompt marker for reliable command completion detection
        - Tracks namespace variables with type information
        - Tracks variable usage via regex matching in commands
        - Displays working directory and recently used variables on screen
        - Supports multi-line code execution
        - Auto-restarts on process termination

    State maintained:
        - Global namespace (variables, functions, classes)
        - Variable usage ordering (most recent first)
        - Current working directory

    Limitations:
        - No timeout mechanism (infinite loops will block indefinitely)
        - Variable tracking uses simple regex (may have false positives)
        - Limited to 100 most recently used variables on screen
    """

    # Unique marker for prompt detection
    PROMPT_MARKER = "<<<PROMPT>>>"
    # Maximum variables to display
    MAX_VARIABLES_DISPLAY = 100

    def __init__(self) -> None:
        """Initialize Python environment (process starts on first command)."""
        super().__init__(
            prompt_marker=self.PROMPT_MARKER,
            name="Python",
        )
        self._cwd: str = os.getcwd()
        self._ordered_vars: list[str] = []

    def _get_spawn_command(self) -> tuple[str, list[str]]:
        """
        Get Python REPL spawn command.

        Returns:
            Tuple of (python_executable, ["-u", "-q"])

        Handles SHELL_PREFIX environment variable for nix develop compatibility.
        """
        # Check for shell prefix (e.g., "nix develop --command")
        shell_prefix = os.environ.get("SHELL_PREFIX", "")

        if shell_prefix:
            # Parse prefix and append python command
            # Example: "nix develop --command" + "python"
            import shlex

            cmd_parts = shlex.split(shell_prefix) + [sys.executable, "-u", "-q"]
            return cmd_parts[0], cmd_parts[1:]
        else:
            # No wrapper, direct python
            return sys.executable, ["-u", "-q"]  # -u: unbuffered, -q: quiet

    def _get_spawn_env(self) -> dict[str, str]:
        """
        Set environment variables for Python process.

        Returns:
            Environment dict with TERM=dumb to disable ANSI codes
        """
        return {"TERM": "dumb", "PYTHONIOENCODING": "utf-8"}

    def _initialize_process(self) -> None:
        """
        Initialize Python REPL and configure prompt.

        Sets custom sys.ps1/ps2 prompts and gets initial working directory.
        """
        # Wait for initial prompt (>>>)
        self._process.expect_exact(">>> ")

        # Set up custom prompt using sys.ps1 and sys.ps2
        self._process.send(f'import sys; sys.ps1 = "{self.PROMPT_MARKER}"\n')
        self._process.expect_exact(self.PROMPT_MARKER)

        # Set continuation prompt (for multi-line code)
        self._process.send('sys.ps2 = ""\n')  # Empty continuation prompt
        self._process.expect_exact(self.PROMPT_MARKER)

        # Get initial working directory
        self._process.send("import os; os.getcwd()\n")
        self._process.expect_exact(self.PROMPT_MARKER)
        output = self._process.before.strip()
        # Output will be like: "'/home/user/project'"
        # Extract the path from the repr string
        if output and output.startswith("'") and output.endswith("'"):
            self._cwd = output[1:-1]

    def _get_type_name(self, type_str: str) -> str:
        """
        Extract simple type name from type() output.

        Args:
            type_str: String like "<class 'int'>" or "<class 'numpy.ndarray'>"

        Returns:
            Simple type name like "int" or "ndarray"
        """
        # Extract from <class 'module.TypeName'> format
        match = re.search(r"<class '(?:.*\.)?(\w+)'>", type_str)
        if match:
            return match.group(1)
        # Fallback: return as-is if pattern doesn't match
        return type_str

    def _get_namespace_variables(self) -> dict[str, str]:
        """
        Get current namespace variables with their type names.

        Returns:
            Dictionary mapping variable names to type names
        """
        if not self._process:
            return {}

        # Get all variables from globals()
        # Filter out private vars and modules
        # Keep user-defined functions, classes, and data
        self._process.send(
            "import types; "
            "{k: str(type(v)) for k, v in globals().items() "
            "if not k.startswith('_') "
            "and not isinstance(v, types.ModuleType)}\n"
        )
        self._process.expect_exact(self.PROMPT_MARKER)
        output = self._process.before.strip()

        # Parse output: {'var1': "<class 'int'>", 'var2': "<class 'str'>"}
        try:
            # Use ast.literal_eval to safely parse the dict representation
            var_dict = ast.literal_eval(output)
            # Verify it's actually a dict
            if not isinstance(var_dict, dict):
                return {}
            # Convert type strings to simple names
            return {k: self._get_type_name(v) for k, v in var_dict.items()}
        except (ValueError, SyntaxError, AttributeError):
            # If parsing fails, return empty dict
            return {}

    def _update_variable_ordering(
        self, command: str, namespace: dict[str, str]
    ) -> None:
        """
        Update variable ordering based on usage in command.

        Args:
            command: The command that was executed
            namespace: Current namespace variables
        """
        # Find variables mentioned in command
        matches = []
        for var_name in namespace.keys():
            # Use word boundary regex to match whole variable names
            if re.search(rf"\b{re.escape(var_name)}\b", command):
                matches.append(var_name)

        # Move matched variables to front of ordered list
        # Remove matches from current position
        remaining = [v for v in self._ordered_vars if v not in matches]
        # Add matches at front
        self._ordered_vars = matches + remaining

        # Add any new variables (not in matches or remaining)
        for var_name in namespace.keys():
            if var_name not in self._ordered_vars:
                self._ordered_vars.append(var_name)

    def _update_state_after_command(self, command: str) -> None:
        """
        Update working directory and variable tracking after command execution.

        Args:
            command: The command that was executed
        """
        if not self._process:
            return

        # Get current working directory
        self._process.send("import os; os.getcwd()\n")
        self._process.expect_exact(self.PROMPT_MARKER)
        output = self._process.before.strip()
        # Output will be like: "'/home/user/project'"
        if output and output.startswith("'") and output.endswith("'"):
            self._cwd = output[1:-1]

        # Get namespace and update variable ordering
        namespace = self._get_namespace_variables()
        self._update_variable_ordering(command, namespace)

    def _send_command(self, command: str) -> None:
        """
        Send Python code to REPL, handling multi-line statements.

        Args:
            command: The Python code to send

        Multi-line code and compound statements require an extra newline
        to tell Python the block is complete.
        """
        # For multi-line code or compound statements, we need an extra newline
        # Check if:
        # 1. Contains newline (explicitly multi-line), OR
        # 2. Is a complete single-line compound statement
        is_multiline = "\n" in command

        # Check for complete compound statement (must have colon)
        stripped = command.lstrip()
        is_compound = (
            (stripped.startswith(("def ", "class ")) and ":" in command)
            or (
                stripped.startswith(
                    ("if ", "for ", "while ", "with ", "elif ", "else:")
                )
                and command.rstrip().endswith(":")
            )
            or stripped.startswith(("try:", "except", "finally:"))
        )

        if is_multiline or is_compound:
            # Multi-line or compound: send command + blank line to complete
            self._process.send(command + "\n\n")
        else:
            # Simple single line: just send with newline
            self._process.send(command + "\n")

    def _on_restart(self) -> None:
        """Reset Python-specific state on process restart."""
        self._cwd = os.getcwd()
        self._ordered_vars = []

    def get_state_display(self) -> str:
        """
        Get Python environment state for display.

        Returns:
            Multi-line string showing working directory, variables, and help
        """
        lines = []

        if self._used:
            # Get current namespace
            namespace = self._get_namespace_variables()

            lines.append(f"Working directory: {self._cwd}")
            lines.append("")
            lines.append("Variables (recent):")

            # Display variables in order, limit to MAX_VARIABLES_DISPLAY
            displayed_count = 0
            for var_name in self._ordered_vars:
                if var_name in namespace:
                    type_name = namespace[var_name]
                    lines.append(f"  {var_name}: {type_name}")
                    displayed_count += 1
                    if displayed_count >= self.MAX_VARIABLES_DISPLAY:
                        break

            # If no variables, show message
            if displayed_count == 0:
                lines.append("  (no variables)")

            # Add blank line before help
            lines.append("")

        # Always show help text
        lines.append("Any Python code. Variables and imports persist across commands.")

        return "\n".join(lines)

    def _shutdown_gracefully(self) -> None:
        """Send exit() command to Python."""
        self._process.send("exit()\n")
