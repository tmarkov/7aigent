# Integrate Git-aware change selection into CodeTree and agent

## Problem

Today the agent runner exposes host-side `git_diff` and `git_commit` tools
(`design/agent-requirements.md`, A3-A6). The model reviews changes as raw Git
hunks with temporary hunk IDs, but it understands code semantically through
`CodeTreeDB` nodes inside Julia. That mismatch makes common workflows awkward:

1. inspect the changed semantic nodes;
2. stage only the relevant subset;
3. run `nix build`;
4. commit either the staged result or another selected subset.

This issue replaces the model-facing, hunk-based read surface with a
CodeTree-integrated one. The **read side** should live in `CodeTree.jl`; the
**write side** should remain host-side Git tooling in the agent.

## Target user-facing model

- The primary semantic surface is the current workspace delta vs `HEAD`.
- The model reasons mostly in terms of `db.code.id` selectors.
- Some changes have no useful current code node (deleted files, binary files,
  non-indexed files, unmerged files, pure file-metadata changes). Those are
  exposed through a file-level escape hatch.
- The model does **not** manage Git snapshots or call a refresh action.
- The model does **not** reason in hunk IDs.
- Staging is a first-class operation, separate from commit.
- The same selectors used to inspect changes are also used to stage/commit them.
- `CodeTree.jl` must remain usable outside Git repositories. Git awareness is an
  overlay, not a prerequisite for `load`, `reload`, or `update_source!`.

## Terms and scope

- **`HEAD`** = committed repository state.
- **`index`** = staged state.
- **`worktree`** = on-disk working tree state.
- **`phase=:all`** means `HEAD -> worktree`.
- **`phase=:staged`** means `HEAD -> index`.
- **`phase=:unstaged`** means `index -> worktree`.
- Git-aware read APIs are scoped to files under `db.root`.
- In the default agent startup, `db.root` is the session workspace root, so this
  scope normally matches the repository root. The API should still behave
  sensibly if `db.root` is a subdirectory of a larger repository.
- A **selector** is either:
  1. a current `db.code.id`; or
  2. a repo-relative `path` returned by `git_file_status(db)`.
- Path selectors are always **whole-file** selectors.
- If a selector string matches a current `db.code.id`, it is treated as a node
  selector. Otherwise it is interpreted as a file-path selector.
- Node selection is **atomic at node granularity**: selecting a node means
  selecting all changes for the requested phase whose lines fall within that
  node's current span. There is no sub-node or hunk-level selection in this
  design.

## Proposed API

### `db.code` overlay columns

Add the following read-only columns to `db.code`:

| Column | Type | Description |
|---|---|---|
| `git_status` | `String` | `clean` or `modified` relative to `HEAD -> worktree` for the node's current span |
| `git_has_staged` | `Bool` | whether any part of the node differs in `HEAD -> index` |
| `git_has_unstaged` | `Bool` | whether any part of the node differs in `index -> worktree` |

Semantics:

- For leaf nodes, these columns describe the leaf's own span.
- For non-leaf nodes, they aggregate over the node's current span, including its
  declaration chunk and descendants.
- For `module` and `codebase` nodes, that aggregate must also include in-scope
  file-level changes under the subtree that have no current descendant node
  representation (for example deleted, binary, unmerged, or metadata-only file
  changes).
- Newly added or untracked nodes count as `git_status = "modified"`.
- Deleted files have no current node row, so they are only visible via
  `git_file_status(db)`.
- These values are session-scoped overlays. They must not be persisted into the
  SQLite cache and must remain directly non-mutable like the rest of `db.code`
  other than `summary`.

### Julia API

```julia
git_diff(
    db::CodeTreeDB,
    selector::AbstractString;
    phase::Symbol = :all,
)::String

git_diff(
    db::CodeTreeDB,
    selectors::AbstractVector{<:AbstractString};
    phase::Symbol = :all,
)::String

git_file_status(
    db::CodeTreeDB;
    phase::Symbol = :all,
)::DataFrame
```

