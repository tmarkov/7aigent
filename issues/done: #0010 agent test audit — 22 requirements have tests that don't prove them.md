# Agent test audit: 22 requirements have tests that don't prove them

## Summary

A strict audit of the `agent/` test suite using the criterion **"If I know
nothing about the implementation and only know these tests pass, can I
conclude the requirement is satisfied?"** yields:

| Verdict | Count |
|---------|-------|
| PASS | 34 |
| WEAK | 22 |
| UNTESTED | 1 |

The dominant gap: tests exercise pure decision functions that return an ADT
value describing what to do, but no test proves the controller actually
executes those decisions. The recently-added `ControllerSpec.purs` closes
this gap for several requirements (A1, A2, A3, A7, A8, A19, A20, A28, A31,
A47, A48) but does not yet cover the majority of the WEAK cases.

## Methodology

For each requirement:
1. Express the requirement as a **trigger → observable outcome** contract.
2. Examine the test's **input** (setup) and **assertion** (what it checks).
3. If the test's input simulates the trigger AND its assertion verifies the
   outcome → **PASS**. Otherwise → **WEAK**. No tests → **UNTESTED**.

**Exception:** Purely definitional requirements (they define WHAT a
computation must produce, not what the system does with the result) are PASS
if the test directly exercises that definition.

**No "trivial gap" reasoning.** If the test doesn't span the requirement's
full trigger→outcome, it's WEAK. This is what distinguished the previous
audit (#0006, now done) — which rated dead code as PASS — from this redo.

## Findings by pattern

### Pattern 1: Decision tested, execution not proven (19 requirements)

The test calls a pure function in `Agent.Programs.*` that returns an ADT
value (action list, decision variant, etc.), but no test proves the
controller/runner acts on the returned value.

| Req | Decision function tested | Gap |
|-----|--------------------------|-----|
| A9 | `processToolOutput` → `{truncated, llmFacing}` | Controller doesn't test large-output path |
| A11 | `handleEscape` → `{actions: [CancelLlmRequest, ...]}` | No controller test for escape |
| A12 | `handleSigint` → `{actions: [SerializeRepl, Exit, ...]}` | No controller test for SIGINT |
| A13 | `handleEof` → same as SIGINT | No controller test for EOF |
| A14 | `timeoutCheckpoints`, `isCheckDue` | Runner doesn't provably send checks |
| A15 | `buildTimeoutCheckRequest` → message array | Request not proven to be sent |
| A16 | `interpretTimeoutResponse` → `Interrupt` | Interrupt not proven to be executed |
| A17 | `interpretTimeoutResponse` → `ScheduleNext` | Next check not proven to be scheduled |
| A18 | `retryDecision` → `Retry(ms)` / `GiveUp` | Not proven to be wired into controller |
| A23 | `substituteTemplate` → `Left(error)` | Runner exit on template error not proven |
| A29 | `extractDefs(events)` → definition list | File not proven to be written |
| A33 | `shouldCompact` / `reactStep` → `ExecuteToolThenCompact` | Compaction not proven to occur |
| A34 | `buildCompactionPlan` + `applyCompaction` | LLM call + exit on failure not proven |
| A36 | `applyCompaction` result omits compaction prompt | Other properties (same model, in log) not proven |
| A37a | `reactStep` → `ExecuteToolThenEndTurn` | Turn end not proven at controller level |
| A38 | `readApiKey` → `Left` on unset/empty | Exit on failure not proven |
| A39 | `parseConfig` → `Left` + advanceStartup → `Abort` | Exit specifically on config error not proven |
| A41 | `formatSessionListing` correct | Runner doesn't provably call and display it |
| A46 | `buildSteeringMessage` → `Just(text)` when baseline>0 | Injection into LLM call not proven |

### Pattern 2: Helper functions tested for wrong scenario (1 requirement)

| Req | What's tested | Gap |
|-----|---------------|-----|
| A20a | ControllerSpec tests sandbox **spawn failure** (startup) | A20a is about **mid-session** crash (closed socket) — different scenario |

### Pattern 3: Comprehensive helper tests but no behavioral proof (2 requirements)

| Req | What's tested | Gap |
|-----|---------------|-----|
| A32 | Snippet contains `try/catch`; SessionResumeSpec: absent file → warning | No test shows: binding fails to deserialize → skipped + session continues |
| A43 | `buildMcpRunConfig`, `handleMcpResult`, `isProgressDue`, `extractFinalMessage` | No test starts an MCP server or processes HTTP requests |

### UNTESTED (1 requirement)

| Req | Description |
|-----|-------------|
| A20b | REPL summary RPC: runner services Jupyter summary requests. Only the `llm_query` log event encoding is tested. |

## What PASS looks like (for comparison)

Requirements that pass use one of two strategies:

1. **ControllerSpec integration**: runs `runNewSession`/`runResumeSession`
   with mock services, verifies observable side effects (service calls made
   in correct order with correct content). Examples: A1, A2, A3, A7, A8,
   A19, A20, A28, A31, A47, A48.

2. **Real-environment tests**: creates actual filesystem/git state, calls the
   actual function, checks the actual result. Examples: A2a–A2d (workspace
   files), A5 (real git diff), A6 (real git commit), A24 (session allocation
   with flock).

3. **Definitional requirements**: the requirement IS the computation spec, so
   testing the function IS testing the requirement. Examples: A4 (iopub
   concatenation rule), A22 (supported keywords), A26 (event field names),
   A30 (pure definition table), A44 (CLI path detection), A50 (JSON parsing
   rules).

## Recommended fix

Extend `ControllerSpec.purs` with additional test scenarios:

**High priority** (dead-code risk like A14):
- A14–A17: provide a long-running mock exec → verify timeout check LLM call
  fires at 30s
- A33–A34: provide mock LLM response with tokens > threshold → verify
  compaction LLM call fires
- A37a: provide token counts exceeding limit → verify turn ends and
  reflection fires

**Medium priority** (important user-facing behavior):
- A11–A13: inject escape/SIGINT/EOF signal → verify interrupt actions + exit
- A18: mock LLM returning 429 → verify retry then success
- A9: mock tool returning large output → verify LLM receives error text

**Lower priority** (startup edge cases and secondary modes):
- A20a: mock sandbox crash during session (not just spawn failure)
- A23/A38/A39: missing env var or bad template → verify exit(1)
- A41: exercise the sessions listing command end-to-end
- A43: MCP mode (complex, may require separate test infrastructure)
- A46: verify steering message appears in the LLM call messages

## Full per-requirement table

| Req | Verdict | Test file(s) | What test proves |
|-----|---------|--------------|------------------|
| A1 | PASS | ReactStepSpec + ControllerSpec | Loop: tool call → exec → LLM again → text → end |
| A2 | PASS | ControllerSpec | Spawn before connect before exec |
| A2a | PASS | ConfigSpec | Real FS: all 7 files + state dir placed |
| A2b | PASS | SandboxPreflightSpec | Real FS: no nogit → no conflict |
| A2c | PASS | SandboxPreflightSpec | Real FS: 4 git metadata kinds identified |
| A2d | PASS | SandboxPreflightSpec | Real FS: halt preserves nogit, proceed removes it |
| A3 | PASS | ToolDefsSpec + ControllerSpec | 3 tools defined + julia_repl dispatched |
| A4 | PASS | JupyterSpec | Iopub concatenation (definitional) |
| A5 | PASS | GitDiffSpec | Real git: hunk IDs, staged/unstaged markers |
| A6 | PASS | GitCommitSpec | Real git: validation + selective commit |
| A7 | PASS | ControllerSpec | Streaming chunks → CallPrintStr |
| A8 | PASS | OutputThresholdSpec + ControllerSpec | First 5 lines + terminal display |
| A9 | WEAK | OutputThresholdSpec | processToolOutput only; controller not tested |
| A10 | PASS | InterruptionSpec | State machine accepts events in all states |
| A11 | WEAK | InterruptionSpec | handleEscape returns actions; not executed |
| A12 | WEAK | InterruptionSpec | handleSigint returns actions; not executed |
| A13 | WEAK | InterruptionSpec | handleEof same; not executed |
| A14 | WEAK | TimeoutSpec | Schedule computed; not proven to fire |
| A15 | WEAK | TimeoutSpec | Request built; not proven to be sent |
| A16 | WEAK | TimeoutSpec | Decision made; not proven to be enacted |
| A17 | WEAK | TimeoutSpec | Decision made; scheduling not proven |
| A18 | WEAK | RetrySpec | Decision logic; controller wiring not proven |
| A19 | PASS | ControllerSpec | First exec is "using CodeTree" |
| A20 | PASS | ControllerSpec | Kernel error → exit(1) |
| A20a | WEAK | ControllerSpec | Tests spawn failure, not mid-session crash |
| A20b | UNTESTED | — | No test for summary RPC handling |
| A21 | PASS | TemplateSpec | Template substitution (definitional) |
| A22 | PASS | TemplateSpec | All 5 keywords substituted |
| A23 | WEAK | TemplateSpec | Error returned; exit not proven |
| A24 | PASS | SessionLogSpec | Real FS: sequential IDs, flock, concurrency |
| A25 | PASS | SessionLogSpec | Real FS: append-only JSONL |
| A26 | PASS | WireFormatSpec + SessionLogSpec | All event types, correct field names |
| A27 | PASS | SessionLogSpec | Truncation to 120 chars (definitional) |
| A28 | PASS | ReplSerializeSpec + ControllerSpec | Snippet correct + executeCode called |
| A29 | WEAK | JuliaDefsSpec | Extraction logic; file writing not proven |
| A30 | PASS | JuliaDefsSpec | Classification table (definitional) |
| A31 | PASS | SessionResumeSpec + ControllerSpec | History reconstruction + def replay in kernel |
| A32 | WEAK | ReplSerializeSpec + SessionResumeSpec | Snippet has try/catch; actual failure not tested |
| A33 | WEAK | ReactStepSpec + CompactionSpec | Trigger decision; actual compaction not proven |
| A34 | WEAK | CompactionSpec | Algorithm correct; LLM call not proven |
| A35 | PASS | TemplateSpec | Compaction template keywords (definitional) |
| A36 | WEAK | CompactionSpec | Not-in-history partially proven; rest not |
| A37 | PASS | ConfigSpec | Parsing (definitional) |
| A37a | WEAK | ReactStepSpec | Decision correct; turn end not proven |
| A38 | WEAK | ConfigSpec | Reads env var; exit on failure not proven |
| A39 | WEAK | ConfigSpec + StartupSpec | Error detected; exit not proven at controller |
| A40 | PASS | CLISpec + ControllerSpec | Parsing + session execution |
| A41 | WEAK | CLISpec + SessionListingSpec | Parsing + formatting; execution not proven |
| A42 | PASS | CLISpec + ControllerSpec | Parsing + resume execution |
| A43 | WEAK | McpSpec | All helpers; no server/HTTP test |
| A44 | PASS | CLISpec | Path detection (definitional) |
| A45 | PASS | SteeringSpec | All 7 keywords (definitional) |
| A46 | WEAK | SteeringSpec | Condition logic; injection not proven |
| A47 | PASS | ControllerSpec | Correct expression sent to kernel |
| A48 | PASS | RoundStepSpec + ControllerSpec | Multi-turn round with reflection |
| A49 | PASS | RoundStepSpec + ControllerSpec | Prompt appended + reflection called |
| A50 | PASS | ReflectionSpec | JSON parsing (definitional) |

## Notes

- **ControllerSpec is the key innovation.** Before it existed, nearly all
  requirements would have been WEAK (decision functions tested, execution
  unproven). It currently covers A1, A2, A3, A7, A8, A19, A20, A28, A31,
  A47, A48 — converting them from WEAK to PASS.

- **The 22 WEAK requirements follow a single systemic pattern:** they have
  correct `Programs/*.purs` logic but no ControllerSpec scenario that
  exercises that specific code path through the runner.

- **This is not about the tests being wrong** — the decision-logic tests are
  thorough and correct. The issue is that they are necessary but not
  sufficient: they prove the helper works, but do not prove the system calls
  the helper. This was precisely the failure mode that let A14 (timeout
  schedule) pass the previous audit despite being dead code.
