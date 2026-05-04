# CodeTree.jl Requirements

## Overview

`CodeTree.jl` is a Julia package that parses a codebase into two queryable,
navigable DataFrames — `code` (the tree) and `refs` (cross-references) — and
keeps them in sync with the source files on disk.

---

## API Shape

These architectural decisions are requirements, not implementation details.

- **`CodeTreeDB`** — a container struct bundling `code`, `refs`, the codebase
  root path, and the language config. This is what `load` returns and what
  `update_source` operates on.

- **`CodeTree <: AbstractDataFrame`** — the `code` table, exposed as a
  read-only DataFrame. All DataFrames.jl query, filter, grouping, and join
  operations work on it. Direct mutation raises an informative error.

- **`CodeRefs <: AbstractDataFrame`** — the `refs` table, with the same
  read-only contract.

- **`load(path, config) -> CodeTreeDB`** — the entry point. Parses or loads
  from cache.

- **`update_source(db, id, new_source)`** — the sole mutation path. Updates
  both `db.code` and `db.refs` together.

---

## Requirements

### Schema

**R1** — `db.code` has the following columns:

| Column | Type | Description |
|--------|------|-------------|
| `id` | String | Unique node identifier (e.g. `engine/search.py:Searcher._minimax`) |
| `parent` | String? | Parent node id; `missing` for the root |
| `depth` | Int | Distance from root (0 = codebase, 1 = module, 2 = file, …) |
| `sibling_order` | Int | Position among siblings, by `line_start` |
| `kind` | String | Node kind (see below) |
| `name` | String | Short identifier |
| `qname` | String? | Qualified name (dot-joined path from root) |
| `language` | String? | Programming language, inherited from the file node |
| `summary` | String? | 1–3 sentence description; `missing` if not found |
| `source` | String? | Full source text of this node's span |
| `signature` | String? | Declaration line only; `missing` for non-declarative nodes |
| `file` | String? | Relative file path from codebase root |
| `line_start` | Int? | First line in the file |
| `line_end` | Int? | Last line in the file |
| `n_lines` | Int? | `line_end - line_start + 1` |
| `n_children` | Int | Number of direct children |

Node kinds: `codebase`, `module`, `file`, `class`, `function`, `loop`,
`conditional`, `try`, `with`, `import`, `variable`, `type`, `comment`,
`chunk`.

**R2** — `db.refs` has the following columns:

| Column | Type | Description |
|--------|------|-------------|
| `from_id` | String | Node containing the reference |
| `to_name` | String | Identifier being referenced |
| `to_id` | String? | Resolved target node id; `missing` if ambiguous or external |
| `line` | Int? | Line number of the reference within the source |
| `ref_kind` | String | `call`, `import`, `inherit` |

---

### Read-only Protection

**R3** — All DataFrames.jl read and query operations (filtering, grouping,
joining, `@subset`, etc.) work on `db.code` and `db.refs`.

**R4** — Any attempt to directly mutate `db.code` or `db.refs` raises an
informative error directing the caller to use `update_source`.

---

### Loading

**R5** — `load(path, config)` discovers all source files under `path`,
skipping ignored paths (`.gitignore` rules, `.7aigent/`, build artifacts,
binary files). If `path` is a git repository, `git ls-files` is used.

**R6** — Each file gets a `kind=file` node; each directory containing source
files gets a `kind=module` node; there is exactly one `kind=codebase` root.

**R7** — Language is detected from file extension.

**R8** — Files with no entry in the language config are loaded as a single
leaf node (the file node itself, with no children).

---

### Language Config

The language config is provided by the caller (the runner). The package
defines its structure but ships no default config.

**R9** — The config maps tree-sitter AST node types to `(class, kind)` per
language, where `class` is either `landmark` or `detail`.

**R10** — **Landmark nodes** always produce their own row in `db.code`.

**R11** — **Detail nodes** only produce a row when their parent node spans
more than a configurable `detail_threshold` lines.

**R12** — The `detail_threshold` is configurable, with a sensible default
(suggested: 30 lines).

**R13** — The config format applies uniformly to all languages. Markdown files
are parsed using Julia's stdlib `Markdown` module; the landmark/detail
classification for Markdown node types is specified in the config, not
hardcoded in the package.

---

### Tree Structure and Spanning

**R14** — For any non-leaf node, its children's `(line_start, line_end)`
ranges are non-overlapping and collectively cover every line of the parent's
body (the spanning invariant).

**R15** — Gaps between compound children (lines belonging to no landmark or
detail node) are filled with `kind=chunk` nodes. Chunks are always leaves.

**R16** — Siblings are ordered by ascending `line_start`
(`sibling_order = 0, 1, 2, …`).

---

### Summaries

**R17** — For functions, methods, and classes: a docstring (the first string
literal in the body) is used as the summary; its first sentence is extracted.

**R18** — If no docstring is found, a comment block immediately preceding the
node (no blank line between comment and declaration) is used.

**R19** — Module-level summary comes from the module-level docstring or first
block comment. Directory-level summary comes from the first paragraph of
`README.md` if present.

**R20** — Summaries are never mechanically generated from structure. If no
documentation is found, `summary` is `missing`.

---

### Cross-References

**R21** — The language config supplies tree-sitter query patterns that define
what constitutes a reference for each language. Each matched pattern produces
a row in `db.refs` with the `ref_kind` label specified in the config.

**R22** — The `ref_kind` label is config-defined, allowing semantically
equivalent constructs across languages to be mapped to the same kind (e.g.
Python `import`, C `#include`, and Nix `imports = [...]` can all map to
`ref_kind="import"`). The package imposes no fixed vocabulary of ref kinds.

**R23** — After extraction, refs with exactly one match in `db.code` by
`to_name` have their `to_id` resolved. Refs with zero or multiple matches
leave `to_id` as `missing`.

---

### Caching

**R24** — The cache is stored under `.7aigent/code_tree/` relative to the
codebase root.

**R25** — A `files` table is persisted alongside `code` and `refs`, tracking
`(path, hash, commit_hash?)` for each indexed file. `hash` is the SHA-256 of
the file contents.

**R26** — On `load`, each discovered file's hash is compared against the
cache. Unchanged files reuse their cached rows without re-parsing.

**R27** — Changed and new files are re-parsed; their rows in `code` and
`refs` are replaced.

**R28** — Files present in the cache but absent on disk have their rows
removed.

---

### Editing

**R29** — `CodeTreeDB` maintains an internal in-memory buffer: a mapping from
file path to current source content. On `load`, all discovered files are read
into this buffer. The DataFrames are always indexed from the buffer, never
directly from disk.

**R30** — `update_source(db, id, new_source)` is the sole mutation path.
There is no other supported way to change codebase content.

**R31** — `update_source` reconstructs the new file content in memory by
replacing the target node's lines with `new_source` in the buffer.

**R32** — The new buffer content is re-indexed in memory (parse → build tree
→ extract summaries → extract refs → resolve refs), producing a new set of
rows. Only if this succeeds are the DataFrames modified.

**R33** — `db.code` and `db.refs` are updated together from the new rows.
Both updates are in-memory and happen before any write to disk.

**R34** — After the DataFrames are updated, the new buffer content is written
to disk and the cache is updated. Disk is never written before the DataFrames
are consistent with the new content.
