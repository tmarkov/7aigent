# CodeTree.jl Requirements

## Overview

`CodeTree.jl` is a Julia package that parses a codebase into two queryable,
navigable DataFrames — `code` (the tree) and `symbols` (external identifier
references) — and keeps them in sync with the source files on disk.

---

## API Shape

These architectural decisions are requirements, not implementation details.

- **`CodeTreeDB`** — a container struct bundling `code`, `symbols`, the
  codebase root path, and the language config. This is what `load` returns
  and what `update_source` operates on.

- **`CodeTree <: AbstractDataFrame`** — the `code` table, exposed as a
  queryable DataFrame. All DataFrames.jl query, filter, grouping, and join
  operations work on it. Direct mutation is forbidden except for the `summary`
  column, which higher-level tools may update in place for session-scoped
  annotations.

- **`CodeSymbols <: AbstractDataFrame`** — the `symbols` table, with the
  same read-only contract.

- **`load(path[, config]) -> CodeTreeDB`** — the entry point. Parses or loads
  from cache. When `config` is omitted, the package uses its built-in default
  config for the languages it ships with.

- **`reload(db)`** — re-runs full file discovery and incremental re-indexing
  in-place on an existing `CodeTreeDB`, using the `path` and `config` already
  stored in `db`. Equivalent to calling `load` again but updates `db` directly
  rather than returning a new object. Used to resync after external changes to
  the codebase.

- **`get_source(db, id) -> String`** — returns the current source text for any
  node span from the in-memory buffer. For leaf nodes this matches the `source`
  column; for non-leaf nodes it reconstructs the span on demand.

- **`update_source(db, id, new_source)`** — the sole mutation path. Updates
  both `db.code` and `db.symbols` together.

---

## Requirements

### Schema

**R1** — `db.code` has the following columns:

| Column | Type | Description |
|--------|------|-------------|
| `id` | String | Unique node identifier (e.g. `engine/search.py:Searcher._minimax`). When two sibling nodes share the same qualified name, they are disambiguated with an ordinal suffix: the first keeps the base id, the second becomes `…name$2`, the third `…name$3`, and so on, ordered by ascending `line_start`. |
| `parent` | String? | Parent node id; `missing` for the root |
| `depth` | Int | Distance from root (0 = codebase, 1 = module, 2 = file, …) |
| `sibling_order` | Int | Position among siblings, by `line_start` |
| `kind` | String | Node kind (see below) |
| `name` | String | Short identifier |
| `qname` | String? | Qualified name (dot-joined path from root); unique across `db.code`. When two sibling nodes share the same qualified name, the same ordinal suffix rule as `id` applies: the first keeps the base qname, the second becomes `…name$2`, etc. |
| `language` | String? | Programming language, inherited from the file node |
| `summary` | String? | 1–3 sentence documentation-derived description populated during indexing; `missing` if no docstring, comment, or README summary is found. Higher-level tooling may replace this value in memory with a session-scoped summary override. |
| `source` | String? | Full source text; populated only for leaf nodes (`n_children = 0`). `missing` for all non-leaf nodes; callers use `get_source(db, id)` to retrieve source text for any node. |
| `signature` | String? | Declaration line only; `missing` for non-declarative nodes |
| `file` | String? | Relative file path from codebase root |
| `line_start` | Int? | First line in the file |
| `line_end` | Int? | Last line in the file |
| `n_lines` | Int? | Stored for query convenience; must always equal `line_end - line_start + 1`. Any code path that sets `line_start` or `line_end` must update `n_lines` accordingly. |
| `n_children` | Int | Number of direct children |

Node kinds: `codebase`, `module`, `file`, `class`, `function`, `loop`,
`conditional`, `try`, `with`, `import`, `variable`, `type`, `comment`,
`chunk`.

**R2** — `db.symbols` has the following columns:

| Column | Type | Description |
|--------|------|-------------|
| `node_id` | String | FK to `db.code`; always a leaf node (`n_children = 0`) |
| `symbol` | String | Identifier name |
| `kind` | String | `call` — a function or method called; `var_ref` — a variable read that is not defined within this leaf |

---

### Read-only Protection

**R3** — All DataFrames.jl read and query operations (filtering, grouping,
joining, `@subset`, etc.) work on `db.code` and `db.symbols`.

