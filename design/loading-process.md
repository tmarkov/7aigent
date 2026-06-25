# Codebase Loading Process

## Overview

`load_codebase(path)` parses a directory of source files and populates two tables:

- **`code`**: A hierarchical tree of all code and documentation nodes
- **`symbols`**: External identifier references (calls and variable reads) per eligible leaf node

The result is a queryable, navigable representation of the codebase. The process is incremental: unchanged files are loaded from cache; only new or changed files are re-parsed.

---

## Key Design Principle: Full Spanning

Every node in the tree must be **fully spanned** by its children. If a node has any children, those children must collectively cover every line of the parent's source — no gaps.

This is achieved by structural child nodes and residual chunks:

- **Structural nodes**: significant nodes that get their own row — functions,
  classes, loops, conditionals, try/catch, non-semantic blocks, etc. Semantic
  structural kinds are configured per language; `block` is used when structure
  is known but language semantics are not.
- **Chunk nodes**: catch-all leaf rows that fill gaps between structural
  children. A chunk is a run of consecutive lines in the parent that does not
  belong to any structural child.

Example:

```python
def myFunc():        # line 1 ─┐ chunk: "line 1" (declaration line)
    a = 10           # line 2 ─┘ chunk: "lines 1-2"  [merged with decl if contiguous]
    for i in range(a): # line 3 — for node (compound)
        print(i)     # line 4 ─── chunk inside the for: "lines 3-4" (decl + body)
    a = 5            # line 5 ─── chunk: "line 5"
```

The function's children are: `[chunk(1-2), for(3-4), chunk(5-5)]`. These fully span lines 1-5. The `for`'s children are: `[chunk(3-4)]` (the `for` declaration plus its body line).

After structural extraction and chunk filling, any parent with no child rows is
a **leaf**: it has no children and its full source is stored directly.

---

## Compound Node Configuration

Each language has a small configuration mapping parser node types to `kind`
values. Only mapped types become compound nodes. Everything else becomes part
of a chunk.

Example (Python):

```yaml
python:
  function_definition:  function
  async_function_def:   function
  class_definition:     class
  for_statement:        loop
  while_statement:      loop
  if_statement:         conditional
  try_statement:        try
  with_statement:       with
  comment:              comment
  import_statement:     import
  import_from_statement: import
  expression_statement: statement   # only at module/class level
  assignment:           variable    # only at module/class level
```

Nodes not in this list (identifiers, operators, argument lists, literals) are never compound — they become part of their parent's `source` text and do not appear as separate rows.

The configuration is deliberately small (~15–20 entries per language).
Languages without configuration use the non-semantic fallback parser described
below.

---

## Step-by-Step Loading Process

### Step 1: Discover Files

Walk the directory tree, or run `git ls-files --cached --others --exclude-standard` if the directory is a git repository (this includes both tracked files and untracked files that are not gitignored).

- Skip non-source files and ignored paths (`.gitignore`, `.7aigent/`, `__pycache__/`, `node_modules/`, build artifacts, binary files)
- Detect language per file by extension (`.py → python`, `.go → go`, `.rs → rust`, `.md → markdown`, `.c → c`, etc.)
- Include documentation files (`.md`, `.rst`, `.txt`) — they are parsed too

Result: a list of `(path, language)` pairs.

### Step 2: Check the Cache

Open `.7aigent/code_tree/index.db` if it exists. Before trusting any cached
rows, check the cache's compatibility token against the current CodeTree
cache format/build logic. If the cache is incompatible, invalidate it and
treat the run as if no cache existed.

The SQLite cache contains the previously built `code` and `symbols` tables,
plus a `files` table:

```sql
CREATE TABLE files (
    path         TEXT PRIMARY KEY,
    hash         TEXT NOT NULL,     -- SHA256 of file contents
    commit_hash  TEXT               -- git commit hash when last indexed (optional)
);
```

For each discovered file, compute its SHA256 hash and compare against the
cache. Partition files into:

- **Unchanged**: hash matches cache → skip re-parsing, reuse existing rows
- **Changed**: hash differs → re-parse, replace rows
- **New**: not in cache → parse, insert rows
- **Deleted**: in cache but not on disk → remove rows

If no compatible cache exists, all files are "new."

### Step 3: Build the Directory Tree

From the full file list (not just changed files), derive the directory hierarchy. Create `code` rows for:

- One `kind=codebase` root node (depth 0, `id = "root"`)
- One `kind=module` node per directory containing source files (depth 1+)

For each module node:
- `name` = directory name
- `summary` = first paragraph of `README.md` in that directory, if present; else NULL
- `source` = NULL (the directory itself has no source)
- `n_children` = count of immediate child files and subdirectories

Only process new/changed directories (those containing new or changed files, or whose README.md changed).

### Step 4: Parse Changed Files

For each new or changed file:

**4a. Parse the file.**

Use the configured parser when it produces a usable tree; otherwise use the
fallback parser from R8.

**4b. Create the file node.**

