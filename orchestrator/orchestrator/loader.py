"""Environment loading and validation.

This module handles loading built-in and ad-hoc environments,
validates environment classes, and provides diagnostic error messages.
"""

import importlib.util
import inspect
import sys
import traceback
import types
from pathlib import Path
from typing import Any

from orchestrator.core_types import (
    CommandResponse,
    EnvironmentName,
    ScreenSection,
)
from orchestrator.protocol import Environment


class EnvironmentValidationError(Exception):
    """Raised when an environment class fails validation."""

    pass


def load_all_environments(
    project_dir: Path,
) -> types.MappingProxyType[EnvironmentName, Environment]:
    """
    Load built-in and ad-hoc environments.

    Args:
        project_dir: Root directory of the project

    Returns:
        Immutable mapping of environment names to environment instances

    This function:
    1. Loads built-in environments (bash, python, editor)
    2. Loads ad-hoc environments from project_dir/env/
    3. Validates each ad-hoc environment before loading
    4. Logs validation errors to stderr but continues loading other environments

    Examples:
        >>> from pathlib import Path
        >>> envs = load_all_environments(Path("/tmp/project"))
        >>> EnvironmentName("bash") in envs
        True
        >>> EnvironmentName("python") in envs
        True
        >>> EnvironmentName("editor") in envs
        True
    """
    environments: dict[EnvironmentName, Environment] = {}

    # Load built-in environments
    from orchestrator.environments.bash import BashEnvironment
    from orchestrator.environments.editor import EditorEnvironment
    from orchestrator.environments.python import PythonEnvironment

    environments[EnvironmentName("bash")] = BashEnvironment()
    environments[EnvironmentName("python")] = PythonEnvironment()
    environments[EnvironmentName("editor")] = EditorEnvironment(project_dir)

    # Load ad-hoc environments from project_dir/env/
    env_dir = project_dir / "env"
    if env_dir.exists() and env_dir.is_dir():
        for module_path in env_dir.glob("*.py"):
            name = module_path.stem

            # Skip __init__.py and other special files
            if name.startswith("_"):
                continue

            try:
                # Load module
                spec = importlib.util.spec_from_file_location(
                    f"adhoc_env.{name}", module_path
                )
                if spec is None or spec.loader is None:
                    print(
                        f"Error loading environment '{name}': Could not load module",
                        file=sys.stderr,
                    )
                    continue

                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)

                # Find environment class
                env_class = find_environment_class(module)
                if env_class is None:
                    print(
                        f"Error loading environment '{name}': "
                        f"No environment class found in {module_path}",
                        file=sys.stderr,
                    )
                    continue

                # Validate environment class
                errors = validate_environment_class(env_class)
                if errors:
                    print(
                        f"Error loading environment '{name}': Validation failed",
                        file=sys.stderr,
                    )
                    for error in errors:
                        print(f"  - {error}", file=sys.stderr)
                    continue

                # Instantiate environment
                environments[EnvironmentName(name)] = env_class()
                print(f"Loaded ad-hoc environment: {name}", file=sys.stderr)

            except Exception as e:
                print(f"Error loading environment '{name}': {e}", file=sys.stderr)
                traceback.print_exc(file=sys.stderr)

    return types.MappingProxyType(environments)


def find_environment_class(module: Any) -> type | None:
    """
    Find the environment class in a module.

    Looks for a class that implements the Environment protocol.
    Returns the first matching class found, or None if no match.

    Args:
        module: Module to search for environment class

    Returns:
        Environment class if found, None otherwise

    Examples:
        >>> import orchestrator.environments.bash as bash_module
        >>> env_class = find_environment_class(bash_module)
        >>> env_class is not None
        True
        >>> env_class.__name__
        'BashEnvironment'
    """
    # Look for classes that have handle_command and get_screen methods
    for name, obj in inspect.getmembers(module, inspect.isclass):
        # Skip classes that are clearly not environments
        if name.startswith("_"):
            continue

        # Check if class has required methods
        if hasattr(obj, "handle_command") and hasattr(obj, "get_screen"):
            return obj

    return None


def validate_environment_class(env_class: type) -> list[str]:
    """
    Validate that a class implements the Environment protocol correctly.

    Checks:
    1. Has handle_command method with correct signature
    2. Has get_screen method with correct signature
    3. Has shutdown method (optional) with correct signature if present
    4. Methods have correct type annotations

    Args:
        env_class: Class to validate

    Returns:
        List of validation error messages (empty if valid)

    Examples:
        >>> from orchestrator.environments.bash import BashEnvironment
        >>> errors = validate_environment_class(BashEnvironment)
        >>> len(errors)
        0
    """
    errors = []

    # Check for handle_command method
    if not hasattr(env_class, "handle_command"):
        errors.append("Missing required method: handle_command")
    else:
        # Check signature
        method = getattr(env_class, "handle_command")
        sig = inspect.signature(method)

        # Should have 2 parameters: self and cmd
        params = list(sig.parameters.values())
        if len(params) != 2:
            errors.append(
                f"handle_command should have 2 parameters (self, cmd), got {len(params)}"
            )
        elif params[1].name != "cmd":
            errors.append(
                f"handle_command second parameter should be named 'cmd', got '{params[1].name}'"
            )

        # Check return type annotation
        if sig.return_annotation == inspect.Signature.empty:
            errors.append("handle_command missing return type annotation")
        elif sig.return_annotation != CommandResponse:
            # Allow string annotations
            if (
                not isinstance(sig.return_annotation, str)
                or "CommandResponse" not in sig.return_annotation
            ):
                errors.append(
                    f"handle_command should return CommandResponse, got {sig.return_annotation}"
                )

    # Check for get_screen method
    if not hasattr(env_class, "get_screen"):
        errors.append("Missing required method: get_screen")
    else:
        # Check signature
        method = getattr(env_class, "get_screen")
        sig = inspect.signature(method)

        # Should have 1 parameter: self
        params = list(sig.parameters.values())
        if len(params) != 1:
            errors.append(
                f"get_screen should have 1 parameter (self), got {len(params)}"
            )

        # Check return type annotation
        if sig.return_annotation == inspect.Signature.empty:
            errors.append("get_screen missing return type annotation")
        elif sig.return_annotation != ScreenSection:
            # Allow string annotations
            if (
                not isinstance(sig.return_annotation, str)
                or "ScreenSection" not in sig.return_annotation
            ):
                errors.append(
                    f"get_screen should return ScreenSection, got {sig.return_annotation}"
                )

    # Check for shutdown method (optional)
    if hasattr(env_class, "shutdown"):
        method = getattr(env_class, "shutdown")
        sig = inspect.signature(method)

        # Should have 1 parameter: self
        params = list(sig.parameters.values())
        if len(params) != 1:
            errors.append(f"shutdown should have 1 parameter (self), got {len(params)}")

        # Check return type annotation (should be None)
        if sig.return_annotation != inspect.Signature.empty:
            if sig.return_annotation not in (None, type(None)):
                # Allow string annotations
                if (
                    not isinstance(sig.return_annotation, str)
                    or sig.return_annotation != "None"
                ):
                    errors.append(
                        f"shutdown should return None, got {sig.return_annotation}"
                    )

    return errors
