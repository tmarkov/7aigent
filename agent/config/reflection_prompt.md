[status]
{{julia_state}}

[message]
You have finished one autonomous round. Reflect using the actual latest tool
results plus the current Julia status, then output a JSON status object.

**Output format — your entire response must be exactly one of these, with no other text, no markdown, no code fences:**
- `{"complete": true}`
- `{"complete": false, "feedback": "..."}`

Use these rules:

1. Base your decision on what already happened in the visible history and
   `[status]`. Never ask to repeat a prerequisite that is already complete
   (for example reading the task/issue, listing a directory, or opening a file
   that was already read).
2. If any todo is `pending` or `in_progress`, the task is not complete. If the
   task was non-trivial and no todos were created, it is not complete.
3. If fewer than 10 tool calls have been made in total, the task is almost
   certainly not complete — output `{"complete": false}` with concrete next step.
4. Check `AGENTS.md` for required design/tests/checks. If those are still
   missing, the task is not complete.
5. If expected file changes are missing, the task is not complete.
6. If file changes exist but are not committed, the task is not complete. In
   that case output exactly
   `{"complete": false, "feedback": "Stage and commit pending changes"}`.
7. For Git work, inspect state through Julia selectors
   (`db.code.git_*`, `git_file_status(db; phase=...)`, `git_diff(...)`) and
   remember that selector-based `git_stage` / `git_commit` writes have no
   `phase`.
8. If the round mostly explored without narrowing to one exact next target,
   feedback must name the specific file, node, test, or requirement section to
   target next.
9. If the round used broad whole-file reads, skipped `db.code` / `db.symbols`,
   drifted from the active todo, or kept planning without acting, say so
   briefly and point to the corrected next step.
10. If the same error repeated 3+ times in the round, feedback must say "stop
    retrying that approach" and name a concrete alternative (e.g. skip the
    blocked step and move to the next todo, use direct file I/O instead of a
    broken REPL function).
11. Keep feedback short and actionable. Prefer one concrete next action over
    generic advice like "plan more" or "understand the architecture".

Now output the JSON:
