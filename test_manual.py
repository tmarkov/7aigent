#!/usr/bin/env python3
"""Manual integration test for full orchestrator with all environments."""

import json
import os
import subprocess
import sys
from pathlib import Path


def test_orchestrator():
    """Test orchestrator end-to-end with all environments."""
    # Set project directory so orchestrator can find ad-hoc environments
    project_dir = Path(__file__).parent
    env = {**os.environ, "PROJECT_DIR": str(project_dir)}

    # Start orchestrator process
    proc = subprocess.Popen(
        [sys.executable, "-m", "orchestrator"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd="/home/todor/dev/7aigent/orchestrator",
        env=env,
    )

    tests = [
        ("Test 1: Bash - Echo command", {"env": "bash", "command": "echo hello world"}),
        ("Test 2: Bash - PWD command", {"env": "bash", "command": "pwd"}),
        ("Test 3: Bash - True command", {"env": "bash", "command": "true"}),
        (
            "Test 4: Bash - False command (should fail)",
            {"env": "bash", "command": "false"},
        ),
        ("Test 5: Python - Simple expression", {"env": "python", "command": "2 + 2"}),
        (
            "Test 6: Python - Variable assignment",
            {"env": "python", "command": "x = 42"},
        ),
        (
            "Test 7: Editor - View file",
            {
                "env": "editor",
                "command": "view README.md start:# 7aigent end:## Development",
            },
        ),
        ("Test 8: Timer - Start", {"env": "timer", "command": "start"}),
        ("Test 9: Timer - Status", {"env": "timer", "command": "status"}),
        ("Test 10: Timer - Stop", {"env": "timer", "command": "stop"}),
    ]

    try:
        for name, cmd in tests:
            print(f"\n{'='*60}")
            print(name)
            print(f"{'='*60}")
            print(f"Sending: {json.dumps(cmd)}")

            # Send command
            proc.stdin.write(json.dumps(cmd) + "\n")
            proc.stdin.flush()

            # Read response
            response_line = proc.stdout.readline()
            if response_line:
                response = json.loads(response_line)
                print("\nResponse:")
                print(f"  Success: {response.get('response', {}).get('success')}")
                print(
                    f"  Output: {response.get('response', {}).get('output', '')[:100]}"
                )
                print("\nScreen sections:")
                for env_name, section in response.get("screen", {}).items():
                    print(f"  {env_name}:")
                    content_preview = section["content"][:150].replace("\n", "\\n")
                    print(f"    {content_preview}...")
            else:
                print("ERROR: No response received")
                break

        # Test unknown environment
        print(f"\n{'='*60}")
        print("Test 11: Unknown environment (should error)")
        print(f"{'='*60}")
        cmd = {"env": "nonexistent", "command": "test"}
        print(f"Sending: {json.dumps(cmd)}")

        proc.stdin.write(json.dumps(cmd) + "\n")
        proc.stdin.flush()

        response_line = proc.stdout.readline()
        if response_line:
            response = json.loads(response_line)
            print("\nError response:")
            print(f"  Type: {response.get('type')}")
            print(f"  Message: {response.get('message')}")

        # Show stderr for ad-hoc environment loading messages
        print(f"\n{'='*60}")
        print("Stderr output (environment loading):")
        print(f"{'='*60}")
        proc.stdin.close()
        proc.wait(timeout=5)
        stderr = proc.stderr.read()
        if stderr:
            print(stderr)

    finally:
        # Shutdown orchestrator (if not already done)
        try:
            proc.stdin.close()
        except Exception:
            pass
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
            proc.wait()

    print(f"\n{'='*60}")
    print("All manual tests complete!")
    print(f"{'='*60}")


if __name__ == "__main__":
    test_orchestrator()
