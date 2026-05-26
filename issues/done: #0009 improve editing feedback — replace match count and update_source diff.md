# Redesign editing: `update_source!` as pattern substitution

## Problem

The previous approach (`replace` + `update_source`, now reverted) had multiple
failure modes observed across test sessions:

1. **Indentation mismatch** — model reconstructed the search string from memory
   with wrong leading whitespace; `str_replace` returned 0 matches silently.
2. **Raw string delimiter collision** — target code containing `"""` broke the
   `raw"""..."""` Julia string literal used to encode the search string.
3. **Stale search string** — after editing a function signature, the model
   searched for the old call-site text that no longer existed.
4. **Verbose diff** — `update_source` diff showed `+128/-123 lines` for a
   5-line insertion due to an LCS bug (inverted backtracking condition in
   `_line_diff`).

## Design

### `update_source!(db, id, pattern => repl [; count=1])`

`update_source!` replaces `update_source` entirely as the public mutation path.
It combines the search-and-replace step with the re-indexing step:

```julia
update_source!(db, "agent/src/Runner/ToolExecution.purs:handle_tool",
    "UnknownToolName other ->" =>
    "RestartRepl -> pure \"restarted\"\n        UnknownToolName other ->")
```

The function:
1. Looks up node `id` to determine its file and span.
2. Reads the current source for that node from the in-memory buffer via
   `get_source`.
3. Searches for `pattern` within that node's source (see below).
4. Throws `ArgumentError("update_source!: pattern not found in <id>")` if there
   are zero matches.
5. If the actual match count exceeds `count`, prints a warning naming all match
   locations and replaces only the first `count` occurrences.
6. Applies the substitution and delegates to the existing internal
   `_update_source!` logic — R30a–R35 all still apply.
7. Prints a compact unified diff of the changed file(s) to stdout.

Pass the most specific node containing the edit target (a function or chunk,
not the whole file) to minimise ambiguous-match risk.

### Indentation-agnostic matching (string patterns only)

When `pattern` is a plain `String` (not a `Regex`), matching is
**indentation-agnostic**:

- **Dedent the pattern**: strip its minimum common leading whitespace from every
  line.
- Search the node source for the dedented pattern, ignoring absolute indentation
  but preserving relative indentation between lines.
- Detect the actual indentation offset of the match in the source.
- **Dedent the replacement**: strip its minimum common leading whitespace, then
  re-indent every line by the detected offset.

When `pattern` is a `Regex`, behaviour is identical to `Base.replace` (no
indentation normalisation). The zero-match and over-match safety behaviours
(steps 4–5 above) apply regardless of pattern type.

### `count` keyword

`count=N` means replace at most N occurrences (same semantics as
`Base.replace`). Default is 1. A warning is printed whenever the actual match
count in the node source exceeds N.

### Diff output

After every successful edit, print a unified diff of the changed file to stdout:

- Standard unified diff format (`--- a/…`, `+++ b/…`, `@@ -L,N +L,N @@`
  hunks).
- 3 lines of context around each changed hunk.
- Full-file scope (not just the node span), so absolute line numbers are
  immediately verifiable.
- Not printed on error (zero-match throw or any other failure).

## Requirements changes

The following changes are needed before implementation (AGENTS.md Step 1):

**`codetree-requirements.md`:**

- **API Shape section**: replace the `update_source(db, id, new_source)` entry
  with `update_source!(db, id, pattern => repl; count=1)`.
- **R20**: update the reference from `update_source` to `update_source!`.
- **R30**: rewrite to describe the pattern-substitution API, the `count`
  keyword, and the delegation to the internal `_update_source!` implementation.
- **R36** (new): after a successful edit, `update_source!` prints a compact
  unified diff (full file, 3-line context) to stdout.
- **R37** (new): for string patterns, matching and replacement are
  indentation-agnostic — dedent the pattern, search, detect offset, dedent then
  re-indent the replacement.
- **R38** (new): zero matches throws `ArgumentError`; when actual match count
  exceeds `count`, a warning naming all match locations is printed and only the
  first `count` occurrences are replaced. Match locations are reported as
  `line L` for string patterns and `line L, chars M:N` (character range within
  that line) for `Regex` patterns.

**`repl-api-requirements.md`:**

- Update the reference in the Roles and Boundaries section from `update_source`
  to `update_source!`.

## Motivation

- Eliminates the two-step boilerplate and the wrong-syntax failure mode.
- Indentation-agnostic matching eliminates the most common zero-match failure
  (wrong indent reconstruction by the model).
- Node-scoped search reduces ambiguous-match risk.
- Throwing on zero matches makes silent no-ops impossible — every call either
  changes the file or raises an error.
- Accurate unified diffs give the model immediate self-verification feedback,
  eliminating post-edit `get_source` re-reads.
