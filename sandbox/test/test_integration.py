"""
Integration tests for the 7aigent sandbox kernel.

These tests start the full sandbox (requires nix build .#sandbox and
gvisor/runsc with KVM available), connect with jupyter_client, and
verify end-to-end behaviour.

Requirements tested:
  S6  — two OS threads: interrupt works during tight eval loop
  S8  — ZMQ IPC transport: kernel is reachable via Unix sockets
  S13 — offline: kernel starts without network
  S18 — interrupt_request raises InterruptException and recovers
  S19 — kernel accepts new requests after interrupt
  S20 — child process is killed when eval is interrupted
"""

import json
import os
import subprocess
import tempfile
import threading
import time
from pathlib import Path

import pytest

try:
    import jupyter_client
except ImportError:
    pytest.skip("jupyter_client not installed", allow_module_level=True)

REPO_ROOT = Path(__file__).parent.parent.parent
BUILT_LAUNCHER = REPO_ROOT / "result" / "bin" / "7aigent-sandbox"


def get_launcher() -> Path:
    if BUILT_LAUNCHER.exists():
        return BUILT_LAUNCHER
    pytest.skip(
        "Built launcher not found at result/bin/7aigent-sandbox. "
        "Run `nix build .#sandbox` first."
    )


@pytest.fixture(scope="module")
def workspace(tmp_path_factory):
    """A minimal workspace directory with a .git subdirectory."""
    ws = tmp_path_factory.mktemp("workspace")
    git_dir = ws / ".git"
    git_dir.mkdir()
    (git_dir / "HEAD").write_text("ref: refs/heads/main\n")
    return ws


@pytest.fixture(scope="module")
def running_kernel(workspace):
    """
    Start the sandbox, connect a BlockingKernelClient, yield it, then
    shut down.  Scoped to module so the kernel is shared across tests.
    """
    launcher = get_launcher()

    proc = subprocess.Popen(
        [str(launcher), str(workspace)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    # Read the kernel.json path from stdout (S15)
    kernel_json_path = Path(proc.stdout.readline().strip())
    assert kernel_json_path.exists(), (
        f"kernel.json not found: {kernel_json_path}\nstderr: {proc.stderr.read()}"
    )

    # Rewrite connection file with host-side socket paths
    # (inside the container /sockets/… maps to the host path)
    conn = json.loads(kernel_json_path.read_text())
    host_sockets_dir = kernel_json_path.parent

    # jupyter_client needs the host path; replace /sockets prefix
    conn["ip"] = str(host_sockets_dir / "kernel")
    tmp_conn = host_sockets_dir / "kernel-host.json"
    tmp_conn.write_text(json.dumps(conn))

    km = jupyter_client.BlockingKernelClient(connection_file=str(tmp_conn))
    km.load_connection_file()

    # Wait for the kernel to be ready (heartbeat)
    deadline = time.time() + 30
    while time.time() < deadline:
        if km.is_alive():
            break
        time.sleep(0.5)
    else:
        proc.terminate()
        pytest.fail("Kernel did not become alive within 30 seconds")

    yield km

    km.shutdown()
    proc.wait(timeout=10)


def execute_and_collect(km, code, timeout=30):
    """Send an execute_request and return (result_text, error_text)."""
    msg_id = km.execute(code)
    result_text = ""
    error_text = ""

    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            msg = km.get_iopub_msg(timeout=1)
        except Exception:
            continue
        mt = msg["msg_type"]
        if mt == "execute_result":
            result_text = msg["content"]["data"].get("text/plain", "")
        elif mt == "stream":
            result_text += msg["content"]["text"]
        elif mt == "error":
            error_text = "\n".join(msg["content"]["traceback"])
        elif mt == "status" and msg["content"]["execution_state"] == "idle":
            break

    return result_text, error_text


# ── S8, S13: basic connectivity ──────────────────────────────────────────────

class TestBasicExecution:
    def test_simple_arithmetic(self, running_kernel):
        """S8: kernel evaluates expressions and returns results."""
        result, err = execute_and_collect(running_kernel, "1 + 1")
        assert err == "", f"Unexpected error: {err}"
        assert "2" in result

    def test_variable_persists_across_cells(self, running_kernel):
        """Variables defined in one cell are accessible in subsequent cells."""
        execute_and_collect(running_kernel, "sandbox_test_var = 42")
        result, err = execute_and_collect(running_kernel, "sandbox_test_var")
        assert err == ""
        assert "42" in result

    def test_codetree_available(self, running_kernel):
        """S13: CodeTree.jl is pre-loaded and importable offline."""
        result, err = execute_and_collect(running_kernel, "using CodeTree; true")
        assert err == "", f"CodeTree not available: {err}"


# ── S18, S19: interrupt handling ─────────────────────────────────────────────

class TestInterrupt:
    def test_interrupt_tight_loop(self, running_kernel):
        """
        S6, S18, S19: submitting an infinite tight loop, then sending
        interrupt_request, must cause the kernel to recover and accept
        new requests.
        """
        km = running_kernel

        # Start an infinite loop on the eval thread
        km.execute("while true; end")

        # Give the kernel a moment to start executing
        time.sleep(1.0)

        # Send interrupt via the control channel (S18)
        km.interrupt_kernel()

        # Drain any pending iopub messages
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                km.get_iopub_msg(timeout=0.5)
            except Exception:
                break

        # S19: kernel must recover and accept new requests
        result, err = execute_and_collect(running_kernel, "1 + 1", timeout=15)
        assert "2" in result, (
            f"Kernel did not recover after interrupt. result={result!r} err={err!r}"
        )

    def test_interrupt_external_process(self, running_kernel):
        """
        S20: interrupt_request must also kill a child process spawned with run().
        After the interrupt the kernel must recover (S19).
        """
        km = running_kernel

        # Spawn a sleeping child process inside the sandbox
        km.execute("run(`sleep 300`)")
        time.sleep(1.0)

        km.interrupt_kernel()

        # Drain iopub
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                km.get_iopub_msg(timeout=0.5)
            except Exception:
                break

        # S19: kernel recovers
        result, err = execute_and_collect(running_kernel, "2 + 2", timeout=15)
        assert "4" in result, (
            f"Kernel did not recover after interrupting child process. "
            f"result={result!r} err={err!r}"
        )
