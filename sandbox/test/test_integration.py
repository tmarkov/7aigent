"""
Integration tests for the 7aigent sandbox kernel.

These tests start the full sandbox (requires nix build .#sandbox and
gvisor/runsc with KVM available), connect with jupyter_client, and
verify end-to-end behaviour.

Requirements tested:
  S2  — default runsc mode has no network access
  S6  — two OS threads: interrupt works during tight eval loop
  S8  — ZMQ IPC transport: kernel is reachable via Unix sockets
  S10a — readonly sandbox state mount rejects writes from inside the sandbox
  S11 — .git metadata is read-only from inside the sandbox
  S13 — kernel starts without runtime package installation
  S17 — runtime directory is removed after shutdown
  S18 — interrupt_request raises InterruptException and recovers
  S19 — kernel accepts new requests after interrupt
  S20 — child process is killed when eval is interrupted
"""

from dataclasses import dataclass
import json
import subprocess
import time
from pathlib import Path

import pytest

try:
    import jupyter_client
except ImportError:
    pytest.skip("jupyter_client not installed", allow_module_level=True)

REPO_ROOT = Path(__file__).parent.parent.parent
BUILT_LAUNCHER = REPO_ROOT / "result" / "bin" / "7aigent-sandbox"


@dataclass
class RunningKernel:
    client: jupyter_client.BlockingKernelClient
    process: subprocess.Popen
    runtime_dir: Path


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
    (ws / ".7aigent" / "state").mkdir(parents=True)
    git_dir = ws / ".git"
    git_dir.mkdir()
    (git_dir / "HEAD").write_text("ref: refs/heads/main\n")
    return ws


@pytest.fixture(scope="module")
def running_kernel(workspace):
    """
    Start the sandbox, connect a BlockingKernelClient, yield it, then
    shut down. Scoped to module so the kernel is shared across tests.
    """
    launcher = get_launcher()

    proc = subprocess.Popen(
        [str(launcher), str(workspace)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    kernel_json_path = Path(proc.stdout.readline().strip())
    assert kernel_json_path.exists(), (
        f"kernel.json not found: {kernel_json_path}\nstderr: {proc.stderr.read()}"
    )

    time.sleep(1.0)
    if proc.poll() is not None:
        stderr = proc.stderr.read().strip()
        pytest.skip(
            "Sandbox launcher exited before the kernel became usable: "
            f"{stderr or 'runner unsupported in this environment'}"
        )

    runtime_dir = kernel_json_path.parent.parent
    conn = json.loads(kernel_json_path.read_text())
    host_sockets_dir = kernel_json_path.parent

    conn["ip"] = str(host_sockets_dir / "kernel")
    tmp_conn = host_sockets_dir / "kernel-host.json"
    tmp_conn.write_text(json.dumps(conn))

    km = jupyter_client.BlockingKernelClient(connection_file=str(tmp_conn))
    km.load_connection_file()
    km.start_channels()

    try:
        km.wait_for_ready(timeout=30)
    except Exception:
        if proc.poll() is not None:
            stderr = proc.stderr.read().strip()
            pytest.skip(
                "Sandbox launcher exited before the kernel became alive: "
                f"{stderr or 'runner unsupported in this environment'}"
            )
        proc.terminate()
        pytest.fail("Kernel did not become ready within 30 seconds")

    yield RunningKernel(client=km, process=proc, runtime_dir=runtime_dir)

    km.shutdown()
    km.stop_channels()
    proc.wait(timeout=10)
    assert not runtime_dir.exists(), f"runtime directory leaked: {runtime_dir}"


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

        if msg.get("parent_header", {}).get("msg_id") != msg_id:
            continue

        mt = msg["msg_type"]
        if mt in ("execute_result", "display_data"):
            result_text += msg["content"]["data"].get("text/plain", "")
        elif mt == "stream":
            result_text += msg["content"]["text"]
        elif mt == "error":
            error_text = "\n".join(msg["content"]["traceback"])
        elif mt == "status" and msg["content"]["execution_state"] == "idle":
            break

    return result_text, error_text


# ── S8, S11, S13: basic connectivity and policy ─────────────────────────────

class TestBasicExecution:
    def test_simple_arithmetic(self, running_kernel):
        """S8: kernel evaluates expressions and returns results."""
        result, err = execute_and_collect(running_kernel.client, "1 + 1")
        assert err == "", f"Unexpected error: {err}"
        assert "2" in result

    def test_variable_persists_across_cells(self, running_kernel):
        """Variables defined in one cell are accessible in subsequent cells."""
        execute_and_collect(running_kernel.client, "sandbox_test_var = 42")
        result, err = execute_and_collect(running_kernel.client, "sandbox_test_var")
        assert err == ""
        assert "42" in result

    def test_codetree_available(self, running_kernel):
        """S13: CodeTree.jl is pre-loaded and importable offline."""
        result, err = execute_and_collect(
            running_kernel.client, "using CodeTree; true"
        )
        assert err == "", f"CodeTree not available: {err}"
        assert "true" in result.lower()

    def test_git_metadata_is_readonly(self, running_kernel):
        """S11: writes to .git fail from inside the sandbox."""
        result, err = execute_and_collect(
            running_kernel.client,
            """
            try
                open(".git/HEAD", "w") do io
                    write(io, "tamper")
                end
                "writable"
            catch
                "read-only"
            end
            """,
        )
        assert err == ""
        assert "read-only" in result

    def test_state_dir_is_readonly(self, running_kernel):
        """S10a: writes to .7aigent/state fail from inside the sandbox."""
        result, err = execute_and_collect(
            running_kernel.client,
            """
            try
                open(".7aigent/state/test-write", "w") do io
                    write(io, "tamper")
                end
                "writable"
            catch
                "read-only"
            end
            """,
        )
        assert err == ""
        assert "read-only" in result

    def test_network_isolated(self, running_kernel):
        """S2: the default runsc sandbox cannot reach the network."""
        result, err = execute_and_collect(
            running_kernel.client,
            """
            success(pipeline(ignorestatus(`ping -c 1 1.1.1.1`), stdout=devnull, stderr=devnull))
            """,
        )
        assert err == ""
        assert "false" in result.lower()


# ── S18, S19, S20: interrupt handling ───────────────────────────────────────

class TestInterrupt:
    def test_interrupt_tight_loop(self, running_kernel):
        """
        S6, S18, S19: submitting an infinite tight loop, then sending
        interrupt_request, must cause the kernel to recover and accept
        new requests.
        """
        km = running_kernel.client

        km.execute("while true; end")
        time.sleep(1.0)
        km.interrupt_kernel()

        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                km.get_iopub_msg(timeout=0.5)
            except Exception:
                break

        result, err = execute_and_collect(km, "1 + 1", timeout=15)
        assert "2" in result, (
            f"Kernel did not recover after interrupt. result={result!r} err={err!r}"
        )

    def test_interrupt_external_process(self, running_kernel):
        """
        S20: interrupt_request must also kill a child process spawned with run().
        After the interrupt the kernel must recover (S19).
        """
        km = running_kernel.client

        km.execute("run(`sleep 300`)")
        time.sleep(1.0)
        km.interrupt_kernel()

        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                km.get_iopub_msg(timeout=0.5)
            except Exception:
                break

        result, err = execute_and_collect(km, "2 + 2", timeout=15)
        assert "4" in result, (
            f"Kernel did not recover after interrupting child process. "
            f"result={result!r} err={err!r}"
        )
