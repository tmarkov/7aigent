**Tokens:** {{turn_tokens}}/{{turn_token_limit}} | {{julia_state}}

---

**Round status:** turn {{turn_index}}/{{max_turns_per_round}} · auto turns {{auto_turns_taken}}

**Immediate priorities:**
- If you just finished reading guide files, the very next tool call should be `status()`, `todo`, `todo_next!()`, or a focused todo mutation — not requirements/code reading.
- Inspect `status()` before broadening the search. If the current leaf is still a placeholder, refine it into task-specific structure now.
- `todo_next!()` already re-renders the tree. Use that updated current path before calling `status()` again.
- If the current leaf is the seeded target-selection placeholder, usually replace it in place with `todo_rewrite_current!(...)`. Use `todo_refine_current!(...)` only when you truly need a short 1-2 candidate comparison. Do not append unrelated top-level rows.
- If `todo_next!()` just moved you onto that seeded target-selection placeholder, the very next call should be `todo_rewrite_current!(...)` or `todo_refine_current!(...)` — not `root_nodes`, not `@subset`, and not `summarize!` yet.
- If the active leaf still reads like broad exploration ("explore architecture", "understand X", "read A and B to understand architecture", a whole module/directory), you are still planning. Refine again until it names one exact file/node/test, requirement section, or one short 1-2 candidate comparison.
- If the active leaf names multiple docs/files, refine again unless it is an explicit 1-2 candidate comparison.
- If the current leaf is a target-selection leaf and you already have enough context to act, stop exploring under it. Use `todo_next!()` to move into the execution leaf, rewrite that leaf if needed, and do the actual change.
- If the task or active leaf already names an exact requirement ID, heading, symbol, or function, use `show_matches(...)`, `show_md_section(...)`, or `show_lines(...)` on that exact file before opening neighboring docs/files.
- If the active leaf names a requirement/design section, use `show_matches(...)`, `show_md_section(...)`, or `show_lines(...)` to read just that section. Do not read the whole document unless it is already small.
- If `todo_refine_current!(...)` just created concrete child leaves, work the first child now instead of continuing to browse under the parent.
- If this task is non-trivial and `todo` is empty, add concrete items and start one now.
- If no leaf todo is `in_progress`, return to the planning phase now.
- Prefer refining the current leaf into children over clearing the whole todo tree. Avoid `empty!(todo)` on a valid plan.
- Prefer `todo_next!()` after finishing a leaf; it keeps parent completion state in sync.
- If you added a mistaken pending leaf, prefer `todo_delete!(id)` over manual DataFrame surgery.
- Prompt-mode sessions may end after this round — narrow quickly and aim for one concrete edit, test, or requirements update.
- If the round is already well underway and you still have no edit or test, stop gathering broad context and make the smallest reversible change on the exact target already named.
- Keep `summarize!` batches small (prefer 1-6 nodes). If your table is bigger, filter it first.
- Summarizing a directory or file survey at the file-row level is fine; avoid mixed file-plus-descendant sweeps, especially from broad `id` matching.
- If a listing returned many rows, the next call must narrow to <=3 candidates or one exact target unless you are intentionally summarizing just the file rows of that survey.
- `db.symbols` columns are `node_id`, `symbol`, and `kind`. If the symbol table is sparse for this language, fall back to a 1-3 file/chunk shortlist instead of a broad sweep.
- Make boolean queries missing-safe before `@subset`; nullable columns are common.
- Within `@subset`, prefer separate predicates like `@subset(df, cond1, .!ismissing.(:source))` over `.&&` on nullable columns.
- If a file node has `source = missing`, inspect child rows with separate missing-safe predicates. Do **not** dump every child chunk or fall back straight to a whole-file `read()`.
- Do not sweep a file by looping over many chunk ids to print source; that is a whole-file read in disguise.
- If `summarize!` is printing progress for a focused, legitimate batch, let it finish unless the selection is clearly wrong.
- Whole-file `read()` on non-guide docs/source is a last resort once you know the file. Prefer `show_matches(...)`, `show_md_section(...)`, `show_lines(...)`, or tree rows.
- If `show_md_section(...)` failed, stay on that same file and retry with `show_matches(...)` or `show_lines(...)` before broadening to a whole-file read or a wider search.
- If a whole-doc read truncated, do not retry the same whole file. Narrow to a heading, match, or line range.
- If the last step failed, retry that same intent with a narrower or missing-safe query before broadening the search.

**Workflow reminder:**
- **Explore:** `@subset` + `summarize!` — never `get_source` for exploration
- **Plan:** leave planning only when the next tool call names the exact file/node/test it will target
- **Edit:** `update_source!(db, id, "old text" => "new text")` — only for files you're changing right now.
- **Commit:** `git_diff` tool → `git_commit` tool (direct tool calls)

> ⚠️ Use `raw"..."` for replacement strings with `$`. Follow AGENTS.md workflow: requirements → tests → implementation → verify → commit.
