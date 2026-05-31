{ pkgs, agent, testCodebase }:
let
  common = import ./vm-common.nix { inherit pkgs; };

  workspacePath = "/tmp/workspace";

  mkConfig =
    { maxApiRetries, timeoutChecks ? "timeout_check_seconds = [3, 7, 14]", progressInterval ? "progress_interval_seconds = 2" }:
    pkgs.writeText "agent-config-${toString maxApiRetries}.toml" ''
      api_endpoint = "http://localhost:9999/v1/chat/completions"
      model = "mock-model"
      api_key_env = "TEST_API_KEY"
      output_threshold_chars = 5000
      max_api_retries = ${toString maxApiRetries}
      max_tokens_per_turn = 50000
      compaction_threshold = 100000
      preserve_initial = 50
      preserve_final = 50
      max_turns_per_round = 5
      ${timeoutChecks}
      ${progressInterval}
    '';

  defaultConfig = mkConfig { maxApiRetries = 3; };
  singleRetryConfig = mkConfig { maxApiRetries = 1; };

  systemPrompt = pkgs.writeText "system_prompt.md" ''
    You are a deterministic VM-test assistant.
    Current datetime: {{datetime}}
    Current model: {{model}}
    Initial REPL output:
    {{initial_repl_output}}
  '';

  startupJl = pkgs.writeText "startup.jl" "";

  mockLlmServer = pkgs.writeText "mock-llm-server.py" ''
    import http.server
    import json
    import re
    import sys
    import threading
    import time

    PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9999
    LOG_PATH = "/tmp/llm-requests.jsonl"

    request_lock = threading.Lock()
    retry_state = {}

    def sse_line(data):
        return f"data: {json.dumps(data)}\n\n"

    def text_response(content, input_tokens=100):
        chunks = []
        for token in content.split(" "):
            chunks.append(sse_line({
                "choices": [{"index": 0, "delta": {"content": token + " "}}]
            }))
        chunks.append(sse_line({
            "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            "usage": {
                "prompt_tokens": input_tokens,
                "completion_tokens": max(1, len(content.split(" "))),
                "prompt_tokens_details": {"cached_tokens": 0},
            },
        }))
        chunks.append("data: [DONE]\n\n")
        return "".join(chunks)

    def tool_call_response(code, input_tokens=100):
        call_id = f"call_{int(time.time() * 1000)}"
        args_json = json.dumps({"code": code})
        return "".join([
            sse_line({
                "choices": [{
                    "index": 0,
                    "delta": {
                        "tool_calls": [{
                            "index": 0,
                            "id": call_id,
                            "function": {"name": "julia_repl", "arguments": ""},
                        }]
                    },
                }]
            }),
            sse_line({
                "choices": [{
                    "index": 0,
                    "delta": {
                        "tool_calls": [{
                            "index": 0,
                            "function": {"arguments": args_json},
                        }]
                    },
                }]
            }),
            sse_line({
                "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
                "usage": {
                    "prompt_tokens": input_tokens,
                    "completion_tokens": 20,
                    "prompt_tokens_details": {"cached_tokens": 0},
                },
            }),
            "data: [DONE]\n\n",
        ])

    def reflection_response():
        return text_response('{"complete": true, "feedback": ""}')

    def append_log(entry):
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")

    def strip_control_tokens(text):
        text = re.sub(r"__RETRY_COUNT__\d+\s*", "", text)
        text = text.replace("__ALWAYS_429__", "")
        return text.strip()

    def is_steering_message(text):
        return text.lstrip().startswith("**Tokens:**")

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            content_len = int(self.headers.get("Content-Length", "0"))
            raw_body = self.rfile.read(content_len).decode("utf-8")

            try:
                payload = json.loads(raw_body)
            except json.JSONDecodeError:
                self.send_error(400, "Invalid JSON")
                return

            messages = payload.get("messages", [])
            last_user = ""
            last_tool = ""
            last_tool_index = -1
            for index, message in enumerate(messages):
                role = message.get("role")
                if role == "user":
                    last_user = message.get("content", "")
                elif role == "tool":
                    last_tool = message.get("content", "")
                    last_tool_index = index

            normalized_user = strip_control_tokens(last_user)
            non_steering_user_after_tool = False
            if last_tool_index >= 0:
                for message in messages[last_tool_index + 1:]:
                    if message.get("role") != "user":
                        continue
                    content = message.get("content", "")
                    if not is_steering_message(content):
                        non_steering_user_after_tool = True
                        break
            kind = "chat"
            if last_tool and not non_steering_user_after_tool:
                kind = "tool-continuation"
            elif "__TOOL_CALL__" in last_user:
                kind = "tool-call"
            elif "Should I interrupt this execution?" in last_user:
                kind = "timeout-check"
            elif payload.get("response_format", {}).get("type") == "json_object":
                kind = "json"

            entry = {
                "timestamp": time.time(),
                "kind": kind,
                "last_user": last_user,
                "normalized_user": normalized_user,
                "last_tool": last_tool,
                "model": payload.get("model"),
                "payload": payload,
            }
            with request_lock:
                append_log(entry)

            retry_match = re.search(r"__RETRY_COUNT__(\d+)", last_user)
            if retry_match:
                raw_key = last_user
                with request_lock:
                    retry_state.setdefault(raw_key, int(retry_match.group(1)))
                    if retry_state[raw_key] > 0:
                        retry_state[raw_key] -= 1
                        self.send_response(429)
                        self.send_header("Content-Type", "application/json")
                        self.end_headers()
                        self.wfile.write(json.dumps({
                            "error": {
                                "message": "Rate limit exceeded",
                                "type": "rate_limit_error",
                            }
                        }).encode("utf-8"))
                        return

            if "__ALWAYS_429__" in last_user:
                self.send_response(429)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({
                    "error": {
                        "message": "Persistent rate limit exceeded",
                        "type": "rate_limit_error",
                    }
                }).encode("utf-8"))
                return

            if kind == "tool-continuation":
                normalized_tool = last_tool.strip()
                body = text_response(f"FINAL_TOOL_OUTPUT: {normalized_tool}")
            elif kind == "timeout-check":
                answer = "yes" if "__INTERRUPT_YES__" in last_user else "no"
                body = text_response(answer)
            elif kind == "tool-call":
                code = last_user.split("__TOOL_CALL__", 1)[1].strip()
                body = tool_call_response(code)
            elif kind == "json":
                body = reflection_response()
            else:
                body = text_response(f"ACK: {normalized_user}")

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))

        def log_message(self, format, *args):
            pass

    if __name__ == "__main__":
        server = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
        server.serve_forever()
  '';

  mcpClient = pkgs.writeText "mcp-client.js" ''
    const sdkBase = process.env.SDK_BASE;
    if (!sdkBase) {
      throw new Error("SDK_BASE is required");
    }

    const { Client } = require(sdkBase + "/client/index.js");
    const { StreamableHTTPClientTransport } =
      require(sdkBase + "/client/streamableHttp.js");

    async function main() {
      const mode = process.argv[2];
      const url = process.argv[3];
      const message = process.argv[4];

      const client = new Client(
        { name: "vm-test-client", version: "1.0.0" },
        { capabilities: {} }
      );
      const transport = new StreamableHTTPClientTransport(new URL(url));
      const startedAt = Date.now();
      const progress = [];

      await client.connect(transport);
      try {
        if (mode === "list-tools") {
          const result = await client.listTools();
          process.stdout.write(JSON.stringify(result.tools));
        } else if (mode === "call-tool") {
          const result = await client.callTool(
            { name: "run", arguments: { message } },
            undefined,
            {
              timeout: 120000,
              resetTimeoutOnProgress: true,
              maxTotalTimeout: 180000,
              onprogress: (update) => {
                progress.push({
                  atMs: Date.now() - startedAt,
                  progress: update.progress,
                  message: update.message,
                });
              },
            }
          );
          process.stdout.write(JSON.stringify({ result, progress }));
        } else {
          throw new Error("Unknown mode: " + mode);
        }
      } finally {
        await transport.close();
      }
    }

    main().catch((error) => {
      console.error(error);
      process.exit(1);
    });
  '';

  workspaceSetup = common.prepareWorkspaceCommand {
    inherit testCodebase;
    destination = workspacePath;
  };
