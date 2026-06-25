{ pkgs, sandbox, codeTree, testCodebase }:
let
  common = import ./vm-common.nix { inherit pkgs; };

  # This script runs inside the VM (not in the type-checked test driver).
  # It connects to the running Julia kernel and exercises all required behaviours.
  kernelTestPy = pkgs.writeText "kernel-test.py" ''
    import sys, time
    import jupyter_client

    kf = sys.argv[1]
    km = jupyter_client.BlockingKernelClient(connection_file=kf)
    km.load_connection_file()
    km.start_channels()
    time.sleep(2)

    def run(code, timeout=60, expect_error=False):
        """Execute code in the kernel; return all text output."""
        km.execute(code)
        reply = km.get_shell_msg(timeout=timeout)
        status = reply["content"]["status"]
        output = []
        while True:
            msg = km.get_iopub_msg(timeout=15)
            if msg["msg_type"] == "execute_result":
                output.append(msg["content"]["data"].get("text/plain", ""))
            elif msg["msg_type"] == "stream":
                output.append(msg["content"]["text"])
            elif msg["msg_type"] == "error":
                tb = "\n".join(msg["content"].get("traceback", []))
                output.append(f"ERROR: {msg['content'].get('ename')}: {msg['content'].get('evalue')}\n{tb}")
            elif msg["msg_type"] == "status" and msg["content"]["execution_state"] == "idle":
                break
        text = "\n".join(output)
        if expect_error:
            assert status == "error", f"Expected error but got status={status!r}; output={text!r}"
        else:
            evalue = reply["content"].get("evalue", "")
            assert status == "ok", f"Kernel error for {code!r}\n  evalue={evalue!r}\n  output={text!r}"
        return text

    # 1. Basic arithmetic
    result = run("1 + 1")
    assert "2" in result, f"Expected 2, got: {result!r}"
    print(f"PASS: 1 + 1 = {result.strip()}")

    # 2. Load CodeTree (which also loads TreeSitter and SQLite internally).
    #    The sandbox CWD is /workspace = the test-codebase copy.
    run("using CodeTree; using DataFrames")
    print("PASS: using CodeTree")

    result = run("SevenAigentREPL.status(); println(\"status ok\")")
    assert "status ok" in result, f"Expected SevenAigentREPL.status() to run, got: {result!r}"
    print("PASS: SevenAigentREPL is preloaded in Main")

    # 2b. Build the LanguageConfig (separate cell to isolate failures)
    run("""
    global config = CodeTree.LanguageConfig(Dict(
        "cpp" => CodeTree.LanguageEntry(
            Dict(
                "function_definition" => CodeTree.NodeMapping(:landmark, "function"),
                "class_specifier"     => CodeTree.NodeMapping(:landmark, "class"),
            ),
            ["(call_expression function: (identifier) @call)"],
            ["(declaration declarator: (identifier) @def)"],
        ),
        "julia" => CodeTree.LanguageEntry(
            Dict(
                "function_definition"       => CodeTree.NodeMapping(:landmark, "function"),
                "short_function_definition" => CodeTree.NodeMapping(:landmark, "function"),
                "struct_definition"         => CodeTree.NodeMapping(:landmark, "class"),
            ),
            ["(call_expression (identifier) @call)"],
            ["(assignment left: (identifier) @def)"],
        ),
        "markdown" => CodeTree.LanguageEntry(
            Dict("Header" => CodeTree.NodeMapping(:landmark, "function")),
            String[], String[],
        ),
    ), Dict(".cpp" => "cpp", ".cc" => "cpp", ".hpp" => "cpp", ".h" => "cpp",
            ".jl" => "julia", ".md" => "markdown"))
    println("config created ok")
    """)
    print("PASS: LanguageConfig created")

    # 2c. Load the codebase — global assignment avoids top-level scoping issues.
    #     Use println to bypass IJulia's display machinery (avoids stack-overflow
    #     in show when displaying large DataFrames).
    result = run("global db = CodeTree.load(pwd(), config); println(nrow(db.code))",
                 timeout=120)
    n = result.strip().splitlines()[-1].strip()
    assert n.isdigit() and int(n) > 0, f"Expected node count > 0, got: {result!r}"
    print(f"PASS: CodeTree.load indexed {n} nodes from test codebase")

    # 3. Bash command via Julia's run() — test that process spawning works
    #    inside gvisor. Output of the child process goes to the kernel's stdout.
    #    We capture it with readchomp/read and print so Python can see it.
    result = run("""
    try
        output = readchomp(`ls -la`)
        println(output)
    catch e
        err_type = string(typeof(e))
        err_msg  = hasfield(typeof(e), :msg)    ? e.msg    : ""
        err_pre  = hasfield(typeof(e), :prefix) ? e.prefix : ""
        println("SPAWN_ERROR_TYPE: ", err_type)
        println("SPAWN_ERROR_MSG: ",  err_msg)
        println("SPAWN_ERROR_PRE: ",  err_pre)
        rethrow(ErrorException("spawn test failed: " * err_type * ": " * err_msg))
    end
    """)
    assert "SPAWN_ERROR_TYPE" not in result, f"Process spawn failed:\n{result}"
    assert len(result.strip()) > 0, "ls -la produced no output"
    print(f"PASS: run(`ls -la`) succeeded (process spawning works in gvisor):\n{result.strip()[:300]}")

    # 4. Network isolation: ping 1.1.1.1 must fail inside the sandbox.
    #    We expect an error from process.jl because --network=none means no
    #    network interface is present — the ping binary will fail immediately.
    run("""run(`ping -c 1 -W 2 1.1.1.1`)""", expect_error=True)
    print("PASS: network isolated — ping 1.1.1.1 raised an error as expected")

    km.stop_channels()
    print("\nAll sandbox e2e tests passed!")
  '';
