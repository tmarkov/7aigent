"""Environment protocol definition."""

from typing import Protocol

from orchestrator.core_types import CommandResponse, CommandText, ScreenSection


class Environment(Protocol):
    """
    Protocol that all environment modules must implement.

    Environments are stateful components that handle commands within their
    domain (bash, python, editor, etc.). They maintain state across commands
    and provide a screen section showing current state.

    ## Implementing an Environment

    To create a new environment, implement a class with these three methods:

    ```python
    from orchestrator.types import CommandText, CommandResponse, ScreenSection

    class MyEnvironment:
        def handle_command(self, cmd: CommandText) -> CommandResponse:
            # Execute command, update state, return response
            ...

        def get_screen(self) -> ScreenSection:
            # Return current state for display
            ...

        def shutdown(self) -> None:  # Optional
            # Clean up resources
            ...
    ```

    ## Built-in Environments

    The orchestrator provides three built-in environments:

    - **bash**: Execute shell commands, manage processes, file system operations
    - **python**: Python REPL with persistent namespace for data analysis
    - **editor**: View and edit files with pattern-based views

    ## Ad-hoc Environments

    Projects can define custom environments in `{project_dir}/env/*.py`:

    ```python
    # project_dir/env/timer.py

    from orchestrator.types import CommandText, CommandResponse, ScreenSection
    import time

    class TimerEnvironment:
        def __init__(self):
            self._start_time = None

        def handle_command(self, cmd: CommandText) -> CommandResponse:
            if cmd.value == "start":
                self._start_time = time.time()
                return CommandResponse("Timer started", success=True)
            elif cmd.value == "stop":
                if self._start_time is None:
                    return CommandResponse("Timer not running", success=False)
                elapsed = time.time() - self._start_time
                self._start_time = None
                return CommandResponse(f"Elapsed: {elapsed:.2f}s", success=True)
            else:
                return CommandResponse(f"Unknown command: {cmd.value}", success=False)

        def get_screen(self) -> ScreenSection:
            if self._start_time is not None:
                elapsed = time.time() - self._start_time
                status = f"Running: {elapsed:.2f}s"
            else:
                status = "Stopped"
            return ScreenSection(content=f"Timer: {status}")
    ```

    ## Design Principles

    **Synchronous execution**: Commands block until complete. This simplifies
    implementation and matches the sequential nature of agent interaction.
    Long-running tasks can use environment-specific mechanisms (bash background
    jobs, python threads) if needed.

    **Minimal screen content before use**: Environments should return minimal
    screen content (just name/description) until the first command is executed.
    This avoids cluttering the screen with information about unused environments.

    **File-based output for large data**: Environments should write large outputs
    (plots, profiling data, logs) to files in the project directory rather than
    including them in command responses or screen sections.

    **Explicit state management**: Environments maintain their own state. There
    is no automatic rollback or transaction support. The agent should use
    explicit mechanisms (git commits, checkpoints) for state management.

    ## Error Handling

    Environments should catch exceptions and return failed responses rather than
    letting exceptions propagate:

    ```python
    def handle_command(self, cmd: CommandText) -> CommandResponse:
        try:
            # Execute command
            result = self._execute(cmd.value)
            return CommandResponse(result, success=True)
        except Exception as e:
            return CommandResponse(f"Error: {e}", success=False)
    ```

    If get_screen() raises an exception, the orchestrator will show an error
    in that environment's screen section but continue operating.

    ## Performance Considerations

    `get_screen()` is called after every command (from any environment), so it
    must be fast:

    - Don't do expensive computation in get_screen()
    - Cache computed state from handle_command() if needed
    - Return quickly with current state

    ## Interactive Programs

    For wrapping interactive programs (gdb, database CLIs, etc.), use the
    `InteractiveEnvironment` base class which handles common patterns:

    ```python
    from orchestrator.interactive import InteractiveEnvironment

    class GdbEnvironment(InteractiveEnvironment):
        command = "gdb"
        prompt = r"\\(gdb\\) "
        description = "GDB debugger"
    ```

    See the orchestrator documentation for details on the InteractiveEnvironment
    base class.
    """

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        """
        Execute a command in this environment.

        This is the main entry point for command execution. The environment
        should parse the command, execute it, update internal state, and
        return a response.

        Args:
            cmd: The command to execute

        Returns:
            Response containing output and success status

        Implementation notes:
            - This method MUST be synchronous (blocking)
            - Timeouts are the environment's responsibility to implement
            - Long-running commands will block the entire interaction loop
            - Exceptions should be caught and returned as failed CommandResponse
            - Update internal state as needed for get_screen() to reflect changes

        Example:
            >>> env.handle_command(CommandText("ls -la"))
            CommandResponse(output='total 48\\ndrwxr-xr-x...', success=True)
        """
        ...

    def get_screen(self) -> ScreenSection:
        """
        Get current screen content for this environment.

        This is called after every command (from any environment) to update
        the screen display. Should return quickly with current state.

        Returns:
            Screen section showing current environment state

        Implementation notes:
            - Called frequently, must be fast (no expensive computation)
            - Content will be truncated if exceeds max_lines
            - Should show the most relevant state information
            - Return minimal content (name + description) before first use
            - Don't include large outputs - those should go to files

        Example (before first use):
            >>> env.get_screen()
            ScreenSection(content='Bash shell (ready)', max_lines=50)

        Example (after use):
            >>> env.get_screen()
            ScreenSection(content='Working directory: /home/user\\nLast exit code: 0\\n...', max_lines=50)
        """
        ...

    def shutdown(self) -> None:
        """
        Clean up resources before environment is stopped.

        Called when the orchestrator is shutting down. Use this to:
        - Kill child processes (bash shells, python REPLs)
        - Close file handles
        - Save state if needed
        - Release system resources

        This method is OPTIONAL to implement. If not provided, no cleanup
        will be performed.

        Implementation notes:
            - Should not raise exceptions (catch and log errors internally)
            - Should complete quickly (orchestrator may timeout)
            - May be called even if environment never received commands

        Example:
            >>> def shutdown(self) -> None:
            ...     if self._process:
            ...         self._process.terminate()
            ...         self._process.wait(timeout=5)
        """
        ...
