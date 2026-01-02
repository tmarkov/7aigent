"""Timer environment for testing ad-hoc environment loading.

This is a simple example environment that demonstrates the Environment protocol.
It maintains a timer that can be started and stopped.
"""

import time

from orchestrator.core_types import CommandResponse, CommandText, ScreenSection


class TimerEnvironment:
    """Simple timer environment for testing.

    Commands:
        start - Start the timer
        stop - Stop the timer and show elapsed time
        reset - Reset the timer
        status - Show current timer status

    Screen shows current timer state (running or stopped) and elapsed time.
    """

    def __init__(self):
        """Initialize timer environment."""
        self._start_time: float | None = None
        self._elapsed: float = 0.0
        self._running: bool = False

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        """Execute timer command.

        Args:
            cmd: Command to execute

        Returns:
            Response with command result
        """
        command = cmd.value.strip().lower()

        if command == "start":
            if self._running:
                return CommandResponse("Timer is already running", success=False)

            self._start_time = time.time()
            self._running = True
            return CommandResponse("Timer started", success=True)

        elif command == "stop":
            if not self._running:
                return CommandResponse("Timer is not running", success=False)

            elapsed = time.time() - self._start_time  # type: ignore
            self._elapsed += elapsed
            self._running = False
            self._start_time = None
            return CommandResponse(
                f"Timer stopped. Elapsed: {elapsed:.2f}s", success=True
            )

        elif command == "reset":
            self._start_time = None
            self._elapsed = 0.0
            self._running = False
            return CommandResponse("Timer reset", success=True)

        elif command == "status":
            if self._running:
                elapsed = time.time() - self._start_time  # type: ignore
                total = self._elapsed + elapsed
                return CommandResponse(
                    f"Timer running. Current: {elapsed:.2f}s, Total: {total:.2f}s",
                    success=True,
                )
            else:
                return CommandResponse(
                    f"Timer stopped. Total: {self._elapsed:.2f}s", success=True
                )

        else:
            return CommandResponse(
                f"Unknown command: {cmd.value!r}. "
                f"Available commands: start, stop, reset, status",
                success=False,
            )

    def get_screen(self) -> ScreenSection:
        """Get current timer state for screen display.

        Returns:
            Screen section showing timer state
        """
        if self._running:
            elapsed = time.time() - self._start_time  # type: ignore
            total = self._elapsed + elapsed
            status = (
                f"Timer (running)\n  Current: {elapsed:.2f}s\n  Total: {total:.2f}s"
            )
        else:
            status = f"Timer (stopped)\n  Total: {self._elapsed:.2f}s"

        return ScreenSection(content=status, max_lines=10)

    def shutdown(self) -> None:
        """Clean up timer environment.

        Stops the timer if running.
        """
        if self._running:
            elapsed = time.time() - self._start_time  # type: ignore
            self._elapsed += elapsed
            self._running = False
            self._start_time = None