in
pkgs.testers.nixosTest {
  name = "7aigent-sandbox-e2e";

  # jupyter_client is imported inside the VM script (kernelTestPy above),
  # not in the test-driver Python that gets type-checked.
  skipTypeCheck = true;

  nodes.machine = common.mkNode {
    systemPackages = [
      (pkgs.python3.withPackages (ps: [ ps.jupyter-client ps.pytest ]))
      pkgs.gvisor
      pkgs.iputils
    ];
  };

  testScript = ''
    import shlex
    import time

    machine.wait_for_unit("multi-user.target")

    # Set up a writable copy of the test codebase as the workspace
    machine.execute("${common.prepareWorkspaceCommand { inherit testCodebase; destination = "/tmp/test-codebase"; }}")

    # Start the sandbox under runsc with systrap platform. systrap uses
    # ptrace-based syscall interception, so it works inside the QEMU VM used
    # by NixOS tests without nested KVM.
    machine.execute(
        "SANDBOX_PLATFORM=systrap ${sandbox}/bin/7aigent-sandbox /tmp/test-codebase"
        " >/tmp/sandbox.log 2>&1 </dev/null &"
    )

    # Wait for the launcher connection file, then for the heartbeat IPC socket
    # created by IJulia. kernel.json is written before Julia starts accepting
    # requests, so it is not a readiness signal by itself.
    machine.wait_for_file("/tmp/7aigent-*/sockets/kernel.json", timeout=120)
    _, kf = machine.execute("ls /tmp/7aigent-*/sockets/kernel.json | head -1")
    kf = kf.strip()
    print(f"Kernel connection file: {kf}")
    _, hb_socket = machine.execute(
        "python3 - <<'PY'\n"
        "import json\n"
        f"kf = {kf!r}\n"
        "with open(kf) as f:\n"
        "    conn = json.load(f)\n"
        "print(kf.replace('kernel.json', f\"kernel-{conn['hb_port']}\"))\n"
        "PY"
    )
    hb_socket = hb_socket.strip()
    for _ in range(180):
        rc, _ = machine.execute(f"test -e {shlex.quote(hb_socket)}")
        if rc == 0:
            break
        time.sleep(1)
    else:
        _, tree = machine.execute("find /tmp/7aigent-* -maxdepth 3 -ls 2>&1 || true")
        print("=== runtime tree ===\n" + tree)
        _, ps = machine.execute("ps -ef")
        print("=== ps ===\n" + ps)
        _, log = machine.execute("cat /tmp/sandbox.log 2>&1 || true")
        print("=== sandbox.log ===\n" + log)
        raise Exception(f"heartbeat socket did not appear: {hb_socket}")
    machine.sleep(1)

    # Run all e2e tests via the Jupyter client (inside the VM).
    # Print sandbox.log on failure for diagnosis.
    rc, _ = machine.execute(f"python3 ${kernelTestPy} {kf} 2>&1 | tee /tmp/kernel-test.log")
    if rc != 0:
        _, log = machine.execute("cat /tmp/sandbox.log")
        print("=== sandbox.log ===\n" + log)
        _, klog = machine.execute("cat /tmp/kernel-test.log")
        print("=== kernel-test.log ===\n" + klog)
        raise Exception("kernel test failed — see logs above")
    _, klog = machine.execute("cat /tmp/kernel-test.log")
    print(klog)

    # Kill the first sandbox (the pytest integration tests start their own)
    machine.execute("kill $(cat /tmp/7aigent-*/sockets/../sandbox.pid 2>/dev/null) 2>/dev/null || true")
    machine.sleep(2)

    # Run pytest integration tests (test_integration.py).
    # These start their own sandbox via the running_kernel fixture.
    rc, _ = machine.execute(
        "SANDBOX_LAUNCHER=${sandbox}/bin/7aigent-sandbox "
        "SANDBOX_PLATFORM=systrap "
        "pytest -x ${../sandbox/test/test_integration.py} "
        "2>&1 | tee /tmp/pytest-integration.log"
    )
    if rc != 0:
        _, log = machine.execute("cat /tmp/pytest-integration.log")
        print("=== pytest-integration.log ===\n" + log)
        raise Exception("pytest integration tests failed — see logs above")
    _, log = machine.execute("cat /tmp/pytest-integration.log")
    print(log)
  '';
}
