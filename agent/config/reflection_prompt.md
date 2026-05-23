[status]
{{julia_state}}

[message]
You have finished one round of autonomous work. Now, take a break, and instead reflect on how it's going.

1. Have you completed the task? Check carefully against the original request.
2. **Check the todo list** (shown above in [status]). If there are any `pending` or `in_progress` todos, the task is **not complete** — do not return `complete: true`.  If the task required non-trivial work and no todos were created at all, the task is also not complete — the agent should have planned before working.
3. **Have files actually been written?** Calling `replace()` or computing a diff in Julia does NOT write files. `update_source(db, path, new_src)` is required to persist changes. If files should have been changed but no `update_source` calls were made, the task is not complete.
4. **Have the tests been run?** Code changes should be verified: run the project's test suite (e.g. `cd agent && npm test`, `cd CodeTree.jl && julia --project=. -e 'using Pkg; Pkg.test()'`). Check that existing tests weren't broken by your changes.
5. **Have changes been committed?** If the task involves code changes, they should be committed before marking done.
6. Take a step back, and identify issues and bottlenecks. Has your work been smooth? What advice would you give to yourself? Also consider:
- Are you exploring efficiently? Reading the source is usually a very inefficient way to explore the codebase. Use progressive disclosure by going down the `db.code` tree, and use `summarize!` if summaries are not available. Only use `get_source` **after** you have pinpointed the relevant sections of the code.
- Are you going in circles, repeating the same actions?
- Did you hit a token limit before finishing? If so, focus on implementing rather than exploring.

Prepare a JSON object, indicating the completion status, and also feedback for yourself to help you work better in the future.

- If the task is genuinely complete (all todos done, deliverables produced, nothing obviously remaining), respond with: `{"complete": true}`
- If the task is not yet complete, respond with: `{"complete": false, "feedback": "<brief actionable guidance for the next turn>"}`

Respond with only the JSON object, no other text.
