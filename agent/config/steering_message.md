**Tokens:** {{turn_tokens}}/{{turn_token_limit}} | {{julia_state}}

---

**Exploration** = `@subset` + `summarize!` only — no file reads.
**Editing** = `update_source!(db, id, "old text" => "new text")` — only for files you're changing right now.
**Committing** = `git_diff` tool → `git_commit` tool (direct tool calls, not `run()` in the REPL).

> If you already know what to implement: **stop exploring and start writing code.**
> If summaries are missing: call `summarize!` — never read the file just to understand it.
> Each round without a file change is wasted — exploration without implementation is not progress.
