# Improve REPL todo tracking with hierarchical validated state

## Summary

The current REPL todo system is a flat `DataFrame` plus three helper functions:
`todo_add!`, `todo_start!`, and `todo_done!`. Self-test runs showed that once the
agent is prompted to look at `todo`, it does use it — but the current model is
still too weak for larger or more exploratory tasks:

- the schema cannot represent hierarchical plans;
- `status()` exposes too little structure to `{{julia_state}}`;
- splitting a task into subtasks or inserting follow-up steps requires awkward
  manual dataframe editing;
- the ownership model between `Main.todo` and the session-owned todo state is
  too implicit.

The REPL todo system should be upgraded into a **hierarchical, validated, and
better-rendered task tracker** while still keeping the underlying table visible
and editable in the REPL.

## Current state

Today the sandbox REPL binds:

- `Main.todo` as a `DataFrame(id, description, status)`;
- `todo_add!(description)` to append a pending row;
- `todo_start!(id)` to set one row `in_progress`;
- `todo_done!(id)` to mark a row `done`;
- `status()` to print task counts, the current `in_progress` item, and the
  first pending item.

Internally, `status()` reads the session-owned todo state rather than trusting
`Main.todo`, so it keeps working even if `Main.todo` is overwritten with a
non-DataFrame value.

## Problems observed

During prompt self-testing, the main remaining weakness after improving prompt
salience was not “the agent ignores todos”, but “the todo model does not carry
enough structure once the task becomes more complex”.

Concrete problems:

1. A flat list cannot represent parent tasks and subtasks.
2. `status()` is too lossy for the runner’s `{{julia_state}}` insertion; it does
   not show the current leaf in the context of its parents and nearby next work.
3. Splitting a current task into subtasks is awkward and easy to do
   inconsistently.
4. The helper API covers only the simplest append/start/done workflow.
5. Direct DataFrame editing is possible today, but the sync/validation contract
   is unclear.

## Desired design

### Hierarchical schema

Upgrade the todo schema to include a parent reference:

- `id`
- `parent`
- `description`
- `status`

`parent` should allow a row to be a child of another row, so larger plans can be
represented as a tree while still using the `DataFrame` row order as display and
sibling order.

### Leaf-only current work

The current `in_progress` item should always be a **leaf node**. Parent rows are
planning context, not the active executable step.

If a helper operation adds a child under the current `in_progress` item, that
should be interpreted as **splitting the current task into subtasks**. The new
child becomes the active leaf.

### Stable ids, non-sequential allowed

Todo ids should be treated as stable handles, not as display positions. They do
not need to remain sequential once items are inserted into the middle of the
table. Display order should come from the DataFrame row order.

### Better helper API

The helper API should be simplified and made more expressive:

- keep `todo_add!`, but allow it to add top-level rows, children, or siblings
  via optional placement arguments;
- keep `todo_start!(id)` as the explicit “focus this leaf” operation;
- add `todo_next!()` as the common happy-path transition (“finish current leaf
  and move to the next pending leaf”);
- remove or de-emphasize `todo_done!`, since `todo_next!()` should cover the
  normal advance-to-next-step workflow.

One possible surface is:

```julia
todo_add!(description; parent=missing, after=missing, start=false)
todo_start!(id)
todo_next!()
```

### Validation and status rendering

`status()` should validate the current `todo` table before rendering it. At a
minimum it should detect:

- duplicate ids;
- missing parent references;
- parent cycles;
- more than one `in_progress` item;
- an `in_progress` item that is not a leaf.

When the table is malformed, `status()` should not fail silently. It should
print concise validation errors that explain what is wrong.

When the table is valid, `status()` should render the current path through the
tree instead of only counts and the first pending item, e.g.:

```text
[Tasks: 3 done · 1 in progress · 4 pending]

Current path:
- Parent task
  - Child task
    - Current leaf
    - Next sibling
- Next top-level task
```

This output is what the runner will surface in `{{julia_state}}`, so it should
optimize for fast LLM comprehension rather than for terminal-style table output.

### Clear ownership / sync contract

The implementation should define a clear contract between the REPL-visible
`Main.todo` and the session-owned todo state. In particular:

- direct DataFrame edits by the model should be supported intentionally, not by
  accident;
- valid edits should be reflected into the session state used by `status()`;
- invalid edits should produce validation feedback without corrupting the last
  known-good session state.

## Proposed fix

1. Update the REPL API requirements for todo state (`RA29`–`RA32`) to describe
   the hierarchical schema, helper API, validation rules, and richer status
   rendering.
2. Replace the flat todo implementation in `sandbox/SevenAigentREPL/Todo.jl`
   with the hierarchical validated model.
3. Update `SevenAigentREPL.bind!` / session state handling so `Main.todo` and the
   session-owned todo state have an explicit sync contract.
4. Update sandbox tests to cover:
   - parent-aware insertion;
   - splitting the current task into subtasks;
   - `todo_next!()` behavior;
   - malformed todo validation;
   - status rendering with current-path context.
5. Revisit the default startup/status usage once the richer todo model exists, so
   prompt templates can rely on the improved structure.