Create a `kind=file` row:
- `name` = filename
- `qname` = relative path from codebase root
- `source` = NULL once children are added; if the file remains a leaf, `source` stores the full file text. `get_source(db, id)` reconstructs any node's span on demand.
- `line_start = 1`, `line_end` = total line count
- `summary` = module-level docstring or header comment if present on the parser-derived path (see Step 5); else NULL

**4c. Extract structural nodes.**

For a configured parser tree, recursively extract compound nodes per the
language config. For the fallback parser, emit `kind=block` nodes per R8.

For each structural child:
- `id` = derived from path + qualified name (e.g., `engine/search.py:Searcher._minimax`)
- `parent` = the enclosing structural node's id
- `kind` = mapped kind from config, or `block` from the fallback parser
- `name` = identifier/first line for semantic nodes, or generic fallback name per R8f
- `qname` = dot-joined chain of names from root to this node
- `signature` = the declaration line, for functions and classes; else NULL
- `source` = NULL for non-leaves; stored only when the row is a leaf
- `line_start`, `line_end` = from the parser's position info
- `n_lines` = line_end - line_start + 1
- `language` = inherited from the file node

**4d. Fill gaps with chunks.**

After collecting the structural children of any node, check for gaps: line ranges in the parent's span not covered by any structural child.

For each gap (contiguous line range between structural children, or before the first / after the last):
- Create a `kind=chunk` row
- `name` = generic fallback name per R8f, otherwise `"lines {start}-{end}"` or `"line {n}"` if single line
- `source` = the text of those lines
- `summary` = NULL
- `signature` = NULL

Chunks are always leaves (no children of their own).

**4e. Set sibling ordering.**

Among all children of a node, set `sibling_order = 0, 1, 2, ...` in ascending
`line_start` order. This preserves source order in navigation views.

**4f. Compute n_children.**

Set `n_children` for each node = count of its direct children.

### Step 5: Extract Initial Summaries

For each node produced in Step 4, attempt to extract a summary from documentation:

**Functions and methods:**
- Look for a docstring: the first statement in the function body, if it is a string literal. Extract the first sentence (up to the first `.` or newline).
- If no docstring, look for a comment block immediately above the function definition (no blank line between comment and `def`/`fn`/`func`). Extract its text.
- Otherwise: `summary = NULL`

**Classes:**
- Same as functions: docstring first, then comment above, then NULL.

**Files:**
- Look for a module-level docstring (first statement in the file, if a string literal).
- Or the first block comment before any non-comment, non-import code.
- Otherwise: NULL.
- File rows loaded by the fallback parser do not use language-specific
  docstring or header-comment extraction and have NULL summary.

**Modules (directories):**
- First paragraph of `README.md` if present, else NULL.

