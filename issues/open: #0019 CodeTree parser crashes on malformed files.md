# #0019 — CodeTree parser crashes on malformed files

## Summary

`CodeTree.load()` and `CodeTree.reload()` do not catch per-file parse errors.
When any file in the workspace triggers a parser error (especially the
markdown parser), the entire load/reload throws an exception instead of
gracefully skipping or degrading that file.

## Reproduction

Edit a markdown file so that `---` appears directly after a paragraph without
a blank line:

```markdown
Some paragraph text
---
```

This causes `_scan_markdown_blocks` and `Markdown.parse` to disagree on the
block count, throwing "Markdown block scan mismatch".

## Impact

Because the agent runner (`ToolExecution.purs:400-415`) calls
`CodeTree.reload(db)` before every tool call, a single malformed file in the
workspace makes every subsequent tool call fail — even `1+1`. The agent
cannot recover because reload runs in the preamble before user code executes.

This effectively bricks the entire session.

## Expected behavior

`load()` and `reload()` should catch parse errors on individual files and
either:
- Skip the file and log a warning, or
- Include the file with degraded information (e.g. a single root chunk with
  no children)

The CodeTree should be able to work with syntactically incorrect or
otherwise unparseable files without crashing.

## Workaround

Currently worked around with a monkey-patch in `startup.jl` that wraps
`CodeTree.reload` in a try/catch.

## Location

- `CodeTree.jl/src/parser.jl:29-39` — `parse_markdown_blocks` throws on mismatch
- `CodeTree.jl/src/load.jl:35-39, 111-119` — catches file read errors but not parse errors
- `CodeTree.jl/src/load.jl:201-207` — `reload()` calls `load()` with no protection
