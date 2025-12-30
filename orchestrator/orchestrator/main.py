"""Main orchestrator entry point.

This is the minimal orchestrator that supports only the bash environment.
It provides early validation of the architecture before implementing the
full orchestrator with environment loading and multiple environments.
"""

import sys
import types
from typing import NoReturn

from orchestrator.communication import (
    ParseError,
    read_message,
    send_error_response,
    send_response,
)
from orchestrator.core_types import EnvironmentName
from orchestrator.environments.bash import BashEnvironment
from orchestrator.executor import UnknownEnvironmentError, execute_command
from orchestrator.screen import collect_screen_updates


def main() -> NoReturn:
    """
    Main orchestrator interaction loop.

    This minimal version hardcodes the bash environment and does not
    support environment loading or multiple environments.

    Protocol:
        1. Read NDJSON command from stdin
        2. Execute command in appropriate environment
        3. Collect screen updates from all environments
        4. Send NDJSON response to stdout
        5. Repeat until EOF

    On EOF, cleanly shuts down all environments and exits.
    """
    # Initialize hardcoded bash environment
    bash_env = BashEnvironment()
    environments = types.MappingProxyType({EnvironmentName("bash"): bash_env})

    try:
        # Main interaction loop
        while True:
            # Read command from stdin
            try:
                message = read_message()
            except ParseError as e:
                # Send error response and continue
                send_error_response(f"Parse error: {e}")
                continue

            # EOF - shutdown and exit
            if message is None:
                break

            # Execute command
            try:
                response = execute_command(message.env, message.command, environments)
            except UnknownEnvironmentError as e:
                # Send error response and continue
                send_error_response(str(e))
                continue

            # Collect screen updates
            screen = collect_screen_updates(environments)

            # Send response
            send_response(response, screen)

    finally:
        # Shutdown environments
        for env in environments.values():
            try:
                env.shutdown()
            except Exception as e:
                # Log error but continue shutdown
                print(f"Error during shutdown: {e}", file=sys.stderr)

    # Exit cleanly
    sys.exit(0)


if __name__ == "__main__":
    main()
