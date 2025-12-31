"""Python REPL environment implementation."""

import os
import re
import sys
from typing import Optional

import pexpect

from orchestrator.core_types import CommandResponse, CommandText, ScreenSection


class PythonEnvironment:
    """
    Python REPL environment for executing Python code.

    Provides a persistent Python interpreter that maintains namespace state
    across commands, with variable tracking and display.

    Design:
        - Spawns persistent Python process using pexpect
        - Uses custom prompt marker for reliable command completion detection
        - Tracks namespace variables with type information
        - Tracks variable usage via regex matching in commands
        - Displays working directory and recently used variables on screen
        - Supports multi-line code execution

    State maintained:
        - Global namespace (variables, functions, classes)
        - Variable usage ordering (most recent first)
        - Current working directory
        - Whether environment has been used

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
        self._process: Optional[pexpect.spawn] = None
        self._used = False
        self._cwd: str = os.getcwd()
        self._ordered_vars: list[str] = []

    def _start_process(self) -> None:
        """Start Python process and configure prompt."""
        # Spawn Python REPL using same Python executable as current process
        # This ensures compatibility in Nix build environment
        # Set TERM=dumb to disable ANSI escape codes
        self._process = pexpect.spawn(
            sys.executable,
            ["-u", "-q"],  # -u: unbuffered, -q: quiet (no banner)
            encoding="utf-8",
            codec_errors="replace",
            echo=False,
            maxread=65536,
            env={"TERM": "dumb", "PYTHONIOENCODING": "utf-8"},
        )

        # Wait for initial prompt (>>>)
        self._process.expect_exact(">>> ")

        # Set up custom prompt using sys.ps1 and sys.ps2
        # ps1 is primary prompt, ps2 is continuation prompt
        self._process.send(f'import sys; sys.ps1 = "{self.PROMPT_MARKER}"\n')
        self._process.expect_exact(self.PROMPT_MARKER)

        # Set continuation prompt (for multi-line code)
        self._process.send('sys.ps2 = ""\n')  # Empty continuation prompt
        self._process.expect_exact(self.PROMPT_MARKER)

        # Get initial working directory
        self._process.send("import os; os.getcwd()\n")
        self._process.expect_exact(self.PROMPT_MARKER)
        output = self._process.before.strip()
        # Output will be like: "'/ home/user/project'"
        # Extract the path from the repr string
        if output and output.startswith("'") and output.endswith("'"):
            self._cwd = output[1:-1]

        self._used = True

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
            # Use eval to parse the dict representation
            # This is safe because we control the Python process output
            var_dict = eval(output)
            # Convert type strings to simple names
            return {k: self._get_type_name(v) for k, v in var_dict.items()}
        except Exception:
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
        # Add matches at front, preserving their relative order from the match
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

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        """
        Execute Python code.

        Args:
            cmd: The Python code to execute

        Returns:
            Response with output (printed values and expression results)
        """
        try:
            # Start process on first command
            if self._process is None:
                self._start_process()

            # Send command
            command = cmd.value

            # For multi-line code, we need to send an extra newline to complete it
            # Check if this looks like multi-line code (contains newline)
            if "\n" in command:
                # Multi-line: send command + blank line to complete
                self._process.send(command + "\n\n")
            else:
                # Single line: just send with newline
                self._process.send(command + "\n")

            # Wait for prompt marker (with reasonable timeout)
            # Use None timeout for now (matches bash behavior)
            # Future: make this configurable
            self._process.expect_exact(self.PROMPT_MARKER, timeout=None)

            # Get output
            output = self._process.before.strip()

            # Update working directory and variable tracking
            self._update_state_after_command(command)

            # Python REPL doesn't have an explicit success/failure indicator
            # We consider it successful if we got a prompt back
            # Exceptions will be in the output
            success = True

            return CommandResponse(output=output, success=success)

        except pexpect.EOF:
            return CommandResponse(
                output="Python process terminated unexpectedly", success=False
            )
        except pexpect.TIMEOUT:
            return CommandResponse(
                output="Command timed out (prompt not detected)", success=False
            )
        except Exception as e:
            return CommandResponse(
                output=f"Error executing command: {e}", success=False
            )

    def get_screen(self) -> ScreenSection:
        """
        Get current Python environment state.

        Returns:
            Screen section showing working directory and variables with types
        """
        if not self._used:
            return ScreenSection(content="Python REPL (ready)", max_lines=50)

        # Get current namespace
        namespace = self._get_namespace_variables()

        # Build screen content
        lines = [f"Working directory: {self._cwd}", "", "Variables (by recent use):"]

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

        content = "\n".join(lines)
        return ScreenSection(content=content, max_lines=50)

    def shutdown(self) -> None:
        """Clean up Python process."""
        if self._process:
            try:
                # Try graceful shutdown
                self._process.send("exit()\n")
                self._process.expect(pexpect.EOF, timeout=2)
            except (pexpect.TIMEOUT, pexpect.EOF):
                pass
            finally:
                if self._process.isalive():
                    self._process.terminate(force=True)
                self._process = None
