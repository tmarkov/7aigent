# AGENTS.md — Working on This Codebase

This document is the primary guide for any LLM agent (or human) contributing
to this repository. Read it fully before making any changes.

---

## Repository Layout

```
7aigent/
├── AGENTS.md                  ← you are here
├── README.md
├── flake.nix                  ← Nix flake — all build/test outputs
├── design/                    ← formal design documents (source of truth)
│   ├── codetree-requirements.md   ← CodeTree formal requirements (R1, R2, …)
│   ├── code-tree-schema.md        ← schema rationale and example queries
│   ├── loading-process.md         ← loading/indexing algorithm narrative
│   ├── agent-requirements.md      ← agent formal requirements (A1, A2, …)
│   ├── sandbox-requirements.md    ← sandbox formal requirements (S1, S2, …)
│   └── repl-api-requirements.md   ← REPL API formal requirements (RA1, RA2, …)
├── CodeTree.jl/               ← the Julia package
│   ├── Project.toml
│   ├── src/
│   │   ├── CodeTree.jl            ← package entry point (includes all subfiles)
│   │   ├── types.jl               ← domain types
│   │   ├── config.jl              ← language configuration
│   │   ├── load.jl                ← load / reload
│   │   ├── update_source.jl       ← incremental re-indexing
│   │   └── …                      ← parser, builder, symbols, cache, etc.
│   └── test/
│       ├── runtests.jl            ← test entry point
│       └── test_codebase/         ← fixture codebase used by tests
│           ├── src/               ← C++ files
│           ├── julia/             ← Julia files
│           ├── docs/              ← Markdown files
│           └── data/              ← unknown-language file (.toml)
├── sandbox/                   ← sandboxed IJulia kernel launcher and REPL API
│   ├── 7aigent-sandbox            ← launcher shell script
│   ├── startup.jl                 ← kernel startup script (run inside sandbox)
│   ├── SevenAigentREPL.jl         ← REPL API module entry point
│   ├── SevenAigentREPL/           ← REPL API implementation
│   │   ├── Display.jl             ← LLM-focused DataFrame display helpers
│   │   ├── Summarize.jl           ← on-demand LLM summary workflow
│   │   └── Todo.jl                ← agent todo-list helpers
│   └── test/                      ← sandbox integration tests (pytest)
└── agent/                     ← ReACT agent — LLM ↔ sandbox bridge
```

The **design documents are the source of truth**. All code and tests must
conform to the requirements in the relevant `design/*-requirements.md` file.
When requirements and code disagree, the requirements win — unless you are
deliberately proposing a requirements change (follow the workflow below).

---

## Principle 1 — Type-Driven Design ("If It Builds, It Works")

The goal is to make illegal states unrepresentable so that type errors surface
at compile time rather than at runtime or in tests.

### Use domain types, not raw primitives

Define a distinct type for every domain concept, even if the underlying
representation is just a string or integer. Use **newtype wrappers**:

```julia
# Bad — raw primitives leak through the whole codebase
function find_children(db, id::String, depth::Int) ...

# Good — the compiler prevents passing a NodeId where a LineNumber is expected
struct NodeId    val::String end
struct LineNumber val::Int    end
struct FilePath   val::String end

function find_children(db, id::NodeId, depth::Int) ...
```

Define these types in a dedicated `types.jl` (or a `Types` submodule) and
import them everywhere. Never use a bare `String` or `Int` for a value that
carries domain meaning.

**Key domain types — examples from across the codebase:**

| Concept | Type | Component |
|---------|------|-----------|
| Node identifier | `NodeId` | CodeTree.jl |
| Relative file path | `FilePath` | CodeTree.jl |
| Node kind (`function`, `chunk`, …) | `NodeKind` | CodeTree.jl |
| Workspace path | `WorkspacePath` | agent |
| Git hunk identifier | `HunkId` | agent |
| LLM token count | `TokenCount` | agent |

### Annotate all public function signatures

Every exported function and every function that crosses a module boundary must
have full type annotations on all parameters and the return type:

```julia
# Bad
function load(path, config)

# Good
function load(path::FilePath, config::LanguageConfig)::CodeTreeDB
```

Private helpers may omit annotations when the types are obvious from context,
but annotate anything non-trivial.

### Represent optional values with `Union{T, Missing}`, not sentinel values

Never use `-1`, `""`, `0`, or `nothing` to mean "absent". Use `missing` (or
`Union{T, Missing}`) so the type system tracks optionality:

```julia
# Bad
summary::String   # "" means absent

# Good
summary::Union{String, Missing}
```

---

## Principle 2 — Feature Development Workflow

Follow these steps **in order** when adding any new feature or changing
behaviour. Do not skip steps.

### Step 1 — Update the requirements

Edit the relevant `design/*-requirements.md` file to add or revise the
requirement(s). Give each new requirement the next available number in that
document's series (`R`, `A`, `S`, `RA`, …). Update any companion design
documents if the schema, protocol, or algorithm changes.

*If you are only fixing a bug that is already covered by an existing
requirement, skip this step.*

### Step 2 — Write or update tests

Add tests to the appropriate test suite for the component being changed
(see repository layout above). Each test must reference the requirement by ID —
see **Testing Strategy** below.

### Step 3 — Review the tests

Before implementing anything, read the tests you just wrote and ask:
- Do they test the requirement, or do they test an implementation detail?
- Could they pass even if the requirement is violated?
- Do they cover the important edge cases?

Revise until the answers are satisfying.

### Step 4 — Review the design and API

The tests you wrote will call your planned API. Now is the moment to ask:
- Are the function names and signatures clear and ergonomic?
- Does the API expose the right level of abstraction?
- Are the types correct and sufficiently specific?

