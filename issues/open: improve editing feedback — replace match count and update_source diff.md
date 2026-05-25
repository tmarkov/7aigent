# Improve editing feedback: replace match count + update_source diff

Two small improvements to make editing errors self-evident, reducing the
re-read cycles the model falls into when a replacement silently misses.

## 1. REPL API: overwrite `replace` for strings to report match count

In `sandbox/startup.jl` (or the appropriate SevenAigentREPL module), shadow
Julia's `Base.replace` for `String` arguments so that it prints the number
of substitutions made before returning:

```julia
# Desired behaviour
src = replace(src, "old pattern" => "new text")
# stdout: replaced 1 occurrence(s)

src = replace(src, "typo" => "fix")
# stdout: replaced 0 occurrence(s)   ← model immediately knows the edit failed
```

This makes silent no-op replacements visible without requiring the model to
write `@assert` on every call, and eliminates the need to re-read the file to
confirm an edit landed.

Implementation note: `replace(s::AbstractString, ...)` should print to stdout
and return the result unchanged so the assignment still works normally.

## 2. CodeTree: `update_source` should print a diff

After writing the file, `update_source` should print a compact diff of what
changed, e.g. using `Diff` or a simple line-by-line comparison:

```
update_source: agent/src/Agent/Services/Jupyter.purs (+12 / -3 lines)
  + restartKernel :: KernelHandle -> Aff KernelHandle
  + restartKernel handle = do
  ...
```

This gives the model immediate confirmation that the correct lines changed,
again without a follow-up `get_source` to verify.

## Motivation

In observed sessions the model reads the same file 10–18 times, mostly in
retry loops caused by silent replace failures and post-write verification
reads. Both changes make the feedback loop tight enough that a single
get_source → replace → update_source cycle is self-verifying.
