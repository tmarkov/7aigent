# Agent Contributing Guide

Engineering guidelines for the PureScript agent (`agent/`). Read alongside
`design/agent-requirements.md` (the source of truth for behaviour) and
`AGENTS.md` (the repo-wide workflow).

---

## Workflow

Follow the same requirement-driven sequence as `AGENTS.md`:

1. **Locate or add the requirement** — every change traces to an `A`-numbered
   requirement. If the behaviour you need isn't specified, propose a
   requirements change first.
2. **Write the test** — before touching implementation, write a failing test
   that references the requirement by ID (see *Testing* below).
3. **Confirm it fails** — a test that passes without an implementation is not
   a test.
4. **Review APIs and contracts** — the test will also show you how APIs and contracts
   work in practice. Review whether they make sense and are ergonomic,
   and adjust them if necessary.
4. **Implement** — work requirement by requirement, not file by file.
5. **Confirm it passes** — run the full suite before considering the work done.
6. **Refactor** — clean up with green tests as a safety net.

---

## Type-Driven Design

The same principle from `AGENTS.md` applies in PureScript, enforced by a
stronger type system. Make illegal states unrepresentable.

### Newtype every domain scalar

Every value that carries domain meaning gets its own newtype, even when the
underlying representation is a primitive:

```purescript
newtype SessionId     = SessionId Int
newtype HunkId        = HunkId String
newtype ToolCallId    = ToolCallId String
newtype TokenCount    = TokenCount Int
newtype RawJulia      = RawJulia String
newtype WorkspacePath = WorkspacePath String
```

This prevents accidental substitution (`HunkId` where a `ToolCallId` is
expected), makes signatures self-documenting, and lets the compiler catch
stale-ID bugs (A6) at compile time rather than runtime.

**Provide smart constructors named `make<Type>`** and an explicit `unwrap`.
Never expose the data constructor directly unless needed for pattern matching
in the same module.

```purescript
makeHunkId :: String -> HunkId
makeHunkId = HunkId

unwrapHunkId :: HunkId -> String
unwrapHunkId (HunkId s) = s
```

### Use ADTs to make state machines explicit

When a value can be in one of several mutually exclusive states, encode that
with a sum type rather than a record with optional fields or a status string:

```purescript
data LoopState
  = AwaitingLlm  ConversationHistory
  | ExecutingTool ConversationHistory ToolCall
  | AwaitingUser ConversationHistory
```

Partial records and boolean flags that stand in for state machines are banned.

### Use `Maybe` for optional values, never sentinel primitives

`-1`, `""`, and `false` are not absent. Use `Maybe`:

```purescript
-- Bad
type Config = { body :: String }   -- "" means absent

-- Good
type Config = { body :: Maybe String }
```

### Annotate every public signature

Every exported function and every function that crosses a module boundary must
have a full type signature. Private helpers may omit signatures only when the
types are unambiguous from context.

---

## Module Architecture

The agent separates **pure logic** from **effectful execution**. This boundary
is the most important structural rule.

### Pure programs

A *program* is a pure function from inputs to outputs. It may return values
that *describe* effects (e.g. a `ControllerAction` record, a `NextStep` ADT),
but it never executes them. Programs live in a `Programs/` subtree.

- No `Effect`, `Aff`, `Ref`, `Console.log`, or any monadic I/O inside a program.
- No runtime decisions based on the current time, random values, or mutable state.
- The only allowed monads are `Maybe`, `Either`, `List`, `Array`, and other
  purely algebraic ones.

Programs being pure means they are trivially testable: construct inputs,
call the function, assert on the output. No mocking, no async test harness.

### Effectful services

*Services* are the effectful shell: they implement I/O capabilities (LLM HTTP
calls, Jupyter ZMQ protocol, git subprocess, file writes) and expose them as
named capability handles (see next section).

Services live in a `Services/` subtree. They may use `Effect`, `Aff`, and
`ExceptT`. They are not tested directly — their behaviour is covered by
requirement tests that drive the whole stack.

### Capability handles

Every capability the loop needs is wrapped in a named newtype. The loop
receives a record of these handles at startup; it never imports a service
module directly.

```purescript
newtype LlmCall    = LlmCall    (ConversationHistory -> Aff LlmResponse)
newtype JuliaExec  = JuliaExec  (RawJulia -> Aff ExecResult)
newtype SessionLog = SessionLog (LogEvent -> Effect Unit)
```

This keeps the dependency surface explicit and lets tests substitute simple
in-memory stubs for the real implementations without a framework.

### Entry point

`Main.purs` is the only place where services are constructed and capability
handles are wired together. The top-level `main` executes effects; everything
above it is pure.

---

## Effect Types

Use native PureScript. Do not introduce fp-ts or any JavaScript-level effect
wrappers.

| Situation | Type |
|-----------|------|
| Synchronous side effect | `Effect a` |
| Async operation | `Aff a` |
| Async that can fail with a typed error | `ExceptT AppError Aff a` |
| Optional value | `Maybe a` |
| Operation that can fail two ways | `Either e a` |

Prefer `ExceptT` over returning `Aff (Either e a)` when errors need to
propagate through a chain of operations — it keeps the happy path readable.
Unwrap at the boundary with `runExceptT`.

**Compose effects; don't execute them inside programs.** If a function in
`Programs/` needs to "sequence two actions", it should return a data structure
describing both actions, not call `bind` on `Aff`.

---

## Error Handling

- Use typed error ADTs. Never throw strings or use `unsafeThrow` in business
  logic.
- Distinguish between *expected failures* (typed with `ExceptT` or `Either`)
  and *invariant violations* (where `unsafeThrow` or `error` is acceptable as
  a last resort and should be accompanied by a comment).
- Do not swallow errors silently. If a recovery path exists, encode it in the
  return type.

```purescript
data AppError
  = LlmApiError HttpStatus String
  | SandboxDisconnected
  | ConfigMissing String
  | StaleHunkId HunkId
```

---

## Testing

### Test requirements, not implementations

Every test must exercise a stated requirement and **reference its ID** in the
test name. There is no separate layer of unit tests or integration tests — a
test either covers a requirement or it does not belong.

```purescript
-- purescript-spec
describe "A6: git_commit rejects stale hunk IDs" do
  it "fails immediately without staging when a hunk ID is absent" do
    ...
  it "lists all unrecognised IDs in the error" do
    ...
```

If a single test covers multiple requirements, list all IDs: `"A33 + A34:
compaction preserves system prompt unconditionally"`.

### What to test

Test observable outputs — the values returned by pure programs and the events
recorded by the session log. Do not test private functions.

For pure programs, the key law families are:

- **Coldness**: constructing a value or calling a program executes no effects.
- **Snapshot fidelity**: a program reflects the inputs it was given, not
  stale state.
- **Invariants under arbitrary input**: properties that must hold for all valid
  inputs, verified with QuickCheck.

```purescript
-- Coldness: building the next step must not execute any IO
it "A1: reactStep is cold during composition" do
  let next = reactStep someHistory someLlmResponse
  -- reaching this line without crashing is the assertion

-- QuickCheck invariant
it "A34: initial block always contains the system prompt" do
  quickCheck \(history :: ConversationHistory) ->
    let plan = buildCompactionPlan history threshold
    in containsSystemPrompt plan.initialBlock
```

### Anti-patterns (same as `AGENTS.md`, applied to PureScript)

- **Reimplementing logic in the test** — check concrete expected values, not
  re-derived ones.
- **Tautological tests** — a test that cannot fail is not a test.
- **Testing structure** — test what the output *contains*, not that a record
  field exists.

---

## Naming

PureScript conventions:

- `camelCase` for functions and variables.
- `PascalCase` for types, newtypes, and modules.
- `SCREAMING_SNAKE_CASE` for module-level constants.
- Smart constructors: `make<Type>` (e.g. `makeSessionId`, `makeHunkId`).
- Unwrap helpers: `unwrap` within the defining module; qualify externally
  (`HunkId.unwrap`).
- Capability handle runners (functions that extract and apply the wrapped
  function): `run<Capability>` (e.g. `runLlmCall`, `runJuliaExec`).

Modules follow `Agent.<Layer>.<Domain>`:

- `Agent.Programs.ReactLoop` — pure ReACT step logic
- `Agent.Programs.Compaction` — pure compaction plan builder
- `Agent.Services.Llm` — effectful LLM HTTP client
- `Agent.Services.Sandbox` — Jupyter ZMQ protocol
- `Agent.Capabilities` — all capability newtype definitions

Keep modules focused: a module should export one coherent concept. If you find
yourself adding an unrelated type or function, it belongs in its own module.

---

## What Not To Do

### Don't execute effects inside programs

A program that calls `Aff`, reads a `Ref`, or calls `Console.log` is not a
program — it's a service in disguise. The moment a program executes an effect,
it becomes untestable without a full async harness and its logic can no longer
be reasoned about purely.

```purescript
-- Bad: program secretly executes an effect
buildViewProps :: Kernel -> Effect ViewProps
buildViewProps kernel = do
  now <- getCurrentTime          -- effect inside program!
  pure { timestamp: now, ... }

-- Good: time is an input, not a side-effect
buildViewProps :: Milliseconds -> Kernel -> ViewProps
buildViewProps now kernel = { timestamp: now, ... }
```

### Don't pass raw primitives across module boundaries

Once a `String` escapes its origin without a newtype wrapper, nothing stops it
being passed where a different `String` is expected. Catching this at the type
level is free; catching it at runtime is expensive.

```purescript
-- Bad
executeJulia :: String -> Aff String

-- Good
executeJulia :: RawJulia -> Aff ExecResult
```

### Don't widen capability handles beyond what a function needs

Passing the entire `RunnerEnv` into a function that only needs `SessionLog`
hides the true dependency surface, makes the function harder to test, and
makes it easy to accidentally use capabilities that shouldn't be in scope.

```purescript
-- Bad
logEvent :: RunnerEnv -> LogEvent -> Effect Unit

-- Good
logEvent :: SessionLog -> LogEvent -> Effect Unit
```

### Don't use `Maybe` or `Either` as a substitute for a typed error ADT

`Either String a` tells the caller nothing about what went wrong or how to
handle it. Define an ADT; the compiler will then force you to handle every
case.

```purescript
-- Bad
executeJulia :: RawJulia -> Aff (Either String ExecResult)

-- Good
executeJulia :: RawJulia -> ExceptT JuliaError Aff ExecResult

data JuliaError
  = KernelDisconnected
  | ExecutionTimeout Duration
  | KernelError String
```

### Don't silently degrade types to make bridging easier

If a type correctly models the domain (e.g. `NonEmptyArray HunkId` for
`git_commit`'s `what` when hunk IDs are specified), keep it. Weakening to
`Array String` to avoid a conversion is a regression: the compiler stops
enforcing the invariant and the requirement falls back to runtime checks or
tests.

### Don't write tests without a requirement ID

A test without an `A`-number is untraceable. When a requirement changes, you
cannot find which tests need updating. When a test fails, you cannot find
which requirement it covers. Both cases lead to drift between specification
and implementation.

```purescript
-- Bad
it "compacts when context is large" do ...

-- Good
it "A33: compaction triggers when input tokens exceed compaction_threshold" do ...
```

### Don't import service modules from programs

Programs must not depend on services. If you find yourself writing
`import Agent.Services.Llm` inside `Agent.Programs.*`, stop — the dependency
is inverted. Pass a capability handle as a parameter instead, or move the
logic into a service.

---

## Formatting and Style

- 2-space indent.
- Lines ≤ 100 characters.
- Every exported symbol gets a comment when its purpose is non-obvious from
  the type alone. Do not comment self-evident things.
- Explicit export lists on every module. Hidden exports make refactoring
  dangerous and make the public API ambiguous.
- No orphan instances. Typeclass instances belong in the module that defines
  either the class or the type.
- Prefer `let`/`where` over helper definitions at the top level when a
  function is only used once and only in one place.

---

## Commit Messages

Same rules as `AGENTS.md`:

- Imperative mood: *"Add A14 timeout check with exponential backoff"*.
- Reference requirement IDs in the subject or body.
- Always include the co-author trailer:

```
Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
```
