"""Interactive environment base class for wrapping persistent processes."""

from abc import ABC, abstractmethod
from pathlib import Path
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
    - Help template loading from co-located help.md files

    Every line sent to the process must produce exactly one prompt response.
    Environments that cannot guarantee this are not supported. prompt_markers
    lists all recognised prompts; the base class tracks which one was last seen
    via _last_prompt_index so subclasses can act on it in
    _update_state_after_command and get_state_display.

    Subclasses must implement:
    - _get_spawn_command(): Return command and args for process
    - _initialize_process(): Set up prompts and initial state
    - _update_state_after_command(command): Update environment-specific state
    - get_state_display(): Return state info for screen display

    Subclasses may override:
    - _format_output(raw_output): Process output before returning to user
    - _on_restart(): Called when process restarts after termination
    - _handle_eof(exception): Custom EOF handling
    - get_help(): Override to provide help text without a help.md file

    Help template cascade:
    1. project_dir/env/{env_name}/help.md  (project override)
    2. package/environments/{env_name}/help.md  (built-in help)
    3. FileNotFoundError if neither exists

    Example usage:

        class GdbEnvironment(InteractiveEnvironment):
            def __init__(self, project_dir: Path = Path(".")) -> None:
                super().__init__(
                    prompt_markers=["(gdb) "],
                    name="gdb",
                    project_dir=project_dir,
                )

            def _get_spawn_command(self) -> tuple[str, list[str]]:
                return "gdb", ["--quiet", "--interpreter=mi"]

            def _initialize_process(self) -> None:
                # Process already spawned, just wait for initial prompt
                self._process.expect_exact(self._prompt_markers[0])

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
        prompt_markers: list[str],
        name: str,
        max_output_size: int = MAX_OUTPUT_SIZE,
        timeout: Optional[int] = TIMEOUT,
        project_dir: Path = Path("."),
    ) -> None:
        """
        Initialize interactive environment.

        Args:
            prompt_markers: Non-empty list of prompt strings the process may
                emit after each line of input. Index 0 is conventionally the
                primary (ready) prompt; higher indices are continuation prompts.
                Every line sent must produce exactly one of these prompts.
            name: Environment name for error messages
            max_output_size: Maximum output bytes before truncation
            timeout: Command timeout in seconds (None = infinite)
            project_dir: Project root directory for help template lookup
        """
        if not prompt_markers:
            raise ValueError("prompt_markers must contain at least one entry")
        self._prompt_markers = prompt_markers
        self._name = name
        self._max_output_size = max_output_size
        self._timeout = timeout
        self._project_dir = project_dir

        self._process: Optional[pexpect.spawn] = None
        self._used = False
        # Index into _prompt_markers of the prompt received after the last line
        self._last_prompt_index: int = 0

    @abstractmethod
    def _get_spawn_command(self) -> tuple[str, list[str]]:
        """
        Get command and arguments for spawning the process.

        Returns:
            Tuple of (command, args_list)

        Example:
            return "bash", ["--norc", "--noprofile"]
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
            self._process.send(f'PS1="{self._prompt_markers[0]}"\\n')
            self._process.expect_exact(self._prompt_markers[0])
        """
        pass

    @abstractmethod
    def _update_state_after_command(self, command: str) -> None:
        """
        Update environment-specific state after command execution.

        Args:
            command: The command that was executed

        Called after every command, including when the process is in
        continuation state. Implementations should check _last_prompt_index
        and update state accordingly — for example, skipping state probes
        that would corrupt an in-progress compound command.

        Example:
            if self._last_prompt_index != 0:
                return  # mid-continuation, no state to probe
            self._process.send("echo $?\\n")
            self._process.expect_exact(self._prompt_markers[0])
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
            if self._last_prompt_index != 0:
                return "Status: waiting for continuation input"
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

        Sends the command one line at a time. After each line, waits for
        exactly one prompt from prompt_markers. This guarantees no stale
        output accumulates in the pexpect buffer between commands, regardless
        of how many lines the command contains.

        _last_prompt_index is updated after each line and reflects which
        prompt was returned for the final line when handle_command returns.

        Args:
            cmd: The command to execute

        Returns:
            Response with output and processed status
        """
        try:
            # Start process on first command
            if self._process is None:
                self._start_process()

            command = cmd.value
            lines = command.splitlines() or [""]
            combined: list[str] = []

            for line in lines:
                self._process.send(line + "\n")
                idx = self._process.expect_exact(
                    self._prompt_markers, timeout=self._timeout
                )
                combined.append(self._process.before)
                self._last_prompt_index = idx

            raw_output = "".join(combined).strip()

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
        3. FileNotFoundError if neither exists

        Returns:
            Template content as string

        Raises:
            FileNotFoundError: If no help template is found
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

        raise FileNotFoundError(
            f"No help.md found for environment '{env_name}'. "
            f"Checked: {project_override}, {package_help}"
        )

    def get_help(self) -> str:
        """
        Return help template as-is (no substitution for interactive environments).

        Returns:
            Help text from the environment's help.md file, or empty string if not found
        """
        try:
            return self._load_help_template()
        except FileNotFoundError:
            return ""

    def get_screen(self) -> ScreenSection:
        """
        Get current environment state for display.

        Returns:
            Screen section with state and help text

        Calls get_state_display() to get environment-specific state, then
        appends help text from the help.md template.
        """
        state = self.get_state_display()
        help_text = self.get_help()
        if state.strip() and help_text.strip():
            content = f"{state}\n\n{help_text}"
        elif state.strip():
            content = state
        else:
            content = help_text
        return ScreenSection(content=content)

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
