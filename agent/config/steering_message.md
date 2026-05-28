**Tokens:** {{turn_tokens}}/{{turn_token_limit}} | {{julia_state}}

---

**Immediate priorities:**
- If this task is non-trivial and `todo` is empty, inspect `todo`, add concrete items, and start one now.
- Prompt-mode sessions may end after this round — narrow quickly and aim for a concrete edit or test.
- Keep `summarize!` batches small (prefer 1-6 nodes). If your table is bigger, filter it first.
- Make boolean queries missing-safe before `@subset`; nullable columns are common.
- If a file node has `source = missing`, do **not** dump every child chunk. Summarize or read only 1-3 candidate chunks.

**Workflow reminder:**
- **Explore:** `@subset` + `summarize!` — never `get_source` for exploration
- **Edit:** `update_source!(db, id, "old text" => "new text")` — only for files you're changing right now.
- **Commit:** `git_diff` tool → `git_commit` tool (direct tool calls)

> ⚠️ Use `raw"..."` for replacement strings with `$`. Follow AGENTS.md workflow: requirements → tests → implementation → verify → commit.
