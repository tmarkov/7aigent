"""Executor module for command routing.

This module routes commands to the appropriate environment and handles
execution errors.
"""

from typing import Mapping

from orchestrator.core_types import CommandResponse, CommandText, EnvironmentName
from orchestrator.protocol import Environment


class UnknownEnvironmentError(Exception):
    """Raised when command is sent to unknown environment."""

    pass


def execute_command(
    env_name: EnvironmentName,
    command_text: str,
    environments: Mapping[EnvironmentName, Environment],
) -> CommandResponse:
    """
    Execute a command in the specified environment.

    Routes the command to the appropriate environment and handles errors.

    Args:
        env_name: Name of environment to execute command in
        command_text: Command to execute
        environments: Mapping of available environments

    Returns:
        CommandResponse from the environment

    Raises:
        UnknownEnvironmentError: If environment name is not in environments mapping

    Examples:
        >>> from orchestrator.environments.bash import BashEnvironment
        >>> bash_env = BashEnvironment()
        >>> envs = {EnvironmentName("bash"): bash_env}
        >>> response = execute_command(
        ...     EnvironmentName("bash"),
        ...     "echo hello",
        ...     envs
        ... )
        >>> response.success
        True
        >>> "hello" in response.output
        True
    """
    # Check if environment exists
    if env_name not in environments:
        available = ", ".join(name.value for name in environments.keys())
        raise UnknownEnvironmentError(
            f"Unknown environment: {env_name.value!r}. "
            f"Available environments: {available}"
        )

    # Get environment
    env = environments[env_name]

    # Create command object
    cmd = CommandText(command_text)

    # Execute command
    # Environment is responsible for catching exceptions and returning
    # failed CommandResponse, but we'll catch any that slip through
    try:
        response = env.handle_command(cmd)
        return response
    except Exception as e:
        # This shouldn't happen (environments should catch their own exceptions),
        # but handle it gracefully just in case
        return CommandResponse(
            output=f"Internal error: {type(e).__name__}: {e}", success=False
        )
