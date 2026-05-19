# Agent Runner Requirements

## Overview

The agent runner drives a ReACT (Reason + Act) loop between an LLM and a
sandboxed Julia REPL. It receives a user goal, sends it to an LLM with
available tools, executes tool calls, feeds results back, and repeats until
the LLM produces a response with no tool call — at which point it prompts
the user for new input.

The runner is written in **PureScript** (compiled to Node.js).

---

## Architecture

- **Runner**: the PureScript process. Runs on the host. Manages the ReACT
  loop, session logging, LLM communication, and tool dispatch.
- **Sandbox**: a gvisor-isolated container running an IJulia Jupyter kernel.
  Spawned by the runner via `7aigent-sandbox`. See `sandbox-requirements.md`
  for the full sandbox specification.
- **LLM API**: an OpenAI-compatible HTTP endpoint (Chat Completions API with
  streaming and tool-use support) configured per workspace.

The runner connects to the sandbox over the Jupyter messaging protocol
(ZeroMQ IPC). All Julia execution happens inside the sandbox.

---

## Requirements

### ReACT Loop

**A1** — The runner starts with a user message, then enters a ReACT loop:

1. Send the current conversation history to the LLM.
2. Stream the LLM response to the terminal.
3. If the response contains a tool call, execute it and append the result to
   conversation history. Then check if the total input tokens for this turn
   exceed `compaction_threshold`; if so, compact the conversation (A33–A36).
   Then go to step 1.
4. If the response contains no tool call, check if the total input tokens for
   this turn exceed `compaction_threshold`; if so, compact the conversation
   (A33–A36). Then prompt the user for new input and go to step 1 with the
   new message appended.

**A2** — On startup, before the first user prompt, the runner:

1. Ensures all workspace bootstrap files and directories are present (A2a).
2. Reads and validates `config.toml` (A37–A39).
3. Performs the pre-launch git trust-state check (A2b–A2d).
4. Spawns the sandbox via `7aigent-sandbox` with the current working directory
   as the workspace path.
5. Reads the `kernel.json` path printed by the launcher.
6. Connects to the Jupyter kernel.
7. Executes the Julia startup sequence (A19–A20).

**A2a** — Before starting a session, the runner ensures that the workspace
contains a `.7aigent/` directory with the configuration files listed below and
with a `.7aigent/state/` directory. Any listed file that is absent is copied
from the runner's bundled `config/` directory into the workspace. If
`.7aigent/state/` is absent, the runner creates it as a directory. A notice is
printed to the terminal for each file or directory created (e.g.
`Created .7aigent/system_prompt.md from defaults`,
`Created .7aigent/state`). The files and their default sources are:

| Workspace path | Default source |
|----------------|----------------|
| `.7aigent/config.toml` | `config/config.toml` |
| `.7aigent/system_prompt.md` | `config/system_prompt.md` |
| `.7aigent/compaction_prompt.md` | `config/compaction_prompt.md` |
| `.7aigent/summary_message.md` | `config/summary_message.md` |
| `.7aigent/steering_message.md` | `config/steering_message.md` |
| `.7aigent/startup.jl` | `config/startup.jl` |

After placing any missing files, the runner proceeds to validate `config.toml`
(A37–A39). If required fields in `config.toml` still hold placeholder values,
the runner exits with an informative error directing the user to edit the file.

**A2b** — Before spawning the sandbox, the runner checks whether
`.7aigent/state/nogit` exists and whether `.git` exists in the workspace root.
If `nogit` is absent or `.git` is absent, the runner proceeds without prompting.
If both are present, the runner treats this as a trust-state conflict and
intervenes before sandbox launch.

**A2c** — When a trust-state conflict from A2b is detected, the runner inspects
the `.git` object and reports its kind to the user as one of:

- `git directory`
- `git symlink`
- `gitfile`
- `other git object`

