"""Integration tests for the sandbox script.

These tests verify that the sandbox script:
1. Spawns correctly and communicates via NDJSON
2. Provides proper filesystem isolation
3. Has required packages available
4. Handles cleanup properly

Protocol format:
    Request: {"env": "bash", "command": "ls"}
    Response: {"response": {"output": "...", "success": true}, "screen": {...}}
"""

import json
import os
import subprocess
import tempfile
from pathlib import Path


def test_sandbox_spawns_and_responds():
    """Test that sandbox spawns and responds to bash command."""
    # Get sandbox script path from environment (set by Nix test derivation)
    sandbox_path = os.environ.get("SANDBOX_SCRIPT")
    assert sandbox_path, "SANDBOX_SCRIPT environment variable not set"
    assert Path(sandbox_path).exists(), f"Sandbox script not found: {sandbox_path}"

    # Create temporary project directory
    with tempfile.TemporaryDirectory() as project_dir:
        # Spawn sandbox
        proc = subprocess.Popen(
            [sandbox_path, project_dir],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            # Send simple bash command (echo)
            cmd = json.dumps({"env": "bash", "command": "echo hello"}) + "\n"
            proc.stdin.write(cmd)
            proc.stdin.flush()

            # Read response
            response_line = proc.stdout.readline()
            assert response_line, "No response from sandbox"

            data = json.loads(response_line)
            assert "response" in data, f"Response missing 'response' field: {data}"
            assert "screen" in data, f"Response missing 'screen' field: {data}"

            response = data["response"]
            assert response["processed"] is True, f"Command failed: {response}"
            assert (
                "hello" in response["output"]
            ), f"Expected 'hello' in output: {response['output']}"

            # Verify screen has expected environments
            screen = data["screen"]
            assert "bash" in screen, "Screen missing bash section"

        finally:
            # Cleanup: send EOF and wait
            proc.stdin.close()
            proc.wait(timeout=5)


def test_sandbox_bash_execution():
    """Test that sandbox can execute bash commands."""
    sandbox_path = os.environ.get("SANDBOX_SCRIPT")
    assert sandbox_path, "SANDBOX_SCRIPT environment variable not set"

    with tempfile.TemporaryDirectory() as project_dir:
        # Create a test file in project directory
        test_file = Path(project_dir) / "test.txt"
        test_file.write_text("Hello from host\n")

        proc = subprocess.Popen(
            [sandbox_path, project_dir],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            # Execute bash command to list files
            bash_cmd = json.dumps({"env": "bash", "command": "ls -la"}) + "\n"
            proc.stdin.write(bash_cmd)
            proc.stdin.flush()

            # Read response
            response_line = proc.stdout.readline()
            data = json.loads(response_line)
            response = data["response"]

            assert response["processed"] is True, f"Bash command failed: {response}"
            output = response["output"]

            # Verify test.txt is visible (we're in /workspace which is mounted from project_dir)
            assert "test.txt" in output, f"test.txt not found in output: {output}"

            # Execute bash command to read file
            read_cmd = json.dumps({"env": "bash", "command": "cat test.txt"}) + "\n"
            proc.stdin.write(read_cmd)
            proc.stdin.flush()

            response_line = proc.stdout.readline()
            data = json.loads(response_line)
            response = data["response"]

            assert response["processed"] is True, f"Read command failed: {response}"
            assert (
                "Hello from host" in response["output"]
            ), f"File content not found: {response['output']}"

        finally:
            proc.stdin.close()
            proc.wait(timeout=5)


def test_sandbox_filesystem_isolation():
    """Test that sandbox has proper filesystem isolation."""
    sandbox_path = os.environ.get("SANDBOX_SCRIPT")
    assert sandbox_path, "SANDBOX_SCRIPT environment variable not set"

    with tempfile.TemporaryDirectory() as project_dir:
        proc = subprocess.Popen(
            [sandbox_path, project_dir],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            # Test 1: Verify we're in /workspace
            pwd_cmd = json.dumps({"env": "bash", "command": "pwd"}) + "\n"
            proc.stdin.write(pwd_cmd)
            proc.stdin.flush()

            response_line = proc.stdout.readline()
            data = json.loads(response_line)
            response = data["response"]

            assert response["processed"] is True
            assert "/workspace" in response["output"], "Not in /workspace"

            # Test 2: Verify /nix/store is accessible (read-only)
            nix_cmd = (
                json.dumps({"env": "bash", "command": "ls /nix/store | head -5"}) + "\n"
            )
            proc.stdin.write(nix_cmd)
            proc.stdin.flush()

            response_line = proc.stdout.readline()
            data = json.loads(response_line)
            response = data["response"]

            assert response["processed"] is True
            # Should have some content (Nix store entries)
            assert len(response["output"].strip()) > 0, "/nix/store appears empty"

            # Test 3: Verify /tmp is writable (tmpfs)
            # Writing to /tmp should work (it's a tmpfs mount in sandbox)
            write_cmd = (
                json.dumps(
                    {
                        "env": "bash",
                        "command": "touch /tmp/test-file && ls /tmp/test-file",
                    }
                )
                + "\n"
            )
            proc.stdin.write(write_cmd)
            proc.stdin.flush()

            response_line = proc.stdout.readline()
            data = json.loads(response_line)
            response = data["response"]

            assert response["processed"] is True
            # Should successfully create file in /tmp
            assert (
                "/tmp/test-file" in response["output"]
            ), f"Should be able to write to /tmp: {response['output']}"

        finally:
            proc.stdin.close()
            proc.wait(timeout=5)


def test_sandbox_python_environment():
    """Test that Python environment works in sandbox."""
    sandbox_path = os.environ.get("SANDBOX_SCRIPT")
    assert sandbox_path, "SANDBOX_SCRIPT environment variable not set"

    with tempfile.TemporaryDirectory() as project_dir:
        proc = subprocess.Popen(
            [sandbox_path, project_dir],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            # Execute Python code
            python_cmd = json.dumps({"env": "python", "command": "print(2 + 2)"}) + "\n"
            proc.stdin.write(python_cmd)
            proc.stdin.flush()

            response_line = proc.stdout.readline()
            data = json.loads(response_line)
            response = data["response"]

            assert response["processed"] is True, f"Python command failed: {response}"
            assert "4" in response["output"], f"Unexpected output: {response['output']}"

        finally:
            proc.stdin.close()
            proc.wait(timeout=5)


def test_sandbox_required_packages_available():
    """Test that required packages are available in sandbox."""
    sandbox_path = os.environ.get("SANDBOX_SCRIPT")
    assert sandbox_path, "SANDBOX_SCRIPT environment variable not set"

    with tempfile.TemporaryDirectory() as project_dir:
        proc = subprocess.Popen(
            [sandbox_path, project_dir],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            # Check for essential commands
            required_commands = ["bash", "python", "ls", "cat", "ps"]

            for cmd in required_commands:
                check_cmd = (
                    json.dumps({"env": "bash", "command": f"which {cmd}"}) + "\n"
                )
                proc.stdin.write(check_cmd)
                proc.stdin.flush()

                response_line = proc.stdout.readline()
                data = json.loads(response_line)
                response = data["response"]

                assert (
                    response["processed"] is True
                ), f"Failed to check for {cmd}: {response}"
                assert (
                    len(response["output"].strip()) > 0
                ), f"Command {cmd} not found in PATH"

        finally:
            proc.stdin.close()
            proc.wait(timeout=5)


def test_sandbox_process_isolation():
    """Test that sandbox has process isolation (separate PID namespace)."""
    sandbox_path = os.environ.get("SANDBOX_SCRIPT")
    assert sandbox_path, "SANDBOX_SCRIPT environment variable not set"

    with tempfile.TemporaryDirectory() as project_dir:
        proc = subprocess.Popen(
            [sandbox_path, project_dir],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            # List processes - should only see sandbox processes
            ps_cmd = json.dumps({"env": "bash", "command": "ps aux"}) + "\n"
            proc.stdin.write(ps_cmd)
            proc.stdin.flush()

            response_line = proc.stdout.readline()
            data = json.loads(response_line)
            response = data["response"]

            assert response["processed"] is True, f"ps command failed: {response}"

            # Should see Python process (orchestrator) - it shows as /nix/store/...python
            # Process listing is isolated, so we check for a small number of processes
            output = response["output"]

            # Look for Python or bash processes (the minimal set in sandbox)
            assert (
                "/nix/store" in output or "bash" in output
            ), f"Expected sandbox processes not found: {output}"

            # Process list should be relatively small (not showing host processes)
            # This is a heuristic - if we see > 50 processes, isolation likely failed
            # Count only data lines (skip header)
            process_count = len(
                [
                    line
                    for line in output.split("\n")
                    if line and not line.startswith("USER")
                ]
            )
            assert (
                process_count < 20
            ), f"Too many processes ({process_count}), isolation may have failed"

        finally:
            proc.stdin.close()
            proc.wait(timeout=5)


def test_sandbox_clean_shutdown():
    """Test that sandbox shuts down cleanly when stdin is closed."""
    sandbox_path = os.environ.get("SANDBOX_SCRIPT")
    assert sandbox_path, "SANDBOX_SCRIPT environment variable not set"

    with tempfile.TemporaryDirectory() as project_dir:
        proc = subprocess.Popen(
            [sandbox_path, project_dir],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        # Send a command to verify it's alive
        cmd = json.dumps({"env": "bash", "command": "echo test"}) + "\n"
        proc.stdin.write(cmd)
        proc.stdin.flush()

        response_line = proc.stdout.readline()
        assert response_line, "Sandbox didn't respond"

        # Close stdin and verify process exits
        proc.stdin.close()
        return_code = proc.wait(timeout=5)

        # Process should exit cleanly (0 or EOF-related code)
        # The orchestrator exits with 0 on EOF
        assert return_code in [
            0,
            None,
        ], f"Sandbox didn't exit cleanly: return code {return_code}"


def test_sandbox_screen_command():
    """Test that screen shows current state."""
    sandbox_path = os.environ.get("SANDBOX_SCRIPT")
    assert sandbox_path, "SANDBOX_SCRIPT environment variable not set"

    with tempfile.TemporaryDirectory() as project_dir:
        proc = subprocess.Popen(
            [sandbox_path, project_dir],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            # Execute a bash command first
            bash_cmd = (
                json.dumps({"env": "bash", "command": "echo 'test output'"}) + "\n"
            )
            proc.stdin.write(bash_cmd)
            proc.stdin.flush()

            response_line = proc.stdout.readline()
            data = json.loads(response_line)

            # Check that screen is returned
            assert "screen" in data, "Response missing 'screen' field"
            screen = data["screen"]
            assert isinstance(screen, dict), "Screen should be a dict"

            # Should have bash section
            assert "bash" in screen, "Screen missing bash section"
            bash_section = screen["bash"]
            assert "content" in bash_section, "Bash section missing content"

            # The bash screen shows working directory and status, not command history
            # This is expected behavior - screen shows current state, not output
            assert (
                "Working directory:" in bash_section["content"]
                or "workspace" in bash_section["content"]
            ), f"Bash screen should show working directory: {bash_section['content']}"

        finally:
            proc.stdin.close()
            proc.wait(timeout=5)
