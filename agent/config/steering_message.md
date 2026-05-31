**Tokens:** {{turn_tokens}}/{{turn_token_limit}} | {{julia_state}}

---

**Round status:** turn {{turn_index}}/{{max_turns_per_round}} · auto turns {{auto_turns_taken}}

**Immediate priorities:**

- Check the active todo leaf. If it is abstract, multi-file, or architecture-wide, rewrite/refine it now.
- If startup just moved you onto a seeded placeholder, mutate that leaf before browsing.
- If the task already names an exact issue, requirement, heading, file, symbol, or function, inspect that anchor before neighboring files.
- Prefer `db.symbols` -> narrowed `db.code` -> small `summarize!` batches. Keep `summarize!` to 1-6 rows.
- Use `show_matches(...)`, `show_md_section(...)`, or `show_lines(...)` for docs before whole-file reads.
- `show_matches(...)` is plain substring search, not regex. Query one exact string at a time.
- For source exploration, do not use whole-file `read()`. First narrow to one node or a <=3 item shortlist, then inspect `row.source` or one chunk.
- After `todo_refine_current!(...)`, the first new child is already active. Work it now.
- After `todo_next!()`, use the printed tree instead of calling `status()` again unless you manually changed `todo`.
- If you already spent about 8-10 tool calls on the current target without an edit or test, stop browsing and act.
- Keep narration minimal between routine tool calls.
- For Git work, inspect Julia selectors first; use path selectors from `git_file_status(db)` for deleted, binary, unmerged, non-indexed, or metadata-only changes. Do not use hunk IDs, and do not pass `phase` to `git_stage` or `git_commit`.

**Workflow reminder:**

- Guide files / issue doc -> `status()` / `todo`
- Concrete leaf -> `db.symbols` / `db.code` / `summarize!`
- Exact target -> targeted read
- Edit tracked files with `update_source!`; new files with `open(path, "w") do io; write(io, content); end`
- Verify and commit per `AGENTS.md`

**Error recovery:**
- If the same error appears 3+ times, stop retrying immediately. Note what's blocked and move to the next todo.
- `MethodError`/`FieldError` on `db` after `include()` on package source = unrecoverable. Use file I/O only from that point.