**R4** — Any attempt to directly mutate `db.symbols`, or any column of
`db.code` other than `summary`, raises an informative error directing the
caller to use `update_source` for code edits.

**R4a** — Direct writes to `db.code.summary` are allowed. They update the
current in-memory `CodeTreeDB` in place, record a session-scoped summary
override keyed by node id, and do not write through to the SQLite cache.

---

### Loading

**R5** — `load(path[, config])` discovers all source files under `path`,
skipping ignored paths (`.gitignore` rules, `.7aigent/`, build artifacts,
binary files). If `path` is a git repository, discovery uses
`git ls-files --cached --others --exclude-standard`, which includes both
tracked files and untracked files that are not gitignored. This ensures
newly created files are indexed before they are committed.

**R6** — Each file gets a `kind=file` node; each directory containing source
files gets a `kind=module` node; there is exactly one `kind=codebase` root.

**R7** — Language is detected from file extension.

**R8** — Files with no entry in the language config, or with no available
tree-sitter grammar, are loaded without compound parsing. The file still gets
its `kind=file` row, but if it contains any non-blank lines those lines are
split into `kind=chunk` child leaves using runs of blank lines as separators.
Separator blank lines are absorbed into the neighbouring chunk so no
`kind=chunk` row consists only of blank lines. If the file is entirely blank,
the file node remains a leaf.

---

### Language Config

The package defines the config structure and ships a built-in
`DEFAULT_CONFIG` covering the languages supported in-tree. Callers may pass
their own config explicitly to override or extend that default.

**R9** — The config maps parser AST node type names to `(class, kind)` per
language, where `class` is either `landmark` or `detail`. Node type names
are parser-specific strings (e.g. tree-sitter grammar names for most
languages; Julia `Markdown` stdlib type names for Markdown files).

**R9a** — Each language entry in the config declares two sets of AST
patterns used for symbol extraction:
- **Call patterns**: AST query patterns that identify the name of a called
  function or method. Each match produces a `kind="call"` row in
  `db.symbols`.
- **Definition patterns**: AST query patterns that identify names being
  bound (e.g. assignment left-hand sides, loop variables, `with`-as
  variables, explicit declarations). These are used to determine which
  identifiers are locally defined within a leaf node, so that only
  externally-sourced variable reads become `kind="var_ref"` rows.

**R10** — **Landmark nodes** always produce their own row in `db.code`.

**R11** — **Detail nodes** only produce a row when their parent node spans
more than `detail_threshold` lines.

**R12** — `detail_threshold` is a single global integer, set as an option to
`load`. The default is 30 lines.

**R13** — The config format applies uniformly to all languages. Markdown files
are parsed using Julia's stdlib `Markdown` module; the landmark/detail
classification for Markdown node types is specified in the config, not
hardcoded in the package.

---

### Tree Structure and Spanning

**R14** — For any non-leaf node, its children's `(line_start, line_end)`
ranges are non-overlapping and collectively cover **every line from the
parent's `line_start` to `line_end` inclusive** (the spanning invariant).
The declaration line(s) of a compound node are always covered by the first
chunk child of that node.

**R14a** — When two sibling compound nodes share a line (the tree-sitter byte
range of one ends on the same line that the byte range of the next begins),
that line is assigned to the **second** node: the first node's `line_end` is
set to `line_start(second) − 1`. The second node's `source` therefore begins
at the shared line, which may include closing delimiters from the preceding
node that appear before the second node's opening token (e.g. `} else if`).
This rule matches natural reading: `} else if () {` opens the else-if branch
and belongs to it, not to the preceding block.

**R14b** — **Leading comment absorption.** When a compound node is
immediately preceded — at the same tree level — by a contiguous comment
block where no blank line separates the last comment line from the
declaration line, that compound node's `line_start` is extended backward to
the first line of the comment block. Those comment lines are not separate
siblings at the parent level; they are absorbed into the compound node's
span and appear as the leading content of its first chunk child. This is
consistent with R18: the same adjacency criterion that identifies the
comment block for summary extraction also determines whether the comment
belongs to the function's span.

**R14c** — **Trailing blank-line absorption.** After leading comments have
been absorbed per R14b, any remaining blank-only lines that fall between
consecutive siblings are assigned to the **preceding** sibling: that
sibling's `line_end` extends to cover them. No `kind=chunk` node may consist
entirely of blank lines.

**R15** — Gaps between compound children — lines not covered by any landmark
or detail child, and not blank-only (those are handled by R14c) — are filled
with `kind=chunk` nodes. Chunks are always leaves. This includes the
declaration line(s) of a compound node (which, together with any absorbed
leading comment, form the first chunk child of that node) and any trailing
non-blank lines after the last compound child.

**R16** — Siblings are ordered by ascending `line_start`
(`sibling_order = 0, 1, 2, …`). For structural nodes without a source line
(the `codebase` root, `module` nodes, and `file` nodes that are siblings of
other files), `sibling_order` is determined by ascending `name`
(case-sensitive lexicographic order).

---

### Documentation-Derived Summaries

Throughout R17–R20a, **"summary lines"** means lines that contain at least
one alphanumeric character (`[A-Za-z0-9]`), after stripping leading comment
markers (`//`, `#`, `*`, `/*`, `*/`, `///`, and combinations thereof) and
surrounding whitespace. The first three such lines are joined with a single
space to form the summary.

**R17** — For functions, methods, and classes: a docstring (the first string
literal in the body) is used as the summary, using the summary-lines rule
above.

**R18** — If no docstring is found, a comment block immediately preceding the
node (no blank line between comment and declaration) is used, applying the
same summary-lines rule.

**R19** — Module-level summary comes from the module-level docstring or first
block comment (same summary-lines rule as R17). Directory-level summary
comes from the first paragraph of `README.md` (all lines up to the first
blank line) if present, using the summary-lines rule.

**R20** — During `load`, `reload`, and `update_source`, summaries are never
mechanically generated from structure or requested from an external LLM. If no
documentation is found, `summary` is `missing`.

**R20a** — For `kind=comment` nodes, the summary is derived directly from the
node's own source using the summary-lines rule: the first three lines of the
comment text (after stripping comment markers) that contain at least one
alphanumeric character, joined with a single space.

**R20b** — `CodeTree.jl` itself performs no network or agent calls as part of
summary extraction. Any explicit, LLM-backed summary generation for already
loaded rows is layered above the package rather than built into the indexing
API. The Julia-side API for such generated summaries is specified separately in
`repl-api-requirements.md`.

---

### Symbols

**R21** — `db.symbols` is populated for every leaf node (`n_children = 0`)
using the language config's call and definition patterns for the leaf's
language:

- **Call symbols**: every function or method call in the leaf's source
  produces a row with `kind = "call"`. Call symbols are always recorded,
  including calls to functions defined elsewhere in `db.code`. This
  ensures that overloaded functions — where one definition is internal and
  another external — are never silently omitted.

- **Variable reference symbols**: every identifier read in the leaf's
  source that is not bound within that leaf (per the language config's
  definition patterns) produces a row with `kind = "var_ref"`. Identifiers
  that are locally defined (assigned, declared, or bound as loop/with
  variables within the same leaf) are excluded.

**R21a** — For Markdown leaf nodes, symbol extraction is applied only to
code spans within the leaf's source. Prose text is never scanned for
symbols. The following span types are recognised:

- **Fenced code blocks with a language tag** (e.g. ` ```python `): the
  block's content is parsed with the tree-sitter grammar for that language
  and symbols are extracted using that language's config patterns, identical
  to how source files of that language are processed.

- **Fenced code blocks without a language tag**, **indented code blocks**
  (four-space or tab-indented per CommonMark), and **inline backtick spans**
  (`` `…` ``): the content is tokenized into identifier-like tokens
  (`[A-Za-z_][A-Za-z0-9_!?.]*`) and intersected with the set of `name`
  values in `db.code` that belong to non-Markdown nodes. Only tokens that
  match a known name are recorded. A matching token is recorded as
  `kind = "call"` if immediately followed by `(` in the span, otherwise as
  `kind = "var_ref"`. This avoids false positives from prose words without
  requiring a grammar.

**R21b** — Because untagged code spans (R21a, second bullet) depend on
`db.code` being populated with non-Markdown content, all non-Markdown source
files are fully indexed — including their `db.code` rows — before any
Markdown file's symbols are extracted. The same ordering applies during
`reload`.

**R21c** — The name-intersection set used in R21a is built from `name`
values of nodes whose `language` is not `"markdown"`. Markdown node names
(heading text, link text, etc.) are excluded from the intersection to
prevent circular false matches.

**R22** — Symbol extraction operates on the leaf's `source` text using the
config's AST patterns. No attempt is made to resolve symbols to specific
nodes in `db.code`; `db.symbols` records names only, not targets. Lookup of
where a symbol is defined is done by querying `db.code` directly (e.g.
filtering by `name`).

---

### Caching

**R24** — The cache is stored under `.7aigent/code_tree/` relative to the
codebase root.

**R25** — A `files` table is persisted alongside `code` and `symbols`,
tracking `(path, hash, commit_hash?)` for each indexed file. `hash` is the
SHA-256 of the file contents.

**R25a** — The cache stores a compatibility token for the current CodeTree
cache format/build logic. If the on-disk cache is incompatible with the
running package version, `load` invalidates the stale cached rows before any
file-level reuse decision is made. Incompatible cache entries must never be
reused to populate `db.code` or `db.symbols`.

**R26** — On `load`, each discovered file's hash is compared against the
cache. Unchanged files reuse their cached rows without re-parsing.

**R27** — Changed and new files are re-parsed; their rows in `code` and
`symbols` are replaced.

**R28** — Files present in the cache but absent on disk have their rows
removed.

---

### Editing

**R29** — `CodeTreeDB` maintains an internal in-memory buffer: a mapping from
file path to current source content. On `load`, all discovered files are read
into this buffer. The DataFrames are always indexed from the buffer, never
directly from disk.

**R29a** — `get_source(db, id)` returns the current text of node `id` by
slicing the in-memory buffer over that node's `(line_start, line_end)` span.
For leaf nodes, this equals the node's `source` column. For non-leaf nodes,
this reconstructs the span on demand even though `source` is `missing`.

**R30** — `update_source(db, id, new_source)` is the sole mutation path. It
must accept both leaf and non-leaf nodes, as long as the target node has a
file association and line range.
There is no other supported way to change codebase content.

**R30a** — Before applying any edit, `update_source` computes the SHA-256
hash of the current on-disk content of the target node's file and compares it
to the hash stored at last-load or last-write time for that file. If the
hashes differ, the file was modified externally: `update_source` re-indexes
the file from disk (as in R27), updates `db.code`, `db.symbols`, and the
buffer to reflect the new on-disk state, and then raises an informative error
explaining that the file changed externally and the `db` has been refreshed.
The caller may inspect the updated `db` and retry.

**R30b** — Any comparison or verification of the current source text of the
target node inside `update_source` is performed against `get_source(db, id)`,
not against the raw `source` column. Non-leaf nodes must therefore verify and
edit correctly even though their `source` column is `missing`.

**R31** — `update_source` reconstructs the new file content in memory by
replacing lines `line_start` through `line_end` (inclusive) of the target
node's file in the buffer with `new_source`. `new_source` must include the
full replacement text for that span — including any declaration line. The
trailing newline of `new_source` is treated as the line ending of
`line_end`; no extra newline is inserted or removed at the boundary.

**R32** — The new buffer content is re-indexed in memory (parse → build tree
→ extract summaries → extract symbols), producing a new set of rows. Only
if this succeeds are the DataFrames modified.

**R33** — `db.code` and `db.symbols` are updated together from the new rows.
Both updates are in-memory and happen before any write to disk.

**R33a** — After the new rows are applied, the `db.symbols` rows for all
leaf nodes that previously belonged to the changed file are removed, and
fresh symbol rows are inserted for the new leaf nodes produced by re-parsing.
No cross-file re-resolution is needed since `db.symbols` records names only,
not target node ids.

**R33b** — When `update_source` re-indexes a file, any in-memory summary
overrides previously attached to rows in that file are re-applied to the new
rows whose ids are unchanged. Overrides for rows whose ids disappear are
dropped.

**R34** — After the DataFrames are updated, the new buffer content is written
to disk and the cache is updated. Disk is never written before the DataFrames
are consistent with the new content.

**R35** — If the disk write or cache update in R34 fails, `update_source`
rolls back `db.code`, `db.symbols`, and the in-memory buffer to the state
they held before the call, then raises an error. After a failed
`update_source` the `db` must be indistinguishable from its pre-call state.