The inspection is based on the object currently present at `.git`; for
`gitfile`, the runner does not need to parse or validate the target at this
stage, only identify the file as a gitfile for display.

**A2d** — After reporting the conflict from A2c, the runner prompts the user to
either halt or to remove `.7aigent/state/nogit` and proceed. The prompt must
make clear that proceeding re-trusts the current `.git` metadata for this and
future launches. If the user chooses to halt, the runner exits before sandbox
spawn. If the user chooses to proceed, the runner removes
`.7aigent/state/nogit` on the host and then continues startup.

---

### Tools

**A3** — The runner exposes three tools to the LLM:

- **`julia_repl`**: executes a Julia expression in the persistent sandbox
  kernel and returns its output.
- **`git_diff`**: returns the current diff of the workspace with each hunk
  annotated by a stable ID. Runs on the host with read access to `.git`.
- **`git_commit`**: stages and commits a selected set of hunks to the
  workspace git repository. Runs on the host with full `.git` write access.

**A4** — `julia_repl` takes a single string argument: the Julia source to
execute. The runner sends an `execute_request` to the Jupyter shell channel
and collects all `stream`, `execute_result`, `display_data`, and `error`
messages from the iopub channel until `execute_reply` is received. The
concatenated output is returned as the tool result.

**A5** — `git_diff` takes no arguments. It returns the diff of the workspace
against HEAD, covering both staged changes (index vs HEAD) and unstaged changes
(working tree vs index) to tracked files, plus all untracked files. Staged and
unstaged hunks for the same file may be interleaved in source order. Each hunk
in the output is annotated with a sequential ID (`H1`, `H2`, …); staged hunks
are additionally marked `[staged]` and unstaged hunks `[unstaged]`. Untracked
files appear as "new file" additions and are each treated as a single
`[unstaged]` hunk. The IDs are invalidated by any subsequent `julia_repl` call
or `git_diff` call.

**A6** — `git_commit` takes:

- `what`: either the string `"all"` (stage all current changes, including
  untracked files) or a non-empty list of hunk IDs from the most recent
  `git_diff` output (e.g. `["H1", "H3"]`).
- `message`: the commit subject line.
- `body` (optional): the commit message body.

The runner stages exactly the specified hunks (or all changes if `"all"`),
commits with the given message, and returns a summary of what was committed,
or an error message if the operation failed. If any hunk ID in the list is
absent from the most recent `git_diff` output (stale, never assigned, or
invalidated), `git_commit` fails immediately with an informative error listing
the unrecognised IDs; no staging or commit is performed.

---

### Live Output

**A7** — LLM responses are streamed to the terminal token by token as they
are generated.

**A8** — After a tool call completes, the runner displays the result on the
terminal. If the output is within `output_threshold_chars` (A37), the first
5 lines are shown. If it exceeds the threshold, the error message sent to the
LLM (A9) is shown instead.

**A9** — If a tool call result exceeds `output_threshold_chars`, the LLM
receives an error message in place of the output, explaining that the output
was too large and suggesting a more targeted expression. The full output is
still written to the session log (A25).

---

### Interruption

**A10** — The runner reads keyboard input on a dedicated thread, concurrently
with LLM generation and tool execution.

**A11** — **Escape key** behaviour:

- If the LLM is generating: cancel the in-flight request. Any text already
  streamed to the terminal is preserved as a complete LLM response in both
  the session log and the conversation history. Any partial tool call is
  discarded. The user is then prompted for new input.
- If a tool is running: interrupt it and prompt the user for new input.
  - For `julia_repl`: send an `interrupt_request` to the Jupyter control
    channel and wait for the kernel to recover (per S18–S19).
  - For `git_diff` or `git_commit`: send SIGINT to the host-side tool
    process and wait for it to exit.

The interrupted turn is recorded in the session log as an `escape` event
(A25).

**A12** — **SIGINT** behaviour, applied regardless of current state:

1. If the LLM is generating, cancel the in-flight request. Any text already
   streamed is preserved as a complete LLM response in the session log and
   conversation history; any partial tool call is discarded.
2. If a tool is running, interrupt it. A `tool_result` event is written to
   the session log with any output produced so far, with `\n[interrupted]`
   appended to the output text.
   - For `julia_repl`: send an `interrupt_request` to the Jupyter control
     channel and wait for the kernel to recover (per S18–S19).
   - For `git_diff` or `git_commit`: send SIGINT to the host-side tool
     process and wait for it to exit.
3. Serialize the Julia REPL state to the session directory (A28–A30).
4. Write a `session_end` event to the session log (A25).
5. Exit the runner.

**A13** — **EOF** on stdin when no generation or tool execution is active
behaves identically to SIGINT.

---

### Julia REPL Timeout

**A14** — If a `julia_repl` tool call has been running without completing,
the runner sends periodic out-of-band interrupt checks using exponential
backoff:

| Check | Time since start |
|-------|-----------------|
| 1st   | 30 s            |
| 2nd   | 60 s            |
| 3rd   | 120 s           |
| 4th   | 240 s           |
| 5th   | 480 s           |
| …     | each interval doubles |

**A15** — Each interrupt check sends a separate LLM request using the same
model. This request is **not** appended to the conversation history. It
contains:

- The Julia source being executed.
- The elapsed time.
- Any output produced so far (accumulated from iopub `stream` messages).
- A yes/no question: should the runner interrupt the execution?

The check request and the LLM's response are written to the session log
(A25) and displayed on the terminal, but are not part of the conversation
history.

**A16** — If the LLM answers yes, the runner sends an `interrupt_request` to
the Jupyter control channel. The output produced so far, with `\n[interrupted]`
appended, is returned as the tool result. The ReACT loop continues normally.

**A17** — If the LLM answers no, the runner schedules the next check and
continues waiting. There is no hard cap on total wait time.

---

### LLM API Error Handling

**A18** — On a transient LLM API error (HTTP 429, 5xx, or network timeout),
the runner retries with exponential backoff. The maximum number of retries is
configurable via `max_api_retries` in `config.toml` (A37). If all retries are
exhausted, the error is displayed on the terminal and the runner re-prompts
the user for new input. The session continues; no state is lost.

---

### Julia Startup

**A19** — On every session start (including resume), after the kernel is
connected, the runner executes the following startup sequence in the kernel:

1. `using CodeTree`
2. The contents of `.7aigent/startup.jl`

The Julia kernel's working directory inside the sandbox is `/workspace`. The
default `startup.jl` (placed by A2a if absent) loads the codebase from
`/workspace` into a `CodeTreeDB` bound to a well-known variable in `Main`.
All output and errors from both expressions are captured and made available
as `{{initial_repl_output}}` for the system prompt (A21).

**A20** — If either startup expression raises an error, the runner prints the
error to the terminal and exits with a non-zero status before prompting for
user input.

**A20a** — If the sandbox exits unexpectedly during a session (detected via a
closed socket or failed heartbeat), the runner writes a `session_end` event
with `reason = "error"` to the session log, prints an informative message to
the terminal, and exits.

**A20b** — The runner services the Jupyter summary RPC defined in
`repl-api-requirements.md`. Summary-helper LLM calls use the same configured
model and retry policy as the main session but are not appended to the REACT
conversation history.

---

### System Prompt

**A21** — The system prompt is read from `.7aigent/system_prompt.md` in the
workspace directory. The file is a Markdown template: occurrences of
`{{keyword}}` are replaced with their values before the prompt is sent. A
literal `{` or `}` may appear freely in the template without escaping; only
`{{...}}` triggers substitution.

**A22** — The supported placeholders are:

| Keyword                    | Replaced with                                                                 |
|----------------------------|-------------------------------------------------------------------------------|
| `{{initial_repl_output}}`  | Output of the Julia startup sequence (A19)                                    |
| `{{agents_md}}`            | Full contents of `AGENTS.md` in the workspace root; empty string if absent    |
| `{{startup_jl}}`           | Full contents of `.7aigent/startup.jl`                                        |
| `{{datetime}}`             | Current date and time in ISO 8601 format                                      |
| `{{model}}`                | The model name from config (A37)                                              |

**A23** — Any `{{keyword}}` in the template that does not appear in the table
above causes the runner to exit with an informative error before the session
starts.

---

### Session Logging

**A24** — Sessions are stored under `.7aigent/sessions/` in the workspace
(the current working directory). Each session is a subdirectory named by its
sequential integer ID, starting at 1 per workspace (e.g. `1/`, `2/`, `3/`).
IDs are assigned under a file lock (`flock` on `.7aigent/sessions/.lock`) to
prevent races when multiple runner processes target the same workspace
concurrently.

**A25** — Each session directory contains:

- `log.jsonl` — append-only event log, one JSON object per line.
- `julia_state.jls` — serialized Julia REPL globals (written on SIGINT or
  EOF, A28).
- `julia_defs.jl` — Julia definition expressions extracted from the session
  (written on SIGINT or EOF, A29–A30).

**A26** — The following event types are written to `log.jsonl`:

| Event type         | Fields                                                                                     |
|--------------------|--------------------------------------------------------------------------------------------|
| `session_start`    | `id`, `timestamp`, `workspace`, `model`, `resumed_from` (id or null)                      |
| `user_message`     | `timestamp`, `content`                                                                     |
| `llm_response`     | `timestamp`, `content`                                                                     |
| `llm_query`        | `timestamp`, `purpose`, `input`                                                            |
| `tool_call`        | `timestamp`, `tool`, `tool_call_id`, `input`                                               |
| `tool_result`      | `timestamp`, `tool_call_id`, `output`, `truncated` (bool)                                  |
| `token_usage`      | `timestamp`, `input_tokens`, `cached_input_tokens`, `output_tokens`, `total_session_input_tokens`, `total_session_cached_input_tokens`, `total_session_output_tokens` |
| `compaction`       | `timestamp`, `summary`, `initial_message_count`, `compacted_message_count`, `final_message_count`, `total_tokens_before` |
| `timeout_check`    | `timestamp`, `elapsed_seconds`, `partial_output`                                           |
| `timeout_response` | `timestamp`, `interrupt` (bool)                                                            |
| `escape`           | `timestamp`                                                                                |
| `sigint`           | `timestamp`                                                                                |
| `session_end`      | `timestamp`, `reason` (`"eof"`, `"sigint"`, `"error"`)                                    |

A `token_usage` event is written after every LLM API call that includes token
counts — including the main conversation, compaction calls, timeout-check
calls, and REPL-summary calls. The session totals accumulate across all such
calls. After each turn, the runner also displays the cumulative session token
counts on the terminal.

A `llm_query` event is written whenever the runner issues an internal LLM query
on behalf of the Julia REPL rather than the main conversation loop. The event's
`purpose` describes the query kind (currently `summary`), and `input` stores the
serialized REPL-to-runner request payload that triggered the query.

**A27** — The session description used in listings (A40) is the content of
the first `user_message` event, truncated to 120 characters.

---

### REPL State Serialization

**A28** — On session end (SIGINT or EOF), the runner serializes the Julia
REPL state by executing a snippet in the kernel that:

1. Iterates `names(Main, all=false)` to enumerate user-defined bindings.
2. Attempts `Serialization.serialize` for each binding into an in-memory
   buffer.
3. Skips any binding that fails serialization, without error.
4. Writes all successfully serialized values to `julia_state.jls` via
   `/workspace/.7aigent/sessions/<id>/julia_state.jls`.

