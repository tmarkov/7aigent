"""Bash environment implementation."""

import os
import re
from pathlib import Path

import pexpect

from orchestrator.core_types import CommandResponse, CommandText
from orchestrator.interactive import InteractiveEnvironment


class BashEnvironment(InteractiveEnvironment):
    """
    Bash shell environment for executing shell commands.

    Provides a persistent bash shell process that maintains state across
    commands including working directory, environment variables, and background
    jobs.

    Design:
        - Extends InteractiveEnvironment for process management
        - Uses unique PS1/PS2 markers for reliable per-line prompt detection
        - Each line sent produces exactly one prompt: PS1 (command complete)
          or PS2 (continuation expected, e.g. inside a heredoc or after \\)
        - Tracks working directory and exit codes via pwd and echo $?
        - Supports background processes via shell job control (&, jobs)
        - Combined stdout/stderr output (matches terminal behavior)
        - Truncates large output at 10MB limit
        - Auto-restarts on process termination

    State maintained:
        - Current working directory
        - Last command exit code
        - Background job list
        - Whether shell is awaiting continuation input

    Limitations:
        - No timeout mechanism (infinite commands will block indefinitely)
        - Interactive programs (vim, gdb, etc.) not supported
        - Large outputs truncated with warning
    """

    # Unique markers that won't appear in normal command output
    PROMPT_MARKER = "<<<PROMPT>>>"
    PROMPT2_MARKER = "<<<PROMPT2>>>"

    def __init__(self, project_dir: Path = Path(".")) -> None:
        """Initialize bash environment (process starts on first command)."""
        super().__init__(
            prompt_markers=[self.PROMPT_MARKER, self.PROMPT2_MARKER],
            name="Bash",
            project_dir=project_dir,
        )
        self._cwd: str = os.getcwd()
        self._exit_code: int = 0
        self._background_jobs: list[str] = []

    def _get_spawn_command(self) -> tuple[str, list[str]]:
        """
        Get bash spawn command.

        Returns:
            Tuple of ("bash", ["--norc", "--noprofile"])
        """
        # Use 'bash' not '/bin/bash' for Nix compatibility
        return "bash", ["--norc", "--noprofile"]

    def _initialize_process(self) -> None:
        """
        Initialize bash process and configure prompts.

        Sets custom PS1 and PS2 prompt markers and gets initial working directory.
        """
        # Export PS1 and PS2 so they survive into any exec'd subshell.
        # Tools like 'nix develop' replace the current bash with a new one via
        # exec; if PS1/PS2 are only shell variables (not exported), the new bash
        # resets them to defaults ('bash-5.x$ ' and '> '), causing single-line
        # commands to hang and heredocs to hang respectively.
        self._process.send(f'export PS1="{self.PROMPT_MARKER}"\n')
        self._process.expect_exact(self.PROMPT_MARKER)

        # Export PS2 for the same reason (heredoc continuation prompt)
        self._process.send(f'export PS2="{self.PROMPT2_MARKER}"\n')
        self._process.expect_exact(self.PROMPT_MARKER)

        # Get initial working directory
        self._process.send("pwd\n")
        self._process.expect_exact(self.PROMPT_MARKER)
        pwd_output = self._process.before.strip()
        if pwd_output and pwd_output.startswith("/"):
            self._cwd = pwd_output

    def _update_state_after_command(self, command: str) -> None:
        """
        Update working directory, exit code, and background jobs after command.

        Skips state probes when the shell is awaiting continuation input
        (last prompt was PS2), since sending commands at that point would
        be interpreted as continuation of the in-progress compound command.

        Args:
            command: The command that was executed
        """
        if not self._process:
            return

        if self._last_prompt_index != 0:
            # Shell is mid-continuation; state probes would corrupt it
            return

        # Get exit code using echo $?
        self._process.send("echo $?\n")
        self._process.expect_exact(self.PROMPT_MARKER)
        exit_code_output = self._process.before
        # Strip ANSI escape codes (bash emits bracketed paste mode even with --norc)
        clean_output = re.sub(r"\x1b\[[^a-zA-Z]*[a-zA-Z]", "", exit_code_output).strip()
        try:
            self._exit_code = int(clean_output)
        except ValueError:
            # If we can't parse, keep previous exit code
            pass

        # Get working directory using pwd
        self._process.send("pwd\n")
        self._process.expect_exact(self.PROMPT_MARKER)
        pwd_output = self._process.before.strip()
        if pwd_output and pwd_output.startswith("/"):
            self._cwd = pwd_output

        # Update background jobs
        self._update_background_jobs()

    def _update_background_jobs(self) -> None:
        """Update list of background jobs using jobs command."""
        if not self._process:
            return

        # Send jobs command
        self._process.send("jobs\n")
        self._process.expect_exact(self.PROMPT_MARKER)

        output = self._process.before
        # Parse job list
        # Format: [1]+ 1234 Running ./program &
        jobs = []
        for line in output.strip().split("\n"):
            # Skip empty lines and lines without job markers
            if line and re.match(r"\[\d+\]", line):
                jobs.append(line.strip())

        self._background_jobs = jobs

    def _on_restart(self) -> None:
        """Reset bash-specific state on process restart."""
        self._cwd = os.getcwd()
        self._exit_code = 0
        self._background_jobs = []
        self._last_prompt_index = 0

    def _handle_eof(self, eof_exception: pexpect.EOF) -> CommandResponse:
        """
        Handle bash process termination.

        Args:
            eof_exception: The EOF exception from pexpect

        Returns:
            CommandResponse with exit_code field if available
        """
        if not self._process:
            return CommandResponse(
                output="Bash process terminated unexpectedly",
                processed=False,
            )

        # Close to populate exitstatus/signalstatus
        self._process.close()
        exit_status = self._process.exitstatus
        signal_status = self._process.signalstatus

        # Clear process and reset state
        self._process = None
        self._on_restart()

        # Create response with exit_code field
        if signal_status is not None:
            # Killed by signal - always an error
            return CommandResponse(
                output=f"Bash process killed by signal {signal_status}. Environment will restart on next command.",
                processed=False,
            )
        elif exit_status == 0:
            # Clean exit
            response = CommandResponse(
                output="Bash process exited cleanly (exit code 0). Environment will restart on next command.",
                processed=True,
            )
            response.exit_code = 0
            return response
        else:
            # Non-zero exit - error
            response = CommandResponse(
                output=f"Bash process exited with code {exit_status}. Environment will restart on next command.",
                processed=False,
            )
            response.exit_code = exit_status if exit_status is not None else -1
            return response

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        """
        Execute a bash command.

        Args:
            cmd: The command to execute

        Returns:
            Response with combined stdout/stderr output and exit_code field.
            When the shell is awaiting continuation input, the response notes
            this and exit_code is not set.

        Notes:
            - First command initializes bash process
            - Commands block until completion (no timeout)
            - Exit code accessible via response.exit_code
            - Output truncated at 10MB limit
            - Working directory and exit code tracked automatically
        """
        response = super().handle_command(cmd)

        if not response.processed:
            return response

        if self._last_prompt_index != 0:
            continuation_note = "Bash is waiting for continuation input."
            response.output = (
                (response.output + "\n" + continuation_note).strip()
                if response.output
                else continuation_note
            )
        else:
            response.exit_code = self._exit_code

        return response

    def get_state_display(self) -> str:
        """
        Get bash environment state for display.

        Returns:
            Multi-line string showing working directory, exit code, and jobs.
            Empty string before first use.
        """
        if not self._used:
            return ""

        lines = []
        lines.append(f"Working directory: {self._cwd}")

        if self._last_prompt_index != 0:
            lines.append("Status: waiting for continuation input")
        else:
            lines.append(f"Last exit code: {self._exit_code}")

        # Add background jobs if any
        if self._background_jobs:
            lines.append("Background jobs:")
            for job in self._background_jobs:
                lines.append(f"  {job}")
        else:
            lines.append("Background jobs: none")

        return "\n".join(lines)

    def _shutdown_gracefully(self) -> None:
        """Send exit command to bash."""
        self._process.send("exit\n")
