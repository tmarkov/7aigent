"""Interactive environment base class for wrapping persistent processes."""

from abc import ABC, abstractmethod
from typing import Optional

import pexpect

from orchestrator.core_types import CommandResponse, CommandText, ScreenSection


class InteractiveEnvironment(ABC):
    """
    Base class for environments that wrap persistent interactive processes.

    This class encapsulates common patterns for managing pexpect-based processes:
    - Process spawning and initialization
    - Prompt detection for command completion
    - Output capture with truncation
    - Auto-restart on process termination
    - Clean shutdown handling

    Subclasses must implement:
    - _get_spawn_command(): Return command and args for process
    - _initialize_process(): Set up prompts and initial state
    - _update_state_after_command(command): Update environment-specific state
    - get_state_display(): Return state info for screen display

    Subclasses may override:
    - _format_output(raw_output): Process output before returning to user
    - _on_restart(): Called when process restarts after termination
    - _handle_eof(exception): Custom EOF handling

    Example usage:

        class GdbEnvironment(InteractiveEnvironment):
            def __init__(self):
                super().__init__(
                    prompt_marker="(gdb) ",
                    name="gdb"
                )

            def _get_spawn_command(self) -> tuple[str, list[str]]:
                return "gdb", ["--quiet", "--interpreter=mi"]

            def _initialize_process(self) -> None:
                # Process already spawned, just wait for initial prompt
                self._process.expect_exact(self._prompt_marker)

            def _update_state_after_command(self, command: str) -> None:
                # Extract breakpoints, current frame, etc. if needed
                pass

            def get_state_display(self) -> str:
                return "GDB ready" if self._used else "GDB (not started)"
    """

    # Maximum output size (10MB)
    MAX_OUTPUT_SIZE = 10 * 1024 * 1024
    # Command timeout (None = wait indefinitely)
    TIMEOUT = None
    # Buffer size for pexpect read operations (64KB)
    PEXPECT_MAXREAD = 65536

    def __init__(
        self,
        prompt_marker: str,
        name: str,
        max_output_size: int = MAX_OUTPUT_SIZE,
        timeout: Optional[int] = TIMEOUT,
    ) -> None:
        """
        Initialize interactive environment.

        Args:
            prompt_marker: Unique string that marks command completion
            name: Environment name for error messages
            max_output_size: Maximum output bytes before truncation
            timeout: Command timeout in seconds (None = infinite)
        """
        self._prompt_marker = prompt_marker
        self._name = name
        self._max_output_size = max_output_size
        self._timeout = timeout

        self._process: Optional[pexpect.spawn] = None
        self._used = False

    @abstractmethod
    def _get_spawn_command(self) -> tuple[str, list[str]]:
        """
        Get command and arguments for spawning the process.

        Returns:
            Tuple of (command, args_list)

        Example:
            return "python", ["-u", "-q"]
        """
        pass

    @abstractmethod
    def _initialize_process(self) -> None:
        """
        Initialize the spawned process.

        Called after the process is spawned but before marking as ready.
        Should set up custom prompts, configure environment, etc.

        The process is available as self._process.

        Example:
            # Wait for default prompt
            self._process.expect_exact(">>> ")
            # Set custom prompt
            self._process.send(f'import sys; sys.ps1 = "{self._prompt_marker}"\\n')
            self._process.expect_exact(self._prompt_marker)
        """
        pass

    @abstractmethod
    def _update_state_after_command(self, command: str) -> None:
        """
        Update environment-specific state after command execution.

        Args:
            command: The command that was executed

        Called after successful command execution. Use this to extract
        state information (exit codes, variables, etc.) from the process.

        Example:
            # Get exit code
            self._process.send("echo $?\\n")
            self._process.expect_exact(self._prompt_marker)
            self._exit_code = int(self._process.before.strip())
        """
        pass

    @abstractmethod
    def get_state_display(self) -> str:
        """
        Get environment-specific state for display.

        Returns:
            Multi-line string describing current state

        This is called by get_screen() to show state before help text.

        Example:
            return f"Working directory: {self._cwd}\\nExit code: {self._exit_code}"
        """
        pass

    def _format_output(self, raw_output: str) -> str:
        """
        Format raw process output before returning to user.

        Args:
            raw_output: Raw output from process

        Returns:
            Formatted output

        Override this to strip ANSI codes, reformat output, etc.
        Default implementation returns output as-is.
        """
        return raw_output

    def _get_spawn_env(self) -> Optional[dict[str, str]]:
        """
        Get environment variables for spawning the process.

        Returns:
            Dictionary of environment variables, or None to inherit parent env

        Override this to set custom environment variables for the process.
        Default implementation returns None (inherit parent environment).

        Example:
            return {"TERM": "dumb", "PYTHONIOENCODING": "utf-8"}
        """
        return None

    def _on_restart(self) -> None:
        """
        Called when process is about to restart after termination.

        Override this to reset environment-specific state.
        Default implementation does nothing.
        """
        pass

    def _handle_eof(self, eof_exception: pexpect.EOF) -> CommandResponse:
        """
        Handle process termination.

        Args:
            eof_exception: The EOF exception from pexpect

        Returns:
            CommandResponse describing the termination

        Override this for custom EOF handling. Default implementation:
        - Closes process to get exit status
        - Returns appropriate error message
        - Clears process so it restarts on next command
        - Calls _on_restart() hook
        """
        if not self._process:
            return CommandResponse(
                output=f"{self._name} process terminated unexpectedly",
                processed=False,
            )

        # Close to populate exitstatus/signalstatus
        self._process.close()
        exit_status = self._process.exitstatus
        signal_status = self._process.signalstatus

        # Clear process so it restarts on next command
        self._process = None
        self._on_restart()

        # Determine if this was a clean exit or error
        if signal_status is not None:
            # Killed by signal - always an error
            return CommandResponse(
                output=f"{self._name} process killed by signal {signal_status}. Environment will restart on next command.",
                processed=False,
            )
        elif exit_status == 0:
            # Clean exit
            return CommandResponse(
                output=f"{self._name} process exited cleanly (exit code 0). Environment will restart on next command.",
                processed=True,
            )
        else:
            # Non-zero exit - error
            return CommandResponse(
                output=f"{self._name} process exited with code {exit_status}. Environment will restart on next command.",
                processed=False,
            )

    def _start_process(self) -> None:
        """Start the process and run initialization."""
        # Get spawn command from subclass
        cmd, args = self._get_spawn_command()

        # Get environment variables from subclass
        env = self._get_spawn_env()

        # Spawn process
        self._process = pexpect.spawn(
            cmd,
            args,
            encoding="utf-8",
            codec_errors="replace",
            echo=False,
            maxread=self.PEXPECT_MAXREAD,
            env=env,
        )

        # Let subclass initialize (set prompts, etc.)
        self._initialize_process()

        # Mark as used
        self._used = True

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        """
        Execute a command in the interactive process.

        Args:
            cmd: The command to execute

        Returns:
            Response with output and processed status

        Notes:
            - First command initializes the process
            - Commands block until prompt detected (or timeout)
            - Process auto-restarts on termination
            - Output truncated at max_output_size limit
        """
        try:
            # Start process on first command
            if self._process is None:
                self._start_process()

            # Send command
            command = cmd.value
            self._send_command(command)

            # Wait for prompt marker
            self._process.expect_exact(self._prompt_marker, timeout=self._timeout)

            # Get output (everything before the prompt marker)
            raw_output = self._process.before.strip()

            # Check output size and truncate if needed
            if len(raw_output) > self._max_output_size:
                raw_output = raw_output[-self._max_output_size :]
                raw_output = (
                    f"[WARNING: Output truncated to last {self._max_output_size} bytes]\n\n"
                    + raw_output
                )

            # Format output (subclass hook)
            output = self._format_output(raw_output)

            # Update state (subclass hook)
            self._update_state_after_command(command)

            return CommandResponse(output=output, processed=True)

        except pexpect.EOF as e:
            return self._handle_eof(e)

        except pexpect.TIMEOUT:
            return CommandResponse(
                output="Command timed out (prompt not detected)", processed=False
            )

        except Exception as e:
            return CommandResponse(
                output=f"Error executing command: {e}", processed=False
            )

    def _send_command(self, command: str) -> None:
        """
        Send command to process.

        Args:
            command: The command to send

        Override this for custom command sending logic (like multi-line handling).
        Default implementation sends command + newline.
        """
        self._process.send(command + "\n")

    def get_screen(self) -> ScreenSection:
        """
        Get current environment state for display.

        Returns:
            Screen section with state and help text

        Calls get_state_display() to get environment-specific content.
        """
        content = self.get_state_display()
        return ScreenSection(content=content, max_lines=50)

    def shutdown(self) -> None:
        """Clean up process on orchestrator shutdown."""
        if self._process:
            try:
                # Try graceful shutdown - subclasses can override _shutdown_gracefully
                self._shutdown_gracefully()
                self._process.expect(pexpect.EOF, timeout=2)
            except (pexpect.TIMEOUT, pexpect.EOF):
                # Graceful shutdown failed or already terminated
                pass
            finally:
                # Force kill if still alive
                if self._process.isalive():
                    self._process.terminate(force=True)
                self._process = None

    def _shutdown_gracefully(self) -> None:
        """
        Attempt graceful shutdown of process.

        Override this to send process-specific exit command.
        Default sends "exit\\n".
        """
        self._process.send("exit\n")