**A29** — The runner also writes `julia_defs.jl`: a Julia source file
containing definition expressions from the session that are safe to replay.
The goal is to make all types and functions available before deserialization
runs, so that `Serialization.deserialize` can reconstruct values of those
types. These are extracted by filtering the `input` field of all `tool_call`
events in `log.jsonl` whose `tool` is `"julia_repl"`, in execution order.

**A30** — An expression is included in `julia_defs.jl` if and only if it is
a **pure definition** — one that registers a new type or method without
executing any code with side effects. The test is applied to the top-level
`Expr` produced by `Meta.parse`. The following are pure definitions:

| Expr head | Julia syntax | Notes |
|-----------|-------------|-------|
| `:function` | `function foo(x) ... end` | Registers the method; body is never executed |
| `:macro` | `macro foo(x) ... end` | Registers the macro; body is never executed |
| `:struct` | `struct Foo ... end`, `mutable struct Foo ... end` | First arg is a Bool for mutability |
| `:abstract_type` | `abstract type Foo end` | |
| `:primitive_type` | `primitive type Foo 64 end` | |
| `:(=)` with call LHS | `f(x) = expr` | Short-form method definition; LHS head must be `:call` |
| `:macrocall` (`@enum`) | `@enum Color Red Green Blue` | Expands to type + constant definitions only |
| `:macrocall` (`@kwdef`) | `@kwdef struct Foo ... end` | Expands to struct + keyword constructor |
| `:const` with simple RHS | `const Foo = Bar`, `const Foo = Vector{Int}` | Included only when the RHS `Expr` is a plain identifier, a parameterised type (`:curly` head), or `Union{...}`. Excluded when the RHS involves any function call (`:call` head) whose side effects cannot be guaranteed absent. |
| `:module` | `module Foo ... end` | The module block itself is **not** replayed whole. Instead its body is scanned recursively for pure definitions (by the same rules in this table), which are emitted individually at the enclosing scope rather than inside a `module` block. |

All other expressions — including standalone function calls, variable
assignments, `const` declarations with non-trivial RHS, `import`/`using`
statements, and any expression not listed above — are excluded. This ensures
that no disk I/O, network access, or other side effects are replayed during
session resumption.

---

### Session Resumption

**A31** — `7aigent resume <session-id>` resumes a previous session by:

1. Spawning a fresh sandbox.
2. Executing the Julia startup sequence (A19–A20).
3. If `julia_defs.jl` exists in the session directory, executing each
   expression it contains in the kernel, in order. If any individual
   expression raises an error, it is skipped and a warning is printed to
   the terminal; replay continues with subsequent expressions. If the file
   is absent (e.g. the session was killed without a clean exit), this step
   is skipped with a warning printed to the terminal.
4. If `julia_state.jls` exists, executing a deserialization snippet in the
   kernel that loads it and rebinds all saved globals into `Main`. If the
   file is absent, this step is skipped with a warning.
5. Reconstructing the conversation history from `log.jsonl` such that the
   in-memory conversation is identical to what it was at session end,
   including any compactions that occurred during the session. The
   `tool_call_id` field in `tool_call` and `tool_result` events is used to
   pair tool calls with their results when reconstructing the message list.
   The `{{datetime}}` placeholder in the system prompt is re-substituted with
   the current date and time at resume time.
6. Writing a `session_start` event with `resumed_from` set to the original
   session ID.
7. Entering the ReACT loop with the restored conversation history.

**A32** — If deserialization of any individual global fails (e.g. the type
is no longer defined, or the serialized format is incompatible), that global
is skipped and a warning is printed to the terminal. The session continues
with all remaining globals intact.

---

### Context Compaction

**A33** — Compaction is triggered as described in A1 steps 3 and 4: after
each tool round-trip or after a no-tool-call LLM response, if the input token
count of the **actual current LLM request** exceeds `compaction_threshold`.
This is the size of the request that just completed, not a cumulative sum of
all prior request sizes earlier in the same turn. Compaction is never triggered
after a user message.