- Invalid `phase` values must raise an informative error.
- `git_diff` and `git_file_status` are Git-aware APIs; if `db.root` is not
  inside a Git repository, they should fail informatively rather than pretending
  the repository exists.

### `git_file_status(db)` schema

Return one row per changed file in scope with at least:

| Column | Type | Description |
|---|---|---|
| `path` | `String` | primary file selector, relative to repository root |
| `db_file` | `String` | the same file path relative to `db.root` (same base as `db.code.file`) |
| `old_path` | `Union{String,Missing}` | previous repo-relative path for rename/copy cases in the requested `phase` |
| `status` | `String` | `modified`, `added`, `deleted`, `renamed`, `copied`, `type_changed`, `untracked`, or `unmerged` for the requested `phase` |
| `is_binary` | `Bool` | whether the change in the requested `phase` is binary |
| `is_indexed` | `Bool` | whether the current worktree file participates in `db.code` |
| `git_has_staged` | `Bool` | whether this file currently has staged changes |
| `git_has_unstaged` | `Bool` | whether this file currently has unstaged changes |

Phase/filter semantics:

- `phase=:all` returns files changed in `HEAD -> worktree`; `status` and
  `old_path` describe that combined delta.
- `phase=:staged` returns only files with staged changes; `status` and
  `old_path` describe `HEAD -> index`.
- `phase=:unstaged` returns only files with unstaged changes; `status` and
  `old_path` describe `index -> worktree`.
- `git_has_staged` and `git_has_unstaged` always describe the full current
  repository state, not just the filter that produced the row set.

This is the file-level escape hatch for changes that do not map cleanly onto a
current code node.

### `git_diff`

`git_diff` must:

- return a valid unified diff for the selected node/file or for the normalized
  union of selected nodes/files;
- accept mixed node-id and file-path selectors;
- order output deterministically by repo-relative path, then source order within
  each file;
- return `""` for a known selector whose selected region is clean in the
  requested `phase`;
- error on unknown selectors;
- deduplicate overlapping selectors cleanly;
- treat file-path selectors as whole-file selections even when the file is
  indexed and also has file/node rows in `db.code`;
- expand `module` and `codebase` selectors to the union of changed descendant
  file-backed nodes plus any in-scope changed file-path entries under the
  subtree that have no current node representation;
- normalize added/untracked descendant node selectors to the containing file
  selection;
- require deleted files to be selected by file path, not node id;
- fail informatively if any selected change is binary or unmerged, naming the
  offending selectors instead of fabricating textual diff content.

## Host-side tools

Replace the current hunk-based write workflow with:

```text
git_stage(what = "all" | [selector, ...])

git_commit(
  what = "staged" | "all" | [selector, ...],
  message = "<subject>",
  body = "<optional body>",
)
```

Required behaviour:

- Selector-based writes do **not** take a `phase` argument. They operate on the
  selector's full current change across staged and unstaged state, while
  preserving the exact state of all unselected changes.
- `git_stage("all")` stages all current changes in the session workspace,
  including untracked files and deletions.
- `git_stage([selector, ...])` stages exactly the selected changes.
- `git_commit("staged")` commits the current index as-is.
- `git_commit("all")` commits the full current workspace delta vs `HEAD`,
  staging whatever is required first.
- `git_commit([selector, ...])` commits exactly the selected changes using the
  same selector semantics as `git_stage`.
- Empty effective selections, missing staged changes for `"staged"`, or
  "nothing to commit" situations must fail informatively with no repository
  mutation.
- Path selectors are valid for any changed file and always mean "the whole file
  change".
- Binary, deleted, non-indexed, and metadata-only changes must still be
  stageable/committable by path selector even when `git_diff` cannot render them
  as text.
- Selections containing `unmerged` files must fail informatively until the
  conflict is resolved.
- `git_stage` and `git_commit` must either preserve the content and
  staged/unstaged state of every unselected change **exactly**, or fail
  atomically. They must never silently widen the selection.