Make any necessary changes to the design docs and API shape *before* writing
implementation code. It is cheap to change a signature now; it is expensive
after the implementation is done.

### Step 5 — Confirm the tests fail

Run the tests. They **must fail** at this point (either compilation errors or
assertion failures). If a test passes without any implementation, it is
testing nothing and must be rewritten.

### Step 6 — Implement

Write the implementation code. Work requirement by requirement, not file by
file. Keep changes minimal and focused — do not refactor unrelated code while
implementing.

### Step 7 — Confirm the tests pass

Run the build for the component under change. All tests must pass before you continue.

```bash
nix build .#codeTree   # CodeTree.jl
nix build .#sandbox    # sandbox + REPL API
nix build .#agent      # agent runner
nix flake check        # all components
```

### Step 8 — Refactor

With green tests as a safety net, clean up:
- Remove duplicated logic; extract shared helpers
- Remove dead code and stale comments
- Ensure consistency with the type conventions in Principle 1
- Confirm tests still pass after refactoring

---

## Principle 3 — Testing Strategy

We test **requirements**, not implementation units. There is no separate layer
of unit tests and integration tests; a test either exercises a stated
requirement or it does not belong.

### Annotate every test with a requirement ID

Include the requirement ID in each test name. The format varies by framework:

```purescript
-- Agent (PureScript spec)
describe "A1: ReACT step — no tool call response" do
  it "A1: LLM text response → PromptUser" do
    case reactStep testConfig tokens history response of
      PromptUser -> pure unit
      _          -> fail "Expected PromptUser"
```

```julia
-- CodeTree / sandbox (Julia @testset)
@testset "R14b: leading comment absorbed into compound node span" begin
    qs = only(filter(r -> r.name == "quick_sort", db.code))
    @test qs.line_start < declaration_line_of("quick_sort", TEST_CODEBASE)
end
```

When one test covers multiple requirements, list all IDs:
`"R14b + R18: absorbed comment also provides summary"` or `describe "A1 + A7: …"`.

### The test codebase is your fixture

`CodeTree.jl/test/test_codebase/` is a carefully constructed fixture whose
structure and content directly correspond to the requirements. Each edge case
in it is annotated with the requirement it exercises (look for `# R…`
comments in the source files). Use it as input to `load` in your tests.

When a new requirement needs a new fixture case, **add it to the test
codebase** (and annotate it). Do not construct synthetic ASTs or in-memory
strings unless the test genuinely cannot be expressed against the fixture.

### One requirement → one or more focused tests

Every requirement in the relevant `design/*-requirements.md` file must have at
least one test. Requirements with conditional behaviour or edge cases need multiple:

- R11 / A37a (thresholds): test both sides of the boundary
- R14a/b/c / A1 (step transitions): test each case, positive and negative

### Anti-patterns to avoid

**Reimplementing logic in the test.** If your test does the same computation
as the code under test, a shared bug will make both pass:

```julia
# Bad — re-runs the same line-counting logic
@test node.n_lines == node.line_end - node.line_start + 1

# Good — checks a known concrete value from the fixture
@test node.n_lines == 36  # merge_sort in algorithms.cpp, counted manually
```

**Tautological or trivial tests.** A test that can never fail is not a test:

```julia
# Bad — always true
@test isa(db, CodeTreeDB)

# Bad — tests the Julia type system, not our code
@test typeof(db.code) <: AbstractDataFrame
```

**Testing structure instead of behaviour.** The schema shape is not
interesting; what matters is what the data contains:

```julia
# Bad — tests that columns exist, not that they hold correct values
@test hasproperty(db.code, :line_start)

# Good — tests a specific correctness property from the requirements
merge_sort_node = only(filter(r -> r.name == "merge_sort", db.code))
@test merge_sort_node.n_lines > 30   # R11: qualifies as "long" parent
```

**Over-specifying implementation.** Do not test private functions directly.
Test observable outputs: the contents of `db.code` and `db.symbols` after
`load` or `update_source`.

---

## Julia Conventions

- **Formatting**: 4-space indent; lines ≤ 100 characters.
- **Naming**: `snake_case` for functions and variables; `PascalCase` for
  types and modules; `SCREAMING_SNAKE_CASE` for module-level constants.
- **Docstrings**: every exported symbol gets a `"""..."""` docstring in the
  standard Julia format (`function_name(args) -> ReturnType\n\nDescription`).
- **Error handling**: `throw(ArgumentError(...))` for invalid arguments;
  `throw(ErrorException(...))` for internal invariant violations. Never
  return error codes or use sentinel values.
- **Mutation**: suffix mutating functions with `!` (e.g. `reindex!`). Prefer
  non-mutating functions for public APIs.
- **`missing` vs `nothing`**: use `missing` for absent data in DataFrames
  (it propagates through operations); use `nothing` for absent control-flow
  values.

---

## Filing Issues

Issues live in `issues/` as plain Markdown files. The filename encodes the
status and number:

```
issues/<status>: #<number> <short title>.md
```

- `<status>` should be `open` for new issues, and changed to `done` once the issue is completed.
- `<number>` is a four-digit zero-padded integer (`%04d`), assigned
  sequentially by creation date. The next number is one higher than the
  highest currently in the directory.
- `<short title>` is a brief, lowercase description of the issue.

**Creating a new issue:** pick the next available number, write the file with
status `open`, and commit it. Do not reuse or skip numbers.

**Closing an issue:** rename the file from `open: #NNNN …` to `done: #NNNN …`
using `git mv` so history is preserved.

---

## Commit Messages

- Write the subject line in the imperative mood: *"Add R14b absorption rule"*,
  not *"Added"* or *"Adding"*.
- Reference requirement IDs in the subject or body when relevant.
- Always include the co-author trailer:

```
Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
```