**Loops, conditionals, try/catch:**
- Look for a comment on the line immediately above the statement (within the parent's source). If it appears to describe the block (single line, ends with no punctuation or ends with `:`) extract it.
- Otherwise: NULL.

**Blocks and chunks:**
- Always NULL. Blocks are non-semantic structural nodes, and chunks are
  residuals; neither has parser-derived documentation.

**Comments:**
- The comment text itself is the summary (it's both `source` and `summary`).

All summary extraction in `load_codebase` is heuristic and documentation-only.
The `summary` column is NULL when nothing is found — it is never mechanically
generated from structure and no external LLM is consulted during indexing.

### Step 6: Extract Symbols

Symbol extraction runs in two passes to satisfy the Markdown ordering
constraint.

**Pass 1 — non-Markdown files:**

For each leaf node (`n_children = 0`) in a non-Markdown file loaded with a
language parser that has symbol extraction patterns, populate `db.symbols`
using the language config's call and definition patterns. Files loaded by the
fallback parser do not emit symbols.

**Call symbols:** apply the config's call patterns to the leaf's source AST.
For each matched call site, create a `symbols` row:
- `node_id` = this leaf node's id
- `symbol` = the called function or method name
- `kind = "call"`

Call symbols are always recorded — even if a function of the same name is
defined elsewhere in the tree. This ensures that indirect references through
overloaded functions are never silently dropped.

**Variable reference symbols:** apply the config's definition patterns to the
leaf's source AST to build the set of locally-defined names (assignment
targets, loop variables, `with`-as variables, explicit declarations, etc.).
For each identifier read in the leaf's source that does not appear in the
locally-defined set, create a `symbols` row:
- `node_id` = this leaf node's id
- `symbol` = the identifier name
- `kind = "var_ref"`

**Pass 2 — Markdown files:**

For each leaf node in a Markdown file loaded by the Markdown parser, scan its
source for code spans. Markdown files loaded by the fallback parser do not emit
symbols:

- **Tagged fenced code blocks**: use the tagged language's config when it has a
  usable tree-sitter grammar. Unknown tags, missing grammars, parse failures,
  and unusable trees emit no symbols; syntax-error nodes inside an otherwise
  usable tree do not suppress extraction.

- **Fenced code blocks without a language tag**, **indented code blocks**,
  and **inline backtick spans**: tokenize the content into identifier-like
  tokens (`[A-Za-z_][A-Za-z0-9_!?.]*`) and intersect with the set of
  `name` values from declaration-like non-Markdown nodes already in
  `db.code`. A node is declaration-like for this purpose when its `kind` is
  `function`, `class`, `type`, `variable`, or `import`. For each matching
  token, create a `symbols` row with `kind = "call"` if the token is
  immediately followed by `(` in the span, otherwise `kind = "var_ref"`.

No resolution of symbol names to `db.code` node ids is performed in either
pass. The `symbols` table records names only.

### Step 7: Update the Cache

Delete all `code` rows where `file` is in the changed/deleted set. Delete all
`symbols` rows where `node_id` starts with any changed file's prefix.

Insert all newly produced rows.

Update the `files` table with new hashes.

Write to `.7aigent/code_tree/index.db`.

### Step 8: Return

Return a handle to the populated database. The `code` and `symbols` tables are ready for querying.

---

## Incremental Updates After Edits

When the user modifies source code through the tool:

1. **Write the modified file to disk.** Apply R31's span replacement to the
   in-memory file buffer, then write the modified buffer.

2. **Re-index the changed file** (Steps 4–6 for that file only). This is a
   file-local parser or fallback rebuild.

3. **Replace symbols for the changed file.** Remove all `symbols` rows whose
   `node_id` belonged to the old leaf nodes of this file, and insert fresh
   rows for the new leaf nodes. No cross-file work is needed since
   `db.symbols` records names only, not target ids.

4. **Update ancestor `n_children`** if nodes were added or removed.

`reload` and file re-indexing only guarantee the documentation-derived
`summary` values produced by Step 5. Any richer on-demand summaries generated
later by REPL or agent tooling (see `repl-api-requirements.md`) are outside the
indexing/cache contract defined in this document.

---

## The Spanning Invariant: Formal Statement

For any node `n` in the `code` table:

- If `n` has no children (`n_children = 0`): `n` is a leaf. Its `source` is stored directly.
- If `n` has children: the children's `(line_start, line_end)` ranges must be non-overlapping, cover every line from `n.line_start` to `n.line_end` inclusive, and be sorted in ascending order.

The declaration line(s) of a parser-derived compound node (e.g. the `def
foo():` line of a Python function) are always covered by the first chunk child
of that node, not excluded from spanning. There is no `header_lines` concept —
children span the full range including the declaration.

This invariant ensures:
- The file can always be reconstructed by concatenating leaf nodes' `source` values in source span order
- There is no "lost" source text
- Searching `source` across all rows finds every occurrence in the codebase, since leaves collectively cover every line exactly once

---

## File Reconstruction

Given the spanning invariant, any file can be reconstructed by concatenating
its leaf nodes' `source` values in `line_start` order:

```sql
-- Get all leaf nodes for a file, in order
SELECT source FROM code
WHERE file = 'engine/search.py'
AND n_children = 0
ORDER BY line_start;
-- Concatenate sources → original file content
```

`source` is only populated for leaf nodes. Non-leaf nodes (functions, classes,
files, modules) carry structural metadata but no source text.

---

## Language Configuration Reference

Each tree-sitter-backed language config is a small YAML/TOML file mapping
tree-sitter node types to `kind` values. Example for Python:

```yaml
language: python
compound_nodes:
  function_definition:    function
  async_function_def:     function
  class_definition:       class
  for_statement:          loop
  while_statement:        loop
  if_statement:           conditional
  try_statement:          try
  with_statement:         with
  comment:                comment
  import_statement:       import
  import_from_statement:  import
  # Only at top-level scope:
  module_scope:
    assignment:           variable
    expression_statement: statement

docstring_node:    expression_statement > string    # first such child of a function/class body
header_comment:    comment                           # immediately preceding a compound node

# Symbol extraction
call_patterns:
  - (call function: (identifier) @symbol)
  - (call function: (attribute attribute: (identifier) @symbol))

definition_patterns:
  - (assignment left: (identifier) @symbol)
  - (for_statement left: (identifier) @symbol)
  - (with_statement alias: (identifier) @symbol)
  - (parameters (identifier) @symbol)
  - (import_statement name: (dotted_name (identifier) @symbol))
  - (import_from_statement name: (dotted_name (identifier) @symbol))
```

## Summary of Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Full spanning | Required | Enables file reconstruction; no lost text |
| Gap filling | Chunk nodes | Avoids trivial single-statement rows while maintaining spanning |
| Compound node set | Configurable per language | Languages differ; keep config small |
| Summary extraction | Documentation only (docstrings, comments, READMEs) | Mechanical reformatting adds noise; summaries should convey intent |
| LLM summaries | Explicit `summarize!`, not at index time | Cost, latency, and correctness — the loader stays documentation-only; richer summaries are requested later for specific rows |
| Source storage | Leaf nodes only | Eliminates O(depth) redundancy; reconstruction from leaves is lossless via spanning invariant |
| Symbol extraction | Call always + var_ref if not locally defined | Calls need always-record to handle overloads; var_refs filter locals to reduce noise |
| No to_id resolution | Names only in symbols table | Name-to-node resolution is ambiguous under overloading; callers query db.code directly |
| Cache | SHA256 per file | Language-agnostic, works without git, resilient to force-push |
| Edit strategy | Write to disk → re-index | Always correct; file-level parse/fallback rebuild is fast enough |
