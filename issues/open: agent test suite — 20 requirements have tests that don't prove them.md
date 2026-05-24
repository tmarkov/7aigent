# Agent test suite: 20 requirements have tests that don't prove them

## Summary

A full audit of the `agent/` test suite reveals that 20 out of 57
requirements have tests that **pass without proving the requirement is
satisfied**. An additional 4 requirements have no tests at all. The dominant
cause is structural: tests cover pure decision functions in `Programs/*.purs`
while the effectful service code that actually performs the actions
(`Services/*.js`) has zero test coverage.

## Verdicts

| Verdict | Count | Meaning |
|---------|-------|---------|
| PASS | 33 | Tests pass ⟹ requirement is reasonably satisfied |
| WEAK | 20 | Tests exist but passing does NOT prove the requirement |
| UNTESTED | 4 | No tests cover this requirement at all |

## Anti-patterns identified

| # | Anti-pattern | Occurrences in WEAK |
|---|---|---|
| 6 | Pure Proxy for Effectful Requirement | 18 |
| 1 | Decision not Outcome | 12 |
| 4 | One Instance of Universal | 2 |
| 2 | Content not under Requirement | 2 |
| 5 | One Failure Mode of Many | 2 |
| 3 | Internal Round-trip not External Format | 1 |

## WEAK requirements (tests exist but don't prove them)

| Req | Summary | Anti-patterns | Gap |
|-----|---------|---------------|-----|
| A1 | ReACT loop | 1, 6 | Tests `reactStep` ADT return; actual loop orchestration untested |
| A2 | Startup orchestration | 1, 6 | Tests `advanceStartup` state machine; actual spawning/connecting untested |
| A3 | Tool definitions | 4 | Tests static schema; tool dispatch never tested |
| A4 | julia_repl execution | 4, 6 | Tests `collectOutput` concatenation; ZMQ communication untested |
| A7 | LLM streaming | 1, 6 | One test checks content availability; actual SSE streaming untested |
| A8 | Tool output display | 6 | Tests `processToolOutput`; actual terminal rendering untested |
| A10 | Concurrent keyboard | 1, 6 | Tests state machine accepts events; actual threading untested |
| A11 | Escape key | 1, 6 | Tests `handleEscape` actions; actual cancellation/interrupt delivery untested |
| A12 | SIGINT | 1, 6 | Tests `handleSigint` actions; actual signal handling and exit untested |
| A15 | Timeout check request | 2, 6 | Tests message content; actual separate LLM call untested |
| A16 | Timeout yes → interrupt | 1, 6 | Tests `interpretTimeoutResponse`; actual interrupt delivery untested |
| A18 | Retry with backoff | 1, 6 | Tests `retryDecision`; actual HTTP retry loop untested |
| A19 | Julia startup | 1, 6 | Tests phase transitions; actual kernel execution untested |
| A20 | Startup error → exit | 1, 5, 6 | Tests Abort return; actual process exit untested (historical bug) |
| A20a | Sandbox crash | 1, 6 | Tests Abort return; actual crash detection untested |
| A26 | Log event fields | 3 | Round-trip tests pass even with wrong field names |
| A28 | Serialization snippet | 2, 6 | Tests generated string content; actual kernel execution untested |
| A31 | Session resume | 6 | Tests history reconstruction; actual kernel restore untested |
| A32 | Deserialization failure | 5, 6 | Tests file presence; actual per-binding failure untested |
| A43 | MCP server | 1, 6 | Tests pure helpers; actual HTTP/MCP protocol untested |

## UNTESTED requirements (no tests at all)

| Req | Summary | What's missing |
|-----|---------|---------------|
| A20b | Summary RPC | `Jupyter.js` `handleSummaryComm` — zero coverage |
| A47 | Julia state resolution | `SevenAigentREPL.status()` execution, `Main.ans` preservation |
| A48 | Round lifecycle | Turn succession, reflection triggering, max_turns enforcement |
| A49 | Reflection call construction | Building the reflection prompt with conversation + template |

## Root cause

