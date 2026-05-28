[status]
{{julia_state}}

[message]
You have finished one round of autonomous work. Reflect on progress, then output a JSON status object.

**Output format — your entire response must be exactly one of these, with no other text, no markdown, no code fences:**
- `{"complete": true}` — task is fully done
- `{"complete": false, "feedback": "..."}` — task is not done; feedback is brief actionable guidance for the next turn

Evaluate the following before deciding:

1. **Task complete?** Check carefully against the original request.
2. **Todos done?** (See [status] above.) Any `pending` or `in_progress` todos → not complete. No todos created for non-trivial work → not complete.
3. **Files actually written?** `update_source!(db, id, pattern => repl)` is required. If expected file changes are missing → not complete.
4. **Only task-relevant files changed?** Off-task edits do not count as progress.
5. **Tests run?** Check `AGENTS.md` for instructions. If tools are unavailable, note it and do not block — commit what's verified.
6. **Changes committed?** If `git_diff` would show uncommitted changes → **NOT complete**. You must commit before marking complete. Use `git_diff` tool then `git_commit` tool.
7. **Planning discipline:** Did you finish the planning phase before broad exploration? Is there exactly one current focus, with an `in_progress` todo that matches it? If not, you are **not done**.
8. **Efficiency issues to correct:** Did you re-read a file after `update_source!` (the diff output already confirmed the edit)? Did you use `read()` or `open()` instead of `update_source!`? Did you call `summarize!` on a broad set instead of a shortlist, dump every chunk of a file because `row.source` was `missing`, or forget to make nullable-column queries missing-safe? If so, note it in feedback so next round avoids these patterns.
9. **Workflow discipline:** If you did not inspect/create todos for non-trivial work, if the active todo and actual work diverged, or if you ended the round with only broad exploration and no narrowed next target, you are **not done**.

**CRITICAL: If there are file changes that haven't been committed, output `{"complete": false, "feedback": "Commit pending changes with git_commit"}` — never mark complete with uncommitted work.**

When incomplete, make the feedback point to the next concrete action, ideally
with the exact file / node / chunk / test to target next.

Now output the JSON:
