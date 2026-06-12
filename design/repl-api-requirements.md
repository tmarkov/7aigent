# REPL API Requirements

## Overview

The sandbox exposes a persistent Julia REPL over Jupyter. Beyond raw `julia_repl`
execution, the sandbox runtime must provide a **dedicated REPL API module** for
higher-level interactive helpers such as DataFrame display tuning and on-demand
LLM-backed summaries.

This layer is intentionally distinct from both:

- **`CodeTree.jl`** — which remains a general, offline indexing library; and
- **`.7aigent/startup.jl`** — which is a workspace bootstrap/config file that
  users may edit and therefore must stay small.

The REPL API layer owns the Julia-side summary workflow. The agent runner owns
servicing summary requests by calling the external LLM.

---

## Roles and Boundaries

- **CodeTree**: loads the tree, provides documentation-derived `summary` values,
  and exposes `db.code`, `db.symbols`, `get_source`, and `update_source!`.
- **REPL API module**: Julia module provided by the sandbox runtime. Exposes
  interactive helpers such as `summarize!`.
- **Workspace startup**: thin bootstrap file that imports/configures the REPL
  API module and binds the initial `db`.
- **Runner summary service**: host-side handler that receives summary requests
  over Jupyter messaging, calls the configured LLM, and returns structured
  results.

---

## Requirements

### Module Placement and Bootstrap

**RA1** — The REPL API is implemented in a dedicated Julia module and
distributed with the sandbox. The substantive implementation of summary
generation, evidence selection, batching, display helpers, configuration
loading, and Jupyter summary RPC lives in that module.

**RA2** — The REPL API module is available inside the sandbox on Julia's load
path without relying on files in the workspace. It is therefore testable as
ordinary repository code and remains available even when the workspace contains
only the bootstrap files placed by the runner.

**RA3** — The REPL API provides session summary functions and explicit
LLM-focused dataframe display helpers.

**RA3.1** — The REPL API is intended to be bootstrapped by `.7aigent/startup.jl`,
which can import the REPL API module, bind its `CodeTreeDB`, and/or install
`Base.show` overrides for DataFrame-like types by delegating to the display
helpers.

**RA3.2** — The LLM-focused dataframe display helpers render visible rows and
columns as a compact markdown table rather than as a whitespace-aligned terminal
grid. They preserve row/column structure, may include a compact summary line,
surface omitted-row or omitted-column counts explicitly instead of spending
tokens on visual alignment padding, and work for the rich `text/markdown`
display path used by Jupyter frontends.

### Session Summary State

**RA4** — Generated summaries are reflected into the in-memory
`db.code.summary` column of the current REPL session. After `summarize!`
returns, later reads from `db.code` in that session must see the generated
summary text for the summarized rows. The REPL/runtime also tracks those
generated summaries as session-scoped overrides keyed by node id so they can be
re-applied after `update_source!` re-indexes a file.

**RA5** — Generated summaries mutate only the in-memory `CodeTreeDB` for the
current session. They do not change the indexing contract of `CodeTree.jl`, are
not written into `.7aigent/code_tree/index.db`, and are not required to survive
`reload` or a fresh session. They do survive `update_source!` when the
re-indexed rows keep the same ids; if a node id changes or disappears, its
generated summary may be lost.

### Public API Shape

**RA6** — The REPL API module exposes `summarize!` methods that accept either:

1. a collection of CodeTree node ids; or
2. an `AbstractDataFrame` containing an `:id` column.

Both forms accept an optional `keywords` argument.

**RA7** — The id-based `summarize!` method is the primary implementation. The
DataFrame-based method extracts ids, delegates to the id-based method, applies
any newly generated summaries back onto the provided frame when that frame is
mutable and has a `:summary` column, and returns the same tabular result as the
id-based method. Both forms update the current session's `db.code.summary`
values for the summarized ids in place on the existing `db` object; they do not
swap `db` to a replacement `CodeTreeDB`.

**RA7a** — `summarize!` returns a `DataFrame` with columns `:id`, `:name`, and
`:summary`. It contains exactly the requested targets whose generated summary
was created or updated during that call. Result rows preserve the caller's
requested target order after filtering to those newly summarized targets.

**RA33** — For any non-empty `summarize!` call, the REPL API prints concise
informational progress to standard output: a startup line with total target and
batch counts, one line before and one line after each batch, and a completion
line. When the requested rows look like a mixed descendant sweep (for example,
files mixed with non-file rows, or a large chunk-heavy selection), `summarize!`
may additionally print a brief advisory note. These messages are informational
only: they must not reject, reorder, or otherwise change selection, batching,
evidence construction, or summary application.

**RA8** — `summarize!` summarizes **only the explicitly requested ids**. It may
split the request into multiple LLM batches, but it must not recursively
pre-summarize omitted children merely to support a requested parent.

### Batching

**RA9** — When `summarize!` receives multiple target ids, it partitions them
into batches by **tree locality**, not by raw input order.

**RA10** — Batch partitioning proceeds by recursive tree partitioning:

1. Ignore the incoming order of ids.
2. Map each target id to its ancestor chain up to the root and count how many
   requested targets fall under each ancestor.
3. Starting from the root, group targets by the current node's immediate
   children.
4. If a child bucket fits within the configured batch limits, keep it intact.
5. If a child bucket exceeds the limits, recurse into that child and split again
   by its immediate children.
6. After recursion, greedily merge adjacent sibling buckets under the same
   parent, in `sibling_order`, whenever the merged bucket still fits.

The result is a sequence of maximal coherent subtree-shaped batches that fit
within the configured limits.

**RA11** — A batch is considered to fit only when both of the following hold:

- the number of target ids does not exceed `max_targets_per_batch`; and
- the estimated prompt size does not exceed `max_prompt_chars`.

Prompt-size estimation may use character count rather than token count, but it
must be deterministic.

### Evidence Graph

**RA12** — For each LLM batch, the REPL API module constructs a **deduplicated
evidence graph**. If the same supporting node or source witness is needed for
multiple targets in the batch, it appears only once in the request payload.

**RA13** — Each target node contributes the following evidence:

1. a **self card** containing `id`, `kind`, `name`, `qname`, `file`,
   `language`, `signature`, `n_children`, `n_lines`, and any existing
   documentation-derived or previously generated summary;
2. an ordered selection of direct children;
3. promoted documentation evidence from a direct child named `README.md`, if
   present; and
4. bounded source witnesses.

**RA14** — The default primary source-witness rule is:

- **leaf target** → the target node itself;
- **non-leaf target** → the leftmost leaf descendant of the target.

This rule relies on the CodeTree spanning invariant: for non-leaf structural
nodes, the leftmost leaf contains the declaration/header chunk and any absorbed
leading comment block.

**RA15** — A direct child named `README.md` is treated as promoted
documentation. Its own direct children and bounded source text from its leaf
content are included even when other descendants are not expanded.

### Child Selection and Overflow

**RA16** — If a target has at most `max_children_per_target` direct children,
all of them are included in the evidence graph.

**RA17** — If a target has more direct children than `max_children_per_target`,
the REPL API module includes only the highest-ranked children and attaches
overflow metadata:

- `n_children_total`
- `n_children_included`
- `n_children_omitted`
- omitted counts by `kind`

**RA18** — Child ranking is deterministic. The default ranking considers, in
descending importance:

1. promoted documentation children (`README.md`);
2. children that already have a summary;
3. structural children before residual children (`module`, `file`, `class`,
   `function`, `type`, `variable`, `import`, `loop`, `conditional`, `try`,
   `with`, `comment`, then `chunk`);
4. keyword matches in the child's primary source witness;
5. larger `n_lines`;
6. earlier `sibling_order`.

### Keywords

**RA20** — `keywords` are an evidence-selection hint only. They affect child and
chunk ranking but are **not** inserted into the LLM prompt as hidden guidance
about what the summary should say.

**RA21** — Keyword matching is deterministic and case-insensitive. A child or
chunk that matches more distinct keywords outranks one that matches fewer;
additional match count may be used as a tie-breaker.

### Jupyter Summary RPC

**RA22** — The REPL API module requests summaries from the runner over Jupyter
`comm_open` / `comm_msg` / `comm_close` messages on the existing kernel
connection. It does not attempt direct network access from inside the sandbox.

**RA23** — A summary request contains:

- a request id;
- the ordered list of target ids in the current batch; and
- the deduplicated evidence graph for that batch.

**RA24** — The REPL API module blocks awaiting a structured response for each
batch. The response is either:

- a mapping from target id to summary text; or
- an informative error.

After a successful response, the generated-summary store is updated before the
next batch begins. The REPL API does not impose a summary-level timeout while
waiting for the runner: a valid request may remain pending through all
configured runner LLM attempts and completes when a response arrives or the
execution is interrupted.

### Configuration

**RA25** — The REPL API module reads summary-specific settings from the
`[summaries]` section of `.7aigent/config.toml` inside the workspace.

**RA26** — The supported summary settings are:

```toml
[summaries]
max_targets_per_batch = 12
max_prompt_chars = 12000
max_children_per_target = 24
max_witness_chars = 400
max_readme_chars = 3000
```

- `max_targets_per_batch`: maximum number of target ids in one LLM request.
- `max_prompt_chars`: maximum estimated prompt size for one batch.
- `max_children_per_target`: cap on direct children included for one target.
- `max_witness_chars`: cap on any individual source-witness excerpt.
- `max_readme_chars`: cap on promoted README text included for one target.

**RA27** — The `[summaries]` section is optional. When absent, the REPL API
module uses bundled defaults for all fields in RA26. When present, any omitted
field falls back to its bundled default.

---

### Module Structure

**RA28** — The REPL API module source is organised as a directory of files
included by a main module entry file. The display helpers, summarize
functionality, and todo/status functionality each reside in a separate included
file.

---

### Todo State

**RA29** — The REPL API module defines the enumeration type `TodoStatus` with
three values: `pending`, `in_progress`, and `done`. The type and all three values
are exported from the module.

**RA30** — `bind!(workspace, db)` unconditionally initialises a variable named
`todo` in the `Main` module as an empty `DataFrame` with four columns:

- `id` of element type `Int`;
- `parent` of element type `Union{Missing, Int}`;
- `description` of element type `String`;
- `status` of element type `TodoStatus`.

Any existing value of `Main.todo` is overwritten. The REPL session also stores a
validated copy of that table as its last known-good todo state. On session
resumption, the persisted value of `todo` is subsequently restored by the
deserialization step (A31 step 4) after `startup.jl` has run.

**RA31** — The REPL API module exports the following helper functions for
managing the todo list:

- `todo_add!(description::String; parent::Union{Int,Missing}=missing, after::Union{Int,Missing}=missing, start::Bool=false)::Int`
  validates the current todo table, inserts a new row with status `pending`, and
  returns its id. The id is one more than the current maximum id (or `1` if the
  table is empty). Ids are stable handles and need not remain sequential after
  insertion; display order comes from DataFrame row order. With no placement
  arguments the new row is appended as a top-level task. With `parent` only it is
  appended as that parent's last child. With `after` only it is inserted as the
  next sibling of `after`, inheriting `after`'s parent. With both `parent` and
  `after` it is inserted as a child of `parent` immediately after `after`, where
  `after` must be either `parent` itself or one of that parent's existing direct
  children. If the new row is added as a child of the current `in_progress` item,
  that is treated as splitting the current task into subtasks: the previous row
  reverts to `pending` and the new child becomes the sole `in_progress` leaf.
  Setting `start=true` likewise makes the new row the sole `in_progress` leaf.
- `todo_start!(id::Int)::Nothing` validates the current todo table, throws an
  `ErrorException` if `id` does not exist, names a non-leaf row, or names a row
  whose status is `done`, and otherwise makes that row the sole `in_progress`
  leaf. Any previous `in_progress` row reverts to `pending`.
- `todo_next!()::Nothing` validates the current todo table, throws an
  `ErrorException` unless exactly one `in_progress` leaf exists, marks that leaf
  `done`, recursively marks any ancestors `done` whose direct children are all
  `done`, and then moves focus to the next `pending` leaf in DataFrame row order
  if one exists. If no pending leaf remains, it leaves the table with no
  `in_progress` row. After completing the mutation it prints the same status tree
  as `status()` so the caller always sees the updated state without a separate
  call.
- `todo_refine_current!(descriptions::AbstractString...)::Vector{Int}` validates
  the current todo table, throws an `ArgumentError` if called with no arguments,
  throws an `ErrorException` unless exactly one `in_progress` leaf exists, and
  inserts the given descriptions as sibling child leaves under that leaf in order.
  The first child is inserted as a child of the current in-progress item (which
  reverts to `pending`); each subsequent child is inserted as the next sibling
  after the previous one. Returns the vector of new ids in insertion order and
  prints the status tree after all insertions.
- `todo_delete!(id::Int)::Nothing` validates the current todo table, throws an
  `ErrorException` if `id` does not exist, is not a leaf, or has status
  `in_progress` or `done`, and otherwise removes that row, re-validates, and
  prints the updated status tree.

All helper mutations update both the session-owned todo state and the REPL-visible
`Main.todo` table.

**RA32** — The REPL API module exports a `status()::Nothing` function. When
called, it validates the current value of `Main.todo` before rendering it. If no
REPL session is active, `status()` prints nothing and returns normally. If
`Main.todo` is a `DataFrame` and validation succeeds, the validated table replaces
the session-owned last known-good todo state before rendering. If `Main.todo` is
not a `DataFrame` or validation fails, `status()` prints concise validation
errors followed by the last known-good todo state under a `[Last known-good
state:]` header (using the same tree renderer), and leaves the session-owned last
known-good todo state unchanged. When no last known-good state is available (e.g.
immediately after `bind!`), only the validation errors are printed.
Validation must detect at least duplicate ids, parent references to missing ids,
parent cycles, more than one `in_progress` row, and any `in_progress` row that is
not a leaf; implementations may report additional schema or type errors. For
valid tables, `status()` prints task counts and a tree-structured summary
optimised for the runner's `{{julia_state}}` insertion: it must show the current
path to the active leaf plus nearby next pending work, or the next pending path
when nothing is currently `in_progress`. `status()` must not throw under any
circumstances and must not modify state except for synchronising a validated
`Main.todo` table into the session-owned last known-good state.