The agent should use `git_diff(db, selectors; phase=...)` as the authoritative
textual patch for text-backed selectors, while still supporting file-path
selection for the non-text or no-current-node cases above.

## Freshness and persistence

- No explicit refresh function is exposed to the model.
- The Git overlay must not be written into the SQLite cache.
- Overlay state must be fresh after `load`, `reload`, `update_source!`,
  `git_stage`, and `git_commit`.
- External Git changes made outside Julia between tool calls must be visible on
  the next `julia_repl` call without the model taking any explicit refresh step.
- It is acceptable for the agent to refresh internal Git overlay state before or
  after `julia_repl`, `git_stage`, and `git_commit`; that lifecycle is an
  implementation detail, not part of the model-facing API.

## Non-Git workspaces

- `CodeTree.jl` loading/editing remains supported exactly as today outside Git
  repositories.
- The `db.code` overlay columns still exist and read as `clean`, `false`,
  `false`.
- `git_diff`, `git_file_status`, `git_stage`, and `git_commit` must fail
  informatively when no Git repository is available.

## Important edge cases

1. **Mixed staged + unstaged edits in one node**  
   The node shows both phase flags. `git_diff(...; phase=:all)` returns the
   combined patch. Selector-based `git_stage` / `git_commit` also treat the
   node's combined current change as the selected unit. Selection is still
   node-atomic.

2. **Deleted / binary / non-indexed / unmerged files**  
   These may have no useful current `db.code` row. They must still appear in
   `git_file_status(db)` and be selectable by `path`.

3. **Pure metadata-only file changes**  
   File-level selectors remain meaningful even when descendant code nodes are
   unchanged or absent.

4. **Added files with current nodes**  
   Newly added files may expose current `db.code` nodes and can be selected by
   node id, but path selection must still work and must mean whole-file
   selection.

5. **Selective writes must be preservation-safe**  
   Every unselected change must keep both its content and its
   staged-vs-unstaged placement exactly, or the operation must fail atomically.

## Affected design/docs/tests

- `design/codetree-requirements.md`
  - extend the `CodeTreeDB` API shape;
  - add the three `db.code` Git overlay columns;
  - specify `git_diff` and `git_file_status`;
  - specify freshness, scope, and non-persistence.
- `design/agent-requirements.md`
  - replace the model-facing host `git_diff` tool;
  - add `git_stage`;
  - change `git_commit` from hunk-id selection to selector-based operation with
    preservation guarantees.
- `design/repl-api-requirements.md`
  - likely no new REPL API of its own, beyond these `CodeTree.jl` functions
    being available in the persistent Julia session.
- `agent/config/system_prompt.md`
  - remove guidance that tells the model to use `git_diff` hunk IDs;
  - teach the selector-based Julia-first workflow.
- `agent/config/steering_message.md`, `agent/config/reflection_prompt.md`,
  `agent/README.md`
  - update tool names and workflow descriptions.
- Tests
  - `CodeTree.jl/test/` for overlay columns, `git_diff`, `git_file_status`,
    non-Git behaviour, and freshness;
  - `agent/test/` for tool definitions, selector-based staging/commit, failure
    modes, and preservation guarantees.

## Non-goals for the first implementation

- model-facing hunk IDs;
- a separate `db.git_status` / patch-tree table or any second CodeTree-shaped
  diff table;
- a model-facing snapshot or refresh action;
- a separate staged-only semantic surface distinct from the unified
  `HEAD -> worktree` surface;
- indexing the Git index as a second CodeTree snapshot;
- arbitrary partial selection smaller than the current node granularity.

## Closed in session

❯ copilot         
  ╭─╮╭─╮   Changes   +2763 -771
  ╰─╯╰─╯   Requests  1 Premium (1h 32m 22s)
  █ ▘▝ █   Tokens    ↑ 36.6m • ↓ 184.5k • 35.8m (cached) • 121.6k (reasoning)
   ▔▔▔▔    Resume    copilot --resume=c937d9e6-9479-42b7-8987-e286b010ad4b

