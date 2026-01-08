"""Bash environment implementation."""

import os
import re
from typing import Optional

import pexpect

from orchestrator.core_types import CommandResponse, CommandText, ScreenSection


class BashEnvironment:
    """
    Bash shell environment for executing shell commands.

    Provides a persistent bash shell process that maintains state across
    commands including working directory, environment variables, and background
    jobs.

    Design:
        - Spawns persistent bash process using pexpect
        - Uses unique prompt marker (<<<PROMPT>>>) for reliable command completion detection
        - Tracks working directory and exit codes via PS1 and special commands
        - Supports background processes via shell job control (&, jobs)
        - Combined stdout/stderr output (matches terminal behavior)
        - Truncates large output at 10MB limit

    State maintained:
        - Current working directory
        - Last command exit code
        - Background job list
        - Whether environment has been used

    Limitations:
        - No timeout mechanism (infinite commands will block indefinitely)
        - Interactive programs (vim, gdb, etc.) not supported
        - Large outputs truncated with warning
    """

    # Unique marker that won't appear in normal command output
    PROMPT_MARKER = "<<<PROMPT>>>"
    # Maximum output size (10MB)
    MAX_OUTPUT_SIZE = 10 * 1024 * 1024

    def __init__(self) -> None:
        """Initialize bash environment (process starts on first command)."""
        self._process: Optional[pexpect.spawn] = None
        self._used = False
        self._cwd: str = os.getcwd()
        self._exit_code: int = 0
        self._background_jobs: list[str] = []

    def _start_process(self) -> None:
        """Start bash process and configure prompt."""
        # Spawn bash with explicit settings
        # Use 'bash' not '/bin/bash' for Nix compatibility
        self._process = pexpect.spawn(
            "bash",
            ["--norc", "--noprofile"],
            encoding="utf-8",
            codec_errors="replace",
            # Disable echo to avoid seeing commands in output
            echo=False,
            # Large buffer for output
            maxread=65536,
        )

        # Set unique prompt marker
        # PS1 format: <<<PROMPT>>>
        ps1_cmd = f'PS1="{self.PROMPT_MARKER}"\n'
        self._process.send(ps1_cmd)

        # Wait for first prompt
        self._process.expect_exact(self.PROMPT_MARKER)

        # Get initial working directory
        self._process.send("pwd\n")
        self._process.expect_exact(self.PROMPT_MARKER)
        pwd_output = self._process.before.strip()
        if pwd_output and pwd_output.startswith("/"):
            self._cwd = pwd_output

        self._used = True

    def _update_state_after_command(self) -> None:
        """Update working directory and exit code after command execution."""
        if not self._process:
            return

        # Get exit code using echo $?
        self._process.send("echo $?\n")
        self._process.expect_exact(self.PROMPT_MARKER)
        exit_code_output = self._process.before.strip()
        try:
            self._exit_code = int(exit_code_output)
        except ValueError:
            # If we can't parse, keep previous exit code
            pass

        # Get working directory using pwd
        self._process.send("pwd\n")
        self._process.expect_exact(self.PROMPT_MARKER)
        pwd_output = self._process.before.strip()
        if pwd_output and pwd_output.startswith("/"):
            self._cwd = pwd_output

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

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        """
        Execute a bash command.

        Args:
            cmd: The command to execute

        Returns:
            Response with combined stdout/stderr output and success status

        Notes:
            - First command initializes bash process
            - Commands block until completion (no timeout)
            - Exit code 0 indicates success
            - Output truncated at 10MB limit
            - Working directory and exit code tracked automatically
        """
        try:
            # Start process on first command
            if self._process is None:
                self._start_process()

            # Send command
            command = cmd.value
            self._process.send(command + "\n")

            # Wait for prompt marker (this blocks indefinitely if command doesn't complete)
            self._process.expect_exact(self.PROMPT_MARKER)

            # Get output (everything before the prompt marker)
            output = self._process.before.strip()

            # Check output size and truncate if needed
            if len(output) > self.MAX_OUTPUT_SIZE:
                output = output[: self.MAX_OUTPUT_SIZE]
                output += (
                    f"\n\n[WARNING: Output truncated at {self.MAX_OUTPUT_SIZE} bytes]"
                )

            # Update state (exit code, working directory, background jobs)
            self._update_state_after_command()
            self._update_background_jobs()

            # Success based on exit code
            success = self._exit_code == 0

            return CommandResponse(output=output, success=success)

        except pexpect.EOF:
            return CommandResponse(
                output="Bash process terminated unexpectedly", success=False
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
        Get current bash environment state.

        Returns:
            Screen section showing working directory, exit code, background jobs, and help

        Format:
            Working directory: /home/user/project
            Last exit code: 0
            Background jobs: [1] 1234 ./server

            Any bash command. Use & for background jobs.
        """
        # Build screen content
        lines = []

        if self._used:
            lines.append(f"Working directory: {self._cwd}")
            lines.append(f"Last exit code: {self._exit_code}")

            # Add background jobs if any
            if self._background_jobs:
                lines.append("Background jobs:")
                for job in self._background_jobs:
                    lines.append(f"  {job}")
            else:
                lines.append("Background jobs: none")

            # Add blank line before help
            lines.append("")

        # Always show help text (freeform environment)
        lines.append("Any bash command. Use & for background jobs.")

        content = "\n".join(lines)
        return ScreenSection(content=content, max_lines=50)

    def shutdown(self) -> None:
        """Clean up bash process."""
        if self._process:
            try:
                # Try graceful shutdown first
                self._process.send("exit\n")
                self._process.expect(pexpect.EOF, timeout=2)
            except (pexpect.TIMEOUT, pexpect.EOF):
                # Force kill if graceful shutdown fails
                pass
            finally:
                # Ensure process is terminated
                if self._process.isalive():
                    self._process.terminate(force=True)
                self._process = None
