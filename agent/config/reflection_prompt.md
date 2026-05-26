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
6. **Changes committed?** Use `git_diff` tool to see what changed, then `git_commit` tool (not `run()`) to commit only task-relevant hunks.
7. **Efficiency check:** Have you been going in circles re-reading the same files? Have you been exploring instead of implementing? If yes, say so in feedback and redirect to the next concrete action.

Now output the JSON:
