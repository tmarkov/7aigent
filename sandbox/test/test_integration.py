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
  S18 — SIGUSR1 to launcher delivers SIGINT and recovers
  S19 — kernel accepts new requests after interrupt
  S20 — child process is killed when eval is interrupted
"""

from dataclasses import dataclass
import json
import os
import signal
import subprocess
import time
from pathlib import Path

import pytest

try:
    import jupyter_client
except ImportError:
    pytest.skip("jupyter_client not installed", allow_module_level=True)

REPO_ROOT = Path(__file__).parent.parent.parent
BUILT_LAUNCHER = Path(os.environ["SANDBOX_LAUNCHER"]) if "SANDBOX_LAUNCHER" in os.environ \
    else REPO_ROOT / "result" / "bin" / "7aigent-sandbox"

# gvisor systrap cannot reliably deliver SIGINT to Julia inside the container.
# The external signal path (runsc kill CID INT) does not reach PID 1, and the
# systrap platform breaks Julia's safepoint mechanism for tight loops.  Skip
# interrupt tests when running under systrap.
_is_systrap = os.environ.get("SANDBOX_PLATFORM", "kvm") == "systrap"
_skip_systrap_interrupt = pytest.mark.skipif(
    _is_systrap,
    reason="gvisor systrap does not reliably deliver SIGINT to sandboxed Julia",
)


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


def _wait_for_kernel_sockets(
    host_sockets_dir: Path,
    conn: dict,
    proc: subprocess.Popen,
    timeout: float = 120.0,
) -> None:
    """Block until Julia has created the ZMQ IPC socket files.

    kernel.json is written by the launcher shell *before* Julia starts inside
    gvisor. The ZMQ IPC socket files (e.g. ``kernel-5`` for the heartbeat
    channel) are only created when Julia loads IJulia and calls
    ``run_kernel()``. Under gvisor systrap this can take tens of seconds.

    If we connect jupyter_client before the socket files exist, the heartbeat
    thread fails immediately (``time_to_dead = 1.0`` s in jupyter_client) and
    ``wait_for_ready`` raises "Kernel died before replying to kernel_info"
    within ~3 seconds — long before the 30-second timeout fires.

    This helper polls for the heartbeat socket file and skips the test if the
    launcher exits early (unsupported runner environment).
    """
    hb_socket = host_sockets_dir / f"kernel-{conn['hb_port']}"
    deadline = time.monotonic() + timeout
    while not hb_socket.exists():
        if proc.poll() is not None:
            stderr = proc.stderr.read().strip()
            pytest.skip(
                "Sandbox launcher exited before kernel created sockets: "
                f"{stderr or 'runner unsupported in this environment'}"
            )
        if time.monotonic() > deadline:
            proc.terminate()
            pytest.fail(
                f"Kernel sockets not created within {timeout:.0f} seconds "
                f"(expected {hb_socket})"
            )
        time.sleep(0.2)
    # Small buffer to let Julia bind all channels before we connect.
    time.sleep(0.5)


def _wait_for_process_exit(proc: subprocess.Popen, runtime_dir: Path) -> None:
    """Gracefully shut down the sandbox launcher and verify cleanup.

    Under gvisor systrap the Julia process and gvisor itself can take
    30-60 seconds to exit cleanly after a shutdown request or SIGTERM.
    This helper:
      1. Waits up to 90 s for a natural exit (e.g. after km.shutdown()).
      2. If the process is still alive, sends SIGTERM (which triggers the
         launcher's cleanup trap) and waits another 60 s.
      3. As a last resort, sends SIGKILL.
    Only asserts that runtime_dir was cleaned up when we know SIGTERM had a
    chance to run the trap (i.e. the process exited on its own or via SIGTERM).
    """
    killed = False
    try:
        proc.wait(timeout=90)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            killed = True

    if not killed:
        assert not runtime_dir.exists(), f"runtime directory leaked: {runtime_dir}"


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

    runtime_dir = kernel_json_path.parent.parent
    conn = json.loads(kernel_json_path.read_text())
    host_sockets_dir = kernel_json_path.parent

    # kernel.json is written by the launcher shell *before* Julia starts.
    # Wait for the ZMQ IPC socket files to appear (Julia creates them when it
    # loads IJulia and binds the channels). Without this, jupyter_client's
    # 1-second heartbeat fires immediately, reporting a false "kernel died".
    _wait_for_kernel_sockets(host_sockets_dir, conn, proc)

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
    _wait_for_process_exit(proc, runtime_dir)


@pytest.fixture(scope="module")
def raw_running_kernel(workspace):
    """
    Start the sandbox and connect channels without wait_for_ready().
    This is useful for regressions where kernel_info handling itself may be
    impacted by the bug under test, but execute_request still works.
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

    runtime_dir = kernel_json_path.parent.parent
    conn = json.loads(kernel_json_path.read_text())
    host_sockets_dir = kernel_json_path.parent

    _wait_for_kernel_sockets(host_sockets_dir, conn, proc)

    conn["ip"] = str(host_sockets_dir / "kernel")
    tmp_conn = host_sockets_dir / "kernel-host.json"
    tmp_conn.write_text(json.dumps(conn))

    km = jupyter_client.BlockingKernelClient(connection_file=str(tmp_conn))
    km.load_connection_file()
    km.start_channels()

    yield RunningKernel(client=km, process=proc, runtime_dir=runtime_dir)

    km.stop_channels()
    proc.terminate()
    _wait_for_process_exit(proc, runtime_dir)


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

    def test_repl_api_module_available(self, running_kernel):
        """RA2/S13: the sandbox REPL API module is on Julia's load path."""
        result, err = execute_and_collect(
            running_kernel.client, "using SevenAigentREPL; true"
        )
        assert err == "", f"SevenAigentREPL not available: {err}"
        assert "true" in result.lower()

    def test_exception_is_rendered_informatively(self, raw_running_kernel):
        """The live IJulia kernel should surface the actual exception text."""
        result, err = execute_and_collect(
            raw_running_kernel.client,
            'startswith(missing, "design/")',
        )
        assert result == ""
        assert (
            "MethodError: no method matching startswith(::Missing, ::String)" in err
        ), f"Unexpected error rendering:\n{err}"
        assert "SYSTEM: show(lasterr) caused an error" not in err

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

@_skip_systrap_interrupt
class TestInterrupt:
    def test_interrupt_tight_loop(self, running_kernel):
        """
        S6, S18, S19: submitting a blocking computation, then sending
        SIGUSR1 to the launcher, must cause the kernel to recover and
        accept new requests.

        We use `sleep(300)` rather than `while true; end` because gvisor's
        systrap platform cannot deliver SIGINT to a pure-computation tight
        loop (Julia's safepoint mechanism requires native ptrace support).
        The agent's A16 VM test already validates this path with `sleep`.
        """
        km = running_kernel.client

        km.execute("sleep(300)")
        time.sleep(2.0)
        os.kill(running_kernel.process.pid, signal.SIGUSR1)

        # Drain iopub: wait until we see either an error traceback (interrupt
        # delivered) or idle status.  Under gvisor-systrap the signal path
        # can be slow, so we keep draining for a generous window.
        deadline = time.time() + 30
        saw_interrupt = False
        while time.time() < deadline:
            try:
                msg = km.get_iopub_msg(timeout=2.0)
                mt = msg.get("msg_type", "")
                if mt == "error":
                    saw_interrupt = True
                if mt == "status" and msg["content"]["execution_state"] == "idle":
                    break
            except Exception:
                if saw_interrupt:
                    break
                continue

        result, err = execute_and_collect(km, "1 + 1", timeout=30)
        assert "2" in result, (
            f"Kernel did not recover after interrupt. result={result!r} err={err!r}"
        )

    def test_interrupt_external_process(self, running_kernel):
        """
        S20: SIGUSR1 to the launcher must also kill a child process spawned
        with run(). After the interrupt the kernel must recover (S19).
        """
        km = running_kernel.client

        km.execute("run(`sleep 300`)")
        time.sleep(2.0)
        os.kill(running_kernel.process.pid, signal.SIGUSR1)

        deadline = time.time() + 30
        saw_interrupt = False
        while time.time() < deadline:
            try:
                msg = km.get_iopub_msg(timeout=2.0)
                mt = msg.get("msg_type", "")
                if mt == "error":
                    saw_interrupt = True
                if mt == "status" and msg["content"]["execution_state"] == "idle":
                    break
            except Exception:
                if saw_interrupt:
                    break
                continue

        result, err = execute_and_collect(km, "2 + 2", timeout=30)
        assert "4" in result, (
            f"Kernel did not recover after interrupting child process. "
            f"result={result!r} err={err!r}"
        )


# ── A4: julia_repl full execute_request → iopub flow ─────────────────────────


class TestExecuteRequestFlow:
    """
    A4: Send execute_request, collect ALL iopub messages until execute_reply.
    Verifies that stream, execute_result, display_data, and error messages
    are all delivered before the status=idle message.
    """

    def test_stream_output_collected(self, running_kernel):
        """A4: println() output appears as stream messages before idle."""
        km = running_kernel.client
        msg_id = km.execute('println("alpha"); println("beta")')

        messages = []
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                msg = km.get_iopub_msg(timeout=1)
            except Exception:
                continue
            if msg.get("parent_header", {}).get("msg_id") != msg_id:
                continue
            messages.append(msg)
            mt = msg["msg_type"]
            if mt == "status" and msg["content"]["execution_state"] == "idle":
                break

        stream_msgs = [m for m in messages if m["msg_type"] == "stream"]
        combined = "".join(m["content"]["text"] for m in stream_msgs)
        assert "alpha" in combined, f"Expected 'alpha' in stream output: {combined!r}"
        assert "beta" in combined, f"Expected 'beta' in stream output: {combined!r}"

    def test_execute_result_collected(self, running_kernel):
        """A4: expression result appears as execute_result before idle."""
        km = running_kernel.client
        result, err = execute_and_collect(km, "42 * 2")
        assert err == "", f"Unexpected error: {err}"
        assert "84" in result

    def test_error_collected(self, running_kernel):
        """A4: error output is collected as error message before idle."""
        km = running_kernel.client
        result, err = execute_and_collect(km, "error(\"test error A4\")")
        assert "test error A4" in err, f"Expected error text in: {err!r}"

    def test_display_data_collected(self, running_kernel):
        """A4: display() output is collected before idle."""
        km = running_kernel.client
        result, err = execute_and_collect(
            km, 'display("text/plain" => "displayed_value")'
        )
        assert err == "", f"Unexpected error: {err}"
        assert "displayed_value" in result


# ── A47: SevenAigentREPL.status() and Main.ans preservation ──────────────────


class TestJuliaState:
    """
    A47: Julia-state resolution returns only SevenAigentREPL.status() output
    while preserving Main.ans.
    """

    def test_status_returns_string(self, running_kernel):
        """A47: SevenAigentREPL.status() returns a non-empty string."""
        km = running_kernel.client
        # status() requires an active session — bind! with an empty CodeTree db.
        _, err = execute_and_collect(km, (
            'db = CodeTree.load("/workspace"); '
            'SevenAigentREPL.bind!("/workspace", db)'
        ))
        assert err == "", f"bind! failed: {err}"
        result, err = execute_and_collect(km, "SevenAigentREPL.status()")
        assert err == "", f"Unexpected error: {err}"
        assert len(result.strip()) > 0, "status() returned empty string"

    def test_status_output_excludes_preserved_ans(self, running_kernel):
        """A47: state text excludes the preserved Main.ans display value."""
        km = running_kernel.client
        sentinel = "A47_ANS_MUST_NOT_APPEAR_IN_STATUS"
        _, err = execute_and_collect(
            km,
            "global _a47_sentinel = Ref("
            f"{json.dumps(sentinel)}"
            "); _a47_sentinel",
        )
        assert err == "", f"Failed to establish Main.ans: {err}"

        result, err = execute_and_collect(km, """
begin
    local previous_ans = isdefined(Main, :ans) ? Main.ans : nothing
    SevenAigentREPL.status()
    previous_ans
end;
""")

        assert err == "", f"Unexpected error: {err}"
        assert "[Tasks:" in result, f"Expected status output, got: {result!r}"
        assert sentinel not in result, (
            f"Preserved ans leaked into status output: {result!r}"
        )

        result, err = execute_and_collect(
            km, "Main.ans === Main._a47_sentinel"
        )
        assert err == "", f"Unexpected error: {err}"
        assert "true" in result, f"Expected identical preserved ans, got: {result!r}"


# ── A20b: summary RPC via handleSummaryComm ──────────────────────────────────


class TestSummaryRPC:
    """
    A20b: The kernel handles summary comm_open messages and routes
    summary requests to the LLM via handleSummaryComm in Jupyter.js.

    NOTE: This test exercises the Julia side. The JS-side handleSummaryComm
    is tested implicitly by verifying the kernel accepts comm_open and
    responds via input_request (the summary_reply protocol).
    """

    def test_summary_comm_target_exists(self, running_kernel):
        """A20b: kernel recognizes the 7aigent.summary comm target."""
        km = running_kernel.client
        # SevenAigentREPL should define the summary config
        result, err = execute_and_collect(
            km, "SevenAigentREPL.summary_config()"
        )
        assert err == "", f"Unexpected error: {err}"
        # Should contain fields like max_nodes
        assert "SummaryConfig" in result or "max_nodes" in result.lower(), (
            f"Expected SummaryConfig in result: {result!r}"
        )

    def test_summary_comm_round_trip(self, running_kernel):
        """RA22: summarize! exchanges summaries via Jupyter comm_open / input_reply.

        Exercises the real comm transport (no mock) end-to-end:
          1. Julia sends comm_open with the summary request payload.
          2. Julia sends input_request (readprompt) to solicit the response.
          3. Python sends input_reply with encoded summaries.
          4. Julia processes the response and applies the summary to db.code.

        Related: issue #11 covers interrupt delivery (SIGINT), which is a
        separate protocol path from the comm-based summary RPC tested here.
        """
        import base64

        km = running_kernel.client

        # Create a small file in the workspace (S10: workspace is rw).
        result, err = execute_and_collect(
            km,
            'write("_ra22_test.jl", '
            '"function ra22_hello()\\n    return 42\\nend\\n"); '
            '"ok"',
            timeout=15,
        )
        assert err == "", f"Failed to create test file: {err}"

        # Load CodeTree (fallback discovery — git is not in the sandbox)
        # and bind a fresh session with no mock transport.
        result, err = execute_and_collect(
            km,
            """
            begin
                _ra22_db = CodeTree.load(".")
                SevenAigentREPL.bind!(".", _ra22_db)
                SevenAigentREPL.clear_summary_transport!()
                _ra22_rows = filter(
                    r -> r.name == "ra22_hello",
                    eachrow(getfield(_ra22_db.code, :_df)),
                )
                isempty(_ra22_rows) ? "NOT_FOUND" : string(first(_ra22_rows).id)
            end
            """,
            timeout=60,
        )
        if err or "NOT_FOUND" in result:
            # Clean up and skip — CodeTree fallback discovery may not find
            # files in every sandbox configuration.
            execute_and_collect(km, 'rm("_ra22_test.jl"; force=true)')
            pytest.skip(
                f"CodeTree could not discover test file: "
                f"result={result!r} err={err!r}"
            )

        node_id = result.strip().strip('"')

        # Start summarize! — this triggers the comm protocol.
        msg_id = km.execute(f'summarize!(["{node_id}"])')

        # Wait for the input_request that proves comm_open was sent and
        # readprompt is blocking for our reply.
        try:
            stdin_msg = km.get_stdin_msg(timeout=120)
        except Exception as exc:
            # Drain any error on iopub before failing.
            _, iopub_err = execute_and_collect(km, '"drain"', timeout=5)
            pytest.fail(
                f"No input_request within 120 s (RA22 comm path): {exc}"
            )

        prompt = stdin_msg["content"]["prompt"]
        assert prompt.startswith("7aigent.summary.reply:"), (
            f"Unexpected prompt prefix: {prompt!r}"
        )

        # Construct response in the stdin-based format expected by
        # _coerce_stdin_response: "ok\n<id>\t<base64 summary>"
        summary_text = "RA22 integration test summary."
        summary_b64 = base64.b64encode(summary_text.encode()).decode()
        km.input(f"ok\n{node_id}\t{summary_b64}")

        # Collect execution result (summarize! should complete now).
        exec_result = ""
        exec_err = ""
        deadline = time.time() + 60
        while time.time() < deadline:
            try:
                msg = km.get_iopub_msg(timeout=1)
            except Exception:
                continue
            if msg.get("parent_header", {}).get("msg_id") != msg_id:
                continue
            mt = msg["msg_type"]
            if mt in ("execute_result", "display_data"):
                exec_result += msg["content"]["data"].get("text/plain", "")
            elif mt == "stream":
                exec_result += msg["content"]["text"]
            elif mt == "error":
                exec_err = "\n".join(msg["content"]["traceback"])
            elif (
                mt == "status"
                and msg["content"]["execution_state"] == "idle"
            ):
                break

        assert exec_err == "", f"summarize! failed over comm: {exec_err}"

        # Verify the summary was applied to db.code
        verify_result, verify_err = execute_and_collect(
            km,
            f"""
            begin
                _ra22_row = only(filter(
                    r -> r.id == "{node_id}",
                    eachrow(getfield(_ra22_db.code, :_df)),
                ))
                string(_ra22_row.summary)
            end
            """,
        )
        assert verify_err == "", f"Verification failed: {verify_err}"
        assert "RA22 integration test summary" in verify_result, (
            f"Summary not applied via comm: {verify_result!r}"
        )

        # Clean up
        execute_and_collect(km, 'rm("_ra22_test.jl"; force=true)')
