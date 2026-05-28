# #0016 Todo API usability improvements

**Status:** done

## Background

Iterative prompt-tuning sessions revealed four friction points in the hierarchical todo API
(introduced in #0015) that cause the model to lose orientation or make avoidable errors.
The issues are ordered by impact.

---

## Issue 1 (high): `todo_next!()` is silent

`todo_next!()` advances focus to the next leaf but prints nothing.  Every correct usage
therefore requires the two-expression idiom `todo_next!(); status()`.  This boilerplate
must be taught explicitly in the system prompt and is the most common source of the "blind
advance" failure mode observed in testing (model calls `todo_next!()` alone and then loses
orientation).

**Fix:** Have `todo_next!()` call the same status-tree renderer as `status()` after
advancing, so the new active state is always visible.  The existing tests assert on
`ErrorException` for invalid states but do not assert on empty output, so this change is
non-breaking.

---

## Issue 2 (high): `status()` shows nothing useful on validation failure

When `Main.todo` is edited into an invalid state (e.g. a manual DataFrame splice that
violates the hierarchy invariants), `status()` prints the validation errors and returns.
The `session.todo_df` last-known-good snapshot is available but unused in the error path,
leaving the model completely without context.

**Fix:** After printing the validation errors, `status()` should also render `session.todo_df`
under a `"[Last known-good state:]"` header.  This lets the model understand where it was
and recover without restarting.

---

## Issue 3 (medium): `todo_refine_current!` belongs in the SevenAigentREPL module

The helper that adds multiple sibling child leaves under the current in-progress leaf was
added to `agent/config/startup.jl` as a workaround.  Defined there it is:

- not exported by `SevenAigentREPL`
- not tested
- unavailable in sessions with a custom `startup.jl`

The pattern is general enough to be a first-class API.

**Fix:** Move the implementation into `sandbox/SevenAigentREPL/Todo.jl`, export it, add
tests for it, and document it in `design/repl-api-requirements.md`.  The default
`startup.jl` can then be simplified to remove the duplicate definition.

---

## Issue 4 (low): No `todo_delete!` — removing a mistaken task requires raw DataFrame manipulation

When the model adds a task with incorrect text, the only recourse is to manually splice
the `todo` DataFrame and call `status()`.  This is fragile (easy to violate invariants)
and requires knowing internal DataFrame representation details.

**Fix:** Add a `todo_delete!(id)` function that removes a pending (not started, not done)
leaf node, re-validates, and renders the updated tree.  Deleting a non-leaf or
in-progress node should throw a descriptive error.