The codebase separates pure decision logic (`src/Agent/Programs/`) from
effectful service code (`src/Agent/Services/` + JS FFI). The test suite
exhaustively covers the pure layer but has **zero coverage** of the effectful
layer. This means:

- The decision "what to do" is always tested
- The execution "actually doing it" is never tested
- Historical bugs (7315873, fc50061, kernel connection issues) all lived in
  the untested effectful layer

## Specific examples of the failure mode

**A20 (startup error → exit):** The test proves `advanceStartup` returns
`Abort`. The actual bug (commit 7315873) was that `Session.purs` received
`Abort` and didn't exit. The test passed throughout.

**A26 (log event fields):** Tests prove `decode(encode(x)) == x`. The actual
bug (commit fc50061) was that the wire format sent to the LLM used wrong field
names. Both encoder and decoder used the same wrong name, so round-trip passed.

**A4 (julia_repl):** Tests prove `collectOutput` concatenates messages
correctly. Historical bugs in `Jupyter.js` (wrong ZMQ address, dropped
messages, race conditions) were all in untested code.

## Recommendations

1. **Controller integration test harness** — drive mock kernel + mock LLM
   through a full turn. Would cover A1, A2, A7, A10–A12, A19, A20, A48.

2. **Wire-format assertions for A26** — assert specific JSON field names in
   encoded output against the requirement table.

3. **Kernel interaction tests for A4, A20b, A47** — extend sandbox/test/
   pytest suite to cover the runner's kernel communication.

4. **Reflection round tests for A48, A49** — test controller logic that chains
   turns with a mock LLM returning controlled reflection JSON.

5. **Do NOT add content-pinning tests** — prompt/template text that isn't
   under requirement should not be asserted on (anti-pattern 2).

---
---

# Appendix: Full Audit Report

## Detailed Findings: PASS (tests properly prove the requirement)

| Req | Summary | Test File |
|-----|---------|-----------|
| A2a | Config file placement | ConfigSpec |
| A2b | Git trust-state check | SandboxPreflightSpec |
| A2c | Git metadata kind reporting | SandboxPreflightSpec |
| A2d | Conflict resolution prompt | SandboxPreflightSpec |
| A5 | git_diff output | GitDiffSpec |
| A6 | git_commit execution | GitCommitSpec |
| A9 | Output threshold truncation | OutputThresholdSpec |
| A13 | EOF ≡ SIGINT | InterruptionSpec |
| A14 | Timeout schedule | TimeoutSpec |
| A17 | Timeout no → reschedule | TimeoutSpec |
| A21 | Template substitution | TemplateSpec |
| A22 | Placeholder values | TemplateSpec |
| A23 | Unknown keyword → error | TemplateSpec |
| A24 | Session directory allocation | SessionLogSpec |
| A25 | Log file format | SessionLogSpec |
| A27 | Session description | SessionLogSpec |
| A29 | Julia defs extraction | JuliaDefsSpec |
| A30 | Pure definition classification | JuliaDefsSpec |
| A33 | Compaction trigger | CompactionSpec + ReactStepSpec |
| A34 | Compaction plan building | CompactionSpec |
| A35 | Compaction templates | TemplateSpec |
| A36 | Compaction call properties | CompactionSpec |
| A37 | Config fields | ConfigSpec |
| A37a | Per-turn token limit | ReactStepSpec |
| A38 | API key from env | ConfigSpec |
| A39 | Missing config fields | ConfigSpec |
| A40 | Start session CLI | CLISpec |
| A41 | Sessions listing | SessionListingSpec + CLISpec |
| A42 | Resume CLI | CLISpec |
| A44 | Workspace override | CLISpec |
| A45 | Steering keywords | SteeringSpec + CLISpec |
| A46 | Steering injection condition | SteeringSpec |
| A50 | Reflection response parsing | ReflectionSpec |

**Why these pass:** Each requirement describes behaviour that is fully
captured in a testable pure function or in an effectful test that exercises
real system resources (filesystem, git, env vars). When these tests pass, the
requirement is satisfied.

---

## Detailed Findings: WEAK (per-requirement analysis)

### A1 — ReACT Loop (AP 1, 6)

