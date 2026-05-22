**Tokens:** {{turn_tokens}}/{{turn_token_limit}} | {{julia_state}}

---

**Exploration** = `@subset` + `summarize!` only — no file reads.
**Editing** = `get_source` → `update_source` — only for files you're changing right now.

> Once summaries answer your question, implement. Reading a file you won't immediately edit wastes context.