**A34** — Compaction proceeds as follows:

1. **Preserve the initial block**: starting from the system prompt and the
   first user message, include as many consecutive messages as possible
   without exceeding `preserve_initial` tokens. The system prompt and first
   user message are always included unconditionally, even if they alone
   exceed `preserve_initial`.

2. **Preserve the final block**: starting from the most recent message and
   working backwards, include as many consecutive messages as possible
   without exceeding `preserve_final` tokens.

3. **Identify the compacted block**: all messages between the initial block
   and the final block.

4. **Summarize**: call the LLM using the compaction prompt template (A35).
   The `{{initial_messages}}`, `{{compacted_messages}}`, and
   `{{final_messages}}` keywords are replaced with the rendered text of the
   respective message groups. This call is not added to the conversation
   history.

5. **Build the new conversation**: replace the full conversation history with
   `[initial block] + [synthetic user message from the summary template
   (A35), with `{{summary}}` replaced by the LLM's response] + [final block]`.

6. **Check post-compaction size**: if the resulting conversation still
   exceeds `compaction_threshold`, the runner exits the session with an
   informative error explaining that the context is too large to compact and
   a new session must be started. A `session_end` event with `reason =
   "error"` is written before exiting.

7. **Log** a `compaction` event (A26) with the generated summary and message
   counts.

**A35** — Two workspace template files govern compaction, both located in
`.7aigent/`. Both use the same `{{keyword}}` substitution syntax as A21. The
**compaction prompt template** is the prompt sent to the LLM requesting a
summary; its supported keywords are `{{initial_messages}}`,
`{{compacted_messages}}`, `{{final_messages}}`, and `{{julia_state}}`. The
**summary message template** produces the synthetic user message inserted at the
compaction boundary; its only supported keyword is `{{summary}}`. An unrecognised
`{{keyword}}` in either template causes the runner to exit with an informative
error (same rule as A23).

**A36** — The compaction LLM call uses the same model as the main session.
It is written to the session log as a `compaction` event but is not part of
the conversation history and does not count against `max_tokens_per_turn`.

---

### Configuration

**A37** — The runner reads `.7aigent/config.toml` from the workspace
directory. The runner-owned required fields are:

```toml
api_endpoint           = "https://openrouter.ai/api/v1"
model                  = "anthropic/claude-opus-4-5"
api_key_env            = "OPENROUTER_API_KEY"
output_threshold_chars = 20000
max_api_retries        = 3
max_tokens_per_turn    = 200000
compaction_threshold   = 150000
preserve_initial       = 20000
preserve_final         = 40000
```

`compaction_threshold`, `preserve_initial`, and `preserve_final` are token
counts governing context compaction (A33–A36). Additional sections may be
present for other layers, including the REPL API; runner configuration parsing
must ignore unknown sections and keys that it does not own.

**A37a** — `max_tokens_per_turn` is the maximum total input tokens the runner
may consume across all LLM calls within a single turn (the ReACT loop between
two user prompts). The runner accumulates the input token count reported by
the API after each LLM call in the turn. When the accumulated total exceeds
`max_tokens_per_turn`, the runner completes the current step normally — the
LLM response is added to conversation history and any tool calls it contains
are executed — and then ends the turn after that step completes. The runner
notifies the user that the token limit was reached and re-prompts for new
input. The next turn begins from the updated conversation history.

**A38** — `api_key_env` names an environment variable that holds the API
key. The runner reads the key from the environment at startup and exits with
an informative error if the variable is not set or is empty.

**A39** — If `config.toml` is absent or any required field is missing, the
runner exits with an informative error before starting the session.

---

### CLI Interface

**A40** — `7aigent` starts a new session for the current working directory.

**A41** — `7aigent sessions` lists all sessions for the current workspace:

```
ID  Started              Duration   Description
 1  2025-01-15 14:32     12m 04s    Add R14b absorption rule to CodeTree.jl
 2  2025-01-15 16:01      3m 22s    Fix failing tests in runtests.jl
 3  2025-01-15 17:45         —      Resume me later
```

Duration is computed from `session_start` to `session_end` timestamps. If
no `session_end` event is present (e.g. the process was killed), duration is
shown as `—`.

**A42** — `7aigent resume <session-id>` resumes the specified session (A31).

---

### MCP Server Mode

**A43** — `7aigent mcp <port>` starts the runner as an MCP server using HTTP
transport on the specified port. The server exposes a single tool:

```json
{
  "name": "run",
  "description": "Run an agent task against the workspace and return the final answer.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "message": { "type": "string", "description": "The task or question for the agent." }
    },
    "required": ["message"]
  }
}
```

Each invocation of `run` starts a complete, independent ReACT loop in its
own sandbox. The invocation is logged as a full session (A24–A26). While the
ReACT loop is running, the server sends MCP progress notifications at regular
intervals (every 15 seconds) so that MCP clients with idle-connection timeouts
can detect that the session is still active. The tool returns the text of the
final LLM message — the first response in that loop that contains no tool
call. If the ReACT loop fails (sandbox crash, API errors exhausted, context
too large, etc.), the tool returns an error string describing the failure
instead of an LLM message.

### Workspace Directory Override

**A44** — If the first CLI argument looks like a filesystem path — that is, it
starts with `.` or contains a `/` — it is interpreted as an explicit
workspace directory and used instead of the current working directory. The
remaining arguments are then parsed as the command in the normal way (A40–A43).

```
7aigent /path/to/project           # start new session in /path/to/project
7aigent relative/path              # start new session in relative/path
7aigent ./myproject sessions       # list sessions for ./myproject
7aigent /path/to/project resume 3  # resume session 3 in /path/to/project
```

If no path argument is present the workspace defaults to the current working
directory (preserving the existing behaviour described in A40–A43).

---

### Turn Steering

**A45** — The workspace contains a steering message template at
`.7aigent/steering_message.md`, placed by A2a if absent. The file uses the same
`{{keyword}}` substitution syntax as A21. At session start, the runner reads and
validates this template; any unrecognised `{{keyword}}` causes the runner to exit
with an informative error (same rule as A23). The supported keywords are:

| Keyword | Replaced with |
|---|---|
| `{{julia_state}}` | Formatted task-list status, resolved as in A47 |
| `{{turn_tokens}}` | Total input tokens accumulated across all LLM calls in the current turn so far |
| `{{turn_token_limit}}` | The `max_tokens_per_turn` value from config |
| `{{compaction_threshold}}` | The `compaction_threshold` value from config |

**A46** — In the ReACT loop, after executing a tool call and appending its result
to the conversation history, if the accumulated input tokens for the current turn
are greater than zero (i.e. at least one LLM call has already completed this
turn), the runner:

1. Resolves `{{julia_state}}` as described in A47.
2. Substitutes all keywords from A45 into the steering message template.
3. Appends the resulting text as a user-role message to the conversation passed
   to the next LLM call only.

The steering message is **not** added to the persistent `ConversationHistory` and
is **not** written to the session log. It is regenerated fresh before each
subsequent LLM call within the turn.

**A47** — The `{{julia_state}}` substitution value — used in both the steering
message (A45) and the compaction prompt (A35) — is obtained by executing the
following Julia expression in the Jupyter kernel:

```julia
begin; local _ans = isdefined(Main, :ans) ? Main.ans : nothing; SevenAigentREPL.status(); _ans end
```

The runner captures the concatenated stdout output (iopub `stream` messages)
produced during this execution as the substitution text. The expression is
structured to restore `Main.ans` to its prior value after the call, so that the
kernel's interactive state is unaffected. If the execution fails, produces no
output, or does not complete within a short timeout, the substitution value is
the empty string. This kernel call is not logged as a `tool_call` event and does
not affect the conversation history.
