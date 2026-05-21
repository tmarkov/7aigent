# `get_source` result is silently truncated by Julia's string repr

## Summary

When `get_source(db, id)` is called as the last expression in a REPL cell
(without `println`), Julia displays the result using its built-in string repr,
which silently truncates long strings to a few hundred characters with a
`⋯ N bytes ⋯` placeholder. The model receives a truncated string that *looks*
like a complete result but is missing most of the file content.

## Example

```julia
get_source(db, "agent/src/Agent/Runner/Session.purs")
# → "module Agent.Runner.Session\n    ...\n" ⋯ 24981 bytes ⋯ "    pure unit\n}"
```

The model sees only the first and last few hundred characters; the middle
24 KB of the file is hidden. Because the output does not say "truncated", the
model may believe it has seen the whole file and proceed with incorrect edits.

## Root cause

Julia's default `show(::String)` method truncates long strings. The truncation
threshold is controlled by Julia's internal display context, not by the
agent's `output_threshold_chars` config. The agent's threshold only applies
to the total cell output — it does not trigger a clear "too large" error for a
single string value that happens to be long.

The correct pattern is:

```julia
src = get_source(db, "agent/src/Agent/Runner/Session.purs")
println(src)   # prints the full string; hits output_threshold_chars if truly too large
```

## Impact

Observed in multiple experiment runs: model calls `get_source` without
`println`, silently receives a truncated file, then produces incorrect edits
because it is working from an incomplete view of the file.

## Fix options

1. **In Display.jl / startup.jl**: override `Base.show(::IO, ::String)` so
   that long strings print a clear "use println() to see the full content"
   message rather than a silent ellipsis.

2. **In `get_source` itself**: return the string wrapped in a custom type that
   has a `show` method producing the above message, while `println` (which
   calls `print` not `show`) still outputs the raw content.

3. **Documentation / system prompt**: instruct the model to always use
   `println(get_source(...))`. (Partial mitigation — does not fix the
   underlying display problem.)

## Affected files

- `sandbox/SevenAigentREPL/Display.jl` or `agent/config/startup.jl`
  (for a display override fix)
- `CodeTree.jl/src/CodeTree.jl` (for a wrapper type fix)