**Requirement:** The runner sends conversation to LLM, streams the response,
executes tool calls, loops.

**What's tested:** `reactStep` returns `ExecuteTool`, `PromptUser`,
`CompactThenPromptUser`, etc. based on the LLM response shape.

**Gap:** The actual loop orchestration — sending HTTP requests, streaming
token-by-token, executing tools, appending results, looping — is never tested.
The test proves the decision function is correct, not that the runner follows
those decisions.

---

### A2 — Startup Orchestration (AP 1, 6)

**Requirement:** Runner validates config, spawns sandbox, reads kernel.json,
connects, executes startup expressions — in that order.

**What's tested:** `advanceStartup` pure state machine transitions.

**Gap:** Does not test actual ordering, sandbox spawning, kernel.json reading,
or ZMQ connection.

---

### A3 — Tool Definitions (AP 4)

**Requirement:** Three tools with specified names and parameters.

**What's tested:** Static count (3), parameter names, required flags.

**Gap:** Tests structure, not that calling these tools actually dispatches to
the right handler. A tool definition could have the right schema but map to
the wrong implementation.

---

### A4 — julia_repl Execution (AP 4, 6)

**Requirement:** Send execute_request, collect ALL stream/execute_result/
display_data/error messages until execute_reply.

**What's tested:** `collectOutput` concatenation of pre-constructed
`IopubMessage` values.

**Gap:** Message routing from ZMQ, execute_request construction, waiting for
execute_reply, handling out-of-order messages — all in `Jupyter.js` with zero
coverage.

---

### A7 — LLM Streaming (AP 1, 6)

**Requirement:** Responses streamed token-by-token as generated.

**What's tested:** One test verifies `response.content` is accessible
alongside tool calls.

**Gap:** Actual SSE/streaming parsing, terminal output rendering, and
incremental display are untested.

---

### A8 — Tool Output Display (AP 6)

**Requirement:** Runner displays first 5 lines (within threshold) or error
message (above threshold).

**What's tested:** `processToolOutput` returns correct `displayText`.

**Gap:** Test proves the display text is computed correctly but not that it's
actually rendered to the terminal. However, since the controller code is
trivial (print the string), this is a mild gap.

---

### A10 — Concurrent Keyboard Input (AP 1, 6)

**Requirement:** Runner reads keyboard on a dedicated thread, concurrently.

**What's tested:** State machine accepts events in any state.

**Gap:** Actual thread creation, concurrent delivery, and race conditions are
untested.

---

### A11 — Escape Key Behaviour (AP 1, 6)

**Requirement:** Cancel LLM request, send interrupt_request to kernel, send
SIGINT to host process.

**What's tested:** `handleEscape` returns the right `ControllerAction` ADT
values and log events.

**Gap:** Actual HTTP cancellation, ZMQ interrupt delivery, and process
signalling are untested.

---

### A12 — SIGINT Behaviour (AP 1, 6)

**Requirement:** Cancel in-flight request, interrupt running tool, serialize
state, write session_end, exit.

**What's tested:** `handleSigint` returns correct actions and log events.
"\n[interrupted]" marker tested.

**Gap:** Actual signal handling, process exit, state serialization execution.

---

### A15 — Timeout Check Request (AP 2, 6)

**Requirement:** Separate LLM request not appended to history, containing
source + elapsed + partial output + yes/no question.

**What's tested:** `buildTimeoutCheckRequest` message contains expected
substrings.

**Gap:** Does not test that the request is actually sent as a separate call
or that it's not appended to history. String assertions on message content
are mild anti-pattern 2.

---

### A16 — Timeout Yes → Interrupt (AP 1, 6)

**Requirement:** Send interrupt_request, return output + [interrupted].

**What's tested:** `interpretTimeoutResponse "Yes..."` returns `Interrupt`.

**Gap:** Actual interrupt delivery and output handling untested.

---

### A18 — Retry with Backoff (AP 1, 6)

**Requirement:** Retry on 429/5xx/timeout, exponential backoff, re-prompt on
exhaustion.

**What's tested:** `retryDecision` returns Retry/GiveUp based on status code
and attempt count. Backoff growth tested.

**Gap:** Actual HTTP retry loop, delay implementation, re-prompting, and
session state preservation on exhaustion.

---

### A19 — Julia Startup Sequence (AP 1, 6)

**Requirement:** Execute "using CodeTree" then startup.jl in the kernel.

**What's tested:** `advanceStartup` phase transitions.

**Gap:** Actual kernel execution and output capture.

---

### A20 — Startup Error → Exit (AP 1, 5, 6)

**Requirement:** Print error and exit with non-zero status.

**What's tested:** `advanceStartup` returning `Abort`.

**Gap:** Runner actually exiting. Historical bug: runner received Abort but
didn't exit. The pure test couldn't catch this.

---

### A20a — Sandbox Crash (AP 1, 6)

**Requirement:** Detect closed socket/failed heartbeat, write session_end,
exit.

**What's tested:** `advanceStartup RunningSession (Left SandboxCrashed)`
returns Abort.

**Gap:** Actual crash detection mechanism untested.

---

### A26 — Log Event Types and Fields (AP 3)

**Requirement:** Specific JSON field names per the table
(e.g. `tool_call_id`, `elapsed_seconds`).

**What's tested:** `decodeLogEvent(encodeLogEvent(event)) == event` for all
types.

**Gap:** Only proves internal consistency. If encoder and decoder both use
`"toolCallId"` instead of `"tool_call_id"`, the round-trip passes but the
log file violates the spec. No test asserts on the actual JSON field names.

---

### A28 — Serialization Snippet (AP 2, 6)

**Requirement:** Execute a snippet that iterates names(Main), serializes
each binding, writes to file.

**What's tested:** `buildSerializationSnippet` string contains expected
substrings ("names(Main", "Serialization.serialize", etc.).

**Gap:** Tests generated code content (anti-pattern 2). Does not test that
the snippet actually works when executed in a real kernel.

---

### A31 — Session Resume (AP 6)

**Requirement:** Spawn sandbox, startup, replay defs, restore state,
reconstruct history.

**What's tested:** `reconstructHistory` (log → conversation), file detection,
datetime re-substitution.

**Gap:** Actual kernel reconnection, def replay execution, state
deserialization in running kernel.

---

### A32 — Deserialization Failure (AP 5, 6)

**Requirement:** Failed globals are skipped, session continues.

**What's tested:** `loadSessionForResume` detects file presence.

**Gap:** Only tests file-system level (file present/absent). Does not test
actual per-binding deserialization failure in a running kernel.

---

### A43 — MCP Server Mode (AP 1, 6)

**Requirement:** HTTP server, single "run" tool, independent sessions,
progress notifications every 15s.

**What's tested:** `buildMcpRunConfig`, `handleMcpResult`, `isProgressDue`,
`extractFinalMessage` pure functions.

**Gap:** Actual HTTP server binding, MCP protocol handling, session isolation,
progress notification emission.

---

## Anti-Pattern Definitions

### Anti-Pattern 1: Testing the Decision, Not the Outcome

The test calls a pure function that returns an ADT value (Abort, ExecuteTool,
PromptUser). The requirement specifies an observable outcome (process exits,
LLM receives a request, tool executes). The decision could be correct while
the calling code ignores it.

### Anti-Pattern 2: Testing Content That Isn't Under Requirement

The test asserts on specific strings or values that no requirement specifies.
When these incidental details change, the test breaks without protecting any
requirement.

### Anti-Pattern 3: Testing Internal Serialization, Not Requirement Behaviour

The test verifies `decode(encode(x)) == x` but cannot catch cases where the
encoding doesn't match what external consumers expect.

### Anti-Pattern 4: Testing One Instance of a Universal Claim

The requirement says "all X" but the test exercises one specific X.

### Anti-Pattern 5: Testing One Failure Mode of Many

The requirement specifies failure behaviour but the test only models one
specific failure path via mock injection.

### Anti-Pattern 6: Pure Function Test as Proxy for Effectful Requirement

The requirement describes something the runner does (connects, sends, writes).
The test imports a pure function from Programs/ and tests its logic. The
effectful code in Services/ (JS FFI) is never tested.
