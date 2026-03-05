"""Tests for orchestrator."""

import functools
import signal


# Timeout decorator for tests that interact with subprocess
# Prevents hanging tests from blocking test suite
def timeout(seconds):
    """Decorator to add timeout to test functions.

    Uses SIGALRM to enforce timeout. Only works on Unix-like systems.

    Args:
        seconds: Maximum number of seconds test can run

    Raises:
        TimeoutError: If test exceeds timeout
    """

    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            def timeout_handler(signum, frame):
                raise TimeoutError(f"Test {func.__name__} exceeded {seconds}s timeout")

            # Set alarm
            old_handler = signal.signal(signal.SIGALRM, timeout_handler)
            signal.alarm(seconds)
            try:
                return func(*args, **kwargs)
            finally:
                # Restore old handler and cancel alarm
                signal.alarm(0)
                signal.signal(signal.SIGALRM, old_handler)

        return wrapper

    return decorator
