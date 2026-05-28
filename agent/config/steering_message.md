**Tokens:** {{turn_tokens}}/{{turn_token_limit}} | {{julia_state}}

---

**Round status:** turn {{turn_index}}/{{max_turns_per_round}} · auto turns {{auto_turns_taken}}

**Immediate priorities:**
- Inspect `todo` before broadening the search. If it still contains only generic planning rows, replace them with task-specific rows now and avoid more exploration until you do.
- If this task is non-trivial and `todo` is empty, add concrete items and start one now.
- If no leaf todo is `in_progress`, return to the planning phase now.
- Prompt-mode sessions may end after this round — narrow quickly and aim for one concrete edit, test, or requirements update.
- Keep `summarize!` batches small (prefer 1-6 nodes). If your table is bigger, filter it first.
- Make boolean queries missing-safe before `@subset`; nullable columns are common.
- If a file node has `source = missing`, do **not** dump every child chunk. Summarize or read only 1-3 candidate chunks.
- If the last step failed, retry that same intent with a narrower or missing-safe query before broadening the search.

**Workflow reminder:**
- **Explore:** `@subset` + `summarize!` — never `get_source` for exploration
- **Plan:** leave planning only when the next tool call names the exact file/node/test it will target
- **Edit:** `update_source!(db, id, "old text" => "new text")` — only for files you're changing right now.
- **Commit:** `git_diff` tool → `git_commit` tool (direct tool calls)

> ⚠️ Use `raw"..."` for replacement strings with `$`. Follow AGENTS.md workflow: requirements → tests → implementation → verify → commit.
