"""Screen module for collecting screen updates."""

import types
from typing import Mapping

from orchestrator.core_types import EnvironmentName, ScreenSection
from orchestrator.protocol import Environment


def collect_screen_updates(
    environments: Mapping[EnvironmentName, Environment],
) -> Mapping[EnvironmentName, ScreenSection]:
    """
    Collect screen updates from all environments.

    Calls get_screen() on each environment. If an environment's get_screen()
    raises an exception, includes an error message in that environment's section.

    Args:
        environments: Mapping of all active environments

    Returns:
        Immutable mapping of environment names to screen sections

    Examples:
        >>> from orchestrator.environments.bash import BashEnvironment
        >>> bash_env = BashEnvironment()
        >>> envs = {EnvironmentName("bash"): bash_env}
        >>> screen = collect_screen_updates(envs)
        >>> EnvironmentName("bash") in screen
        True
        >>> isinstance(screen[EnvironmentName("bash")], ScreenSection)
        True
    """
    sections = {}

    for env_name, env in environments.items():
        try:
            sections[env_name] = env.get_screen()
        except Exception as e:
            error_msg = f"Error getting screen: {type(e).__name__}: {e}"
            sections[env_name] = ScreenSection(content=error_msg)

    return types.MappingProxyType(sections)
