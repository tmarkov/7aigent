"""Screen module for collecting screen updates.

This module collects screen sections from all environments and applies
truncation to stay within line limits.
"""

import types
from typing import Mapping

from orchestrator.core_types import EnvironmentName, ScreenSection
from orchestrator.protocol import Environment


def _truncate_section(section: ScreenSection) -> ScreenSection:
    """
    Truncate section content to max_lines.

    Args:
        section: Screen section to truncate

    Returns:
        New ScreenSection with truncated content if needed

    Examples:
        >>> section = ScreenSection("line1\\nline2\\nline3", max_lines=2)
        >>> truncated = _truncate_section(section)
        >>> truncated.content
        'line1\\nline2\\n... (1 more line, truncated)'
    """
    lines = section.content.split("\n")

    # Count total lines (including trailing empty line if content ends with \n)
    total_lines = len(lines)

    # If within limit, return as-is
    if total_lines <= section.max_lines:
        return section

    # Truncate and add indicator
    kept_lines = lines[: section.max_lines]
    truncated_count = total_lines - section.max_lines
    truncated_msg = (
        f"... ({truncated_count} more line, truncated)"
        if truncated_count == 1
        else f"... ({truncated_count} more lines, truncated)"
    )
    kept_lines.append(truncated_msg)

    return ScreenSection(content="\n".join(kept_lines), max_lines=section.max_lines)


def collect_screen_updates(
    environments: Mapping[EnvironmentName, Environment],
) -> Mapping[EnvironmentName, ScreenSection]:
    """
    Collect screen updates from all environments.

    Calls get_screen() on each environment and applies truncation.
    If an environment's get_screen() raises an exception, includes
    an error message in that environment's section.

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
            # Get screen section from environment
            section = env.get_screen()

            # Apply truncation
            truncated = _truncate_section(section)

            sections[env_name] = truncated

        except Exception as e:
            # Environment get_screen() failed - show error in section
            error_msg = f"Error getting screen: {type(e).__name__}: {e}"
            sections[env_name] = ScreenSection(content=error_msg, max_lines=50)

    # Return immutable mapping
    return types.MappingProxyType(sections)