in
pkgs.testers.nixosTest {
  name = "7aigent-agent-e2e";

  skipTypeCheck = true;

  nodes.machine = common.mkNode {
    systemPackages = [
      agent
      pkgs.python3
      pkgs.curl
      pkgs.coreutils
      pkgs.procps
      pkgs.nodejs
    ];
    environmentVariables = {
      TEST_API_KEY = "test-key-12345";
      SANDBOX_PLATFORM = "systrap";
    };
  };

  testScript = ''
    import json
    import shlex
    import time

    WORKSPACE = "${workspacePath}"
    REQUEST_LOG = "/tmp/llm-requests.jsonl"
    DEFAULT_CONFIG = "${defaultConfig}"
    SINGLE_RETRY_CONFIG = "${singleRetryConfig}"
    SYSTEM_PROMPT = "${systemPrompt}"
    STARTUP_JL = "${startupJl}"
    MCP_CLIENT = "${mcpClient}"
    SDK_BASE = "${agent}/lib/7aigent/node_modules/@modelcontextprotocol/sdk/dist/cjs"

    machine.wait_for_unit("multi-user.target")

    def run(command):
        return machine.execute(command)

    def succeed(command, context):
        rc, out = run(command)
        if rc != 0:
            raise Exception(f"{context}\nCommand: {command}\nOutput:\n{out}")
        return out

    def read_file(path):
        _, out = run(f"cat {shlex.quote(path)} 2>/dev/null || true")
        return out

    def read_jsonl(path):
        text = read_file(path)
        return [json.loads(line) for line in text.splitlines() if line.strip()]

    def session_dirs():
        _, out = run(
            f"find {shlex.quote(WORKSPACE + '/.7aigent/sessions')} "
            "-mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort || true"
        )
        return [line for line in out.splitlines() if line.strip()]

    def latest_session_log():
        dirs = session_dirs()
        if not dirs:
            raise Exception("No session directories found")
        return read_jsonl(dirs[-1] + "/log.jsonl")

    def reset_workspace(config_path):
        run(f"rm -rf {shlex.quote(WORKSPACE)}")
        succeed("${workspaceSetup}", "Failed to prepare workspace")
        succeed(
            f"cp {shlex.quote(config_path)} {shlex.quote(WORKSPACE + '/.7aigent/config.toml')}",
            "Failed to install config.toml",
        )
        succeed(
            f"cp {shlex.quote(SYSTEM_PROMPT)} {shlex.quote(WORKSPACE + '/.7aigent/system_prompt.md')}",
            "Failed to install system_prompt.md",
        )
        succeed(
            f"cp {shlex.quote(STARTUP_JL)} {shlex.quote(WORKSPACE + '/.7aigent/startup.jl')}",
            "Failed to install startup.jl",
        )
        run("rm -f /tmp/*.log /tmp/*.json /tmp/*.jsonl /tmp/mcp.pid")

    def wait_for_http(url, expected_code, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            _, out = run(
                f"curl -s -o /dev/null -w '%{{http_code}}' {shlex.quote(url)} || true"
            )
            if out.strip() == str(expected_code):
                return
            machine.sleep(1)
        raise Exception(f"Timed out waiting for {url} to return HTTP {expected_code}")

    def start_mock_llm():
        run("rm -f " + shlex.quote(REQUEST_LOG))
        succeed(
            "python3 ${mockLlmServer} 9999 >/tmp/mock-llm.log 2>&1 &",
            "Failed to start mock LLM server",
        )
        deadline = time.time() + 30
        while time.time() < deadline:
            _, out = run(
                "curl -s -o /dev/null -w '%{http_code}' "
                "-X POST http://localhost:9999/v1/chat/completions "
                "-H 'Content-Type: application/json' "
                "-d 'not json' || true"
            )
            if out.strip() == "400":
                return
            machine.sleep(1)
        raise Exception("Timed out waiting for mock LLM server")

    def run_agent(prompt=None, input_lines=None, timeout_seconds=60, log_path="/tmp/agent.log"):
        run(f"rm -f {shlex.quote(log_path)}")
        if prompt is not None:
            command = (
                f"cd {shlex.quote(WORKSPACE)} && "
                f"timeout {timeout_seconds} 7aigent -p {shlex.quote(prompt)} "
                f"> {shlex.quote(log_path)} 2>&1"
            )
        else:
            escaped_lines = " ".join(shlex.quote(line) for line in input_lines)
            command = (
                f"cd {shlex.quote(WORKSPACE)} && "
                f"printf '%s\\n' {escaped_lines} | "
                f"timeout {timeout_seconds} 7aigent "
                f"> {shlex.quote(log_path)} 2>&1"
            )
        rc, _ = run(command)
        return rc, read_file(log_path)

    def request_entries(kind=None, normalized_user=None):
        entries = read_jsonl(REQUEST_LOG)
        if kind is not None:
            entries = [entry for entry in entries if entry["kind"] == kind]
        if normalized_user is not None:
            entries = [
                entry for entry in entries
                if entry.get("normalized_user") == normalized_user
            ]
        return entries

    def assert_tool_result_text(result, expected_substring):
        texts = [
            item.get("text", "")
            for item in result.get("content", [])
            if isinstance(item, dict)
        ]
        merged = "\n".join(texts)
        assert expected_substring in merged, merged
        return merged

    start_mock_llm()

    # A18: transient 429 → retry with exponential backoff and succeed.
    reset_workspace(DEFAULT_CONFIG)
    rc, out = run_agent(
        prompt="__RETRY_COUNT__2 hello after retries",
        timeout_seconds=90,
        log_path="/tmp/a18-success.log",
    )
    assert rc == 0, out
    retry_entries = request_entries(
        kind="chat",
        normalized_user="hello after retries",
    )
    assert len(retry_entries) == 3, retry_entries
    retry_gaps = [
        retry_entries[1]["timestamp"] - retry_entries[0]["timestamp"],
        retry_entries[2]["timestamp"] - retry_entries[1]["timestamp"],
    ]
    assert retry_gaps[0] >= 0.8, retry_gaps
    assert retry_gaps[1] >= 1.8, retry_gaps
    assert "ACK: hello after retries" in out, out

    # A18: exhausted retries → error shown, session continues, and prior REPL state survives.
    reset_workspace(SINGLE_RETRY_CONFIG)
    rc, out = run_agent(
        prompt=None,
        input_lines=[
            "__TOOL_CALL__x = 41; println(\"set-x\")",
            "__ALWAYS_429__ fail after state",
            "__TOOL_CALL__println(x)",
        ],
        timeout_seconds=90,
        log_path="/tmp/a18-exhausted.log",
    )
    assert rc == 0, out
    assert "LLM error:" in out, out
    assert "FINAL_TOOL_OUTPUT: set-x" in out, out
    exhausted_entries = request_entries(kind="chat")
    first_prompt_entries = [
        entry for entry in exhausted_entries
        if "__ALWAYS_429__ fail after state" in entry["last_user"]
    ]
    restored_state_entries = [
        entry for entry in request_entries(kind="tool-call")
        if "__TOOL_CALL__println(x)" in entry["last_user"]
    ]
    assert len(first_prompt_entries) == 2, first_prompt_entries
    assert len(restored_state_entries) == 1, restored_state_entries
    assert len(session_dirs()) == 1, session_dirs()
    tool_results = [
        event["output"]
        for event in latest_session_log()
        if event.get("type") == "tool_result"
    ]
    assert any("set-x" in output for output in tool_results), tool_results
    assert any("41" in output for output in tool_results), tool_results

    # A14 + A15 + A17: periodic timeout checks with preserved conversation history.
    # Config uses timeout_check_seconds = [3, 7, 14], so sleep(12) triggers all 3.
    reset_workspace(DEFAULT_CONFIG)
    timeout_prompt = (
        "__TOOL_CALL__begin; "
        "println(\"started\"); flush(stdout); sleep(12); println(\"done\"); "
        "end"
    )
    rc, out = run_agent(
        prompt=timeout_prompt,
        timeout_seconds=60,
        log_path="/tmp/a14.log",
    )
    assert rc == 0, out
    timeout_checks = request_entries(kind="timeout-check")
    assert len(timeout_checks) == 3, timeout_checks
    tool_request = request_entries(kind="tool-call")[0]
    offsets = [entry["timestamp"] - tool_request["timestamp"] for entry in timeout_checks]
    assert 1 <= offsets[0] <= 12, offsets
    check_gaps = [
        timeout_checks[1]["timestamp"] - timeout_checks[0]["timestamp"],
        timeout_checks[2]["timestamp"] - timeout_checks[1]["timestamp"],
    ]
    assert 2 <= check_gaps[0] <= 12, check_gaps
    assert 4 <= check_gaps[1] <= 16, check_gaps
    for entry in timeout_checks:
        text = entry["last_user"]
        assert "sleep(12)" in text, text
        assert "started" in text, text
        assert "Should I interrupt this execution?" in text, text
        assert entry["model"] == "mock-model", entry
    continuation = request_entries(kind="tool-continuation")[-1]
    continuation_payload = json.dumps(continuation["payload"])
    assert "Should I interrupt this execution?" not in continuation_payload, continuation_payload
    session_log = latest_session_log()
    timeout_check_events = [event for event in session_log if event.get("type") == "timeout_check"]
    timeout_response_events = [event for event in session_log if event.get("type") == "timeout_response"]
    assert len(timeout_check_events) == 3, timeout_check_events
    assert len(timeout_response_events) == 3, timeout_response_events
    assert [event["elapsed_seconds"] for event in timeout_check_events] == [3, 7, 14], timeout_check_events
    assert all(event["interrupt"] is False for event in timeout_response_events), timeout_response_events
    assert "Should I interrupt this execution?" in out, out
    assert "no" in out.lower(), out
    assert "FINAL_TOOL_OUTPUT:" in out and "done" in out, out

    # A16: "yes" timeout response interrupts execution and returns partial output.
    # First timeout check at 3s; sleep(8) keeps it alive long enough.
    reset_workspace(DEFAULT_CONFIG)
    interrupt_prompt = (
        "__TOOL_CALL__begin; "
        "println(\"partial\"); flush(stdout); sleep(8); println(\"too-late\"); "
        "end # __INTERRUPT_YES__"
    )
    rc, out = run_agent(
        prompt=interrupt_prompt,
        timeout_seconds=45,
        log_path="/tmp/a16.log",
    )
    assert rc == 0, out
    session_log = latest_session_log()
    timeout_response_events = [event for event in session_log if event.get("type") == "timeout_response"]
    assert len(timeout_response_events) >= 1, timeout_response_events
    assert any(event["interrupt"] is True for event in timeout_response_events), timeout_response_events
    tool_results = [event for event in session_log if event.get("type") == "tool_result"]
    interrupted_outputs = [event["output"] for event in tool_results if "[interrupted]" in event["output"]]
    assert interrupted_outputs, tool_results
    assert all("too-late" not in output for output in interrupted_outputs), interrupted_outputs
    assert "partial" in out and "[interrupted]" in out, out

    # A43: MCP server exposes the run tool, sends progress, isolates sessions, and returns errors.
    reset_workspace(DEFAULT_CONFIG)
    succeed(
        f"7aigent {shlex.quote(WORKSPACE)} mcp 8080 >/tmp/mcp.log 2>&1 & echo $! >/tmp/mcp.pid",
        "Failed to start MCP server",
    )
    wait_for_http("http://localhost:8080/mcp", 405, timeout=60)

    def run_mcp_client(mode, message=None):
        command = (
            f"SDK_BASE={shlex.quote(SDK_BASE)} "
            f"node {shlex.quote(MCP_CLIENT)} {shlex.quote(mode)} "
            f"{shlex.quote('http://localhost:8080/mcp')}"
        )
        if message is not None:
            command += " " + shlex.quote(message)
        rc, out = run(command)
        if rc != 0:
            server_log = read_file("/tmp/mcp.log")
            raise Exception(
                f"MCP client {mode} failed\n"
                f"Command: {command}\n"
                f"Output:\n{out}\n"
                f"MCP server log:\n{server_log}"
            )
        return json.loads(out)

    tools = run_mcp_client("list-tools")
    assert len(tools) == 1, tools
    tool = tools[0]
    assert tool["name"] == "run", tool
    assert tool["description"] == (
        "Run an agent task against the workspace and return the final answer."
    ), tool
    assert tool["inputSchema"]["required"] == ["message"], tool
    assert tool["inputSchema"]["properties"]["message"]["type"] == "string", tool

    existing_sessions = len(session_dirs())
    slow_result = run_mcp_client(
        "call-tool",
        "__TOOL_CALL__begin; println(\"mcp-slow\"); flush(stdout); sleep(5); println(\"mcp-done\"); end",
    )
    assert slow_result["result"].get("isError") is False, slow_result
    slow_text = assert_tool_result_text(slow_result["result"], "mcp-done")
    assert "FINAL_TOOL_OUTPUT:" in slow_text, slow_text
    assert slow_result["progress"], slow_result
    assert slow_result["progress"][0]["progress"] == 2, slow_result
    assert slow_result["progress"][0]["atMs"] >= 1500, slow_result
    assert len(session_dirs()) == existing_sessions + 1, session_dirs()
    slow_session_log = latest_session_log()
    logged_types = [event.get("type") for event in slow_session_log]
    assert "session_start" in logged_types, logged_types
    assert "session_end" in logged_types, logged_types

    run_mcp_client("call-tool", "__TOOL_CALL__x = 41; println(\"set-x\")")
    isolation_result = run_mcp_client(
        "call-tool",
        "__TOOL_CALL__println(isdefined(Main, :x))",
    )
    isolation_text = assert_tool_result_text(isolation_result["result"], "false")
    assert "FINAL_TOOL_OUTPUT:" in isolation_text, isolation_text

    failure_result = run_mcp_client("call-tool", "__ALWAYS_429__ mcp failure")
    assert failure_result["result"].get("isError") is True, failure_result
    failure_text = assert_tool_result_text(failure_result["result"], "Session error")
    assert "LLM error" in failure_text or "LlmApiError" in failure_text, failure_text

    run("kill $(cat /tmp/mcp.pid) >/dev/null 2>&1 || true")
  '';
}
