# Codebase Loading Process

## Overview

`load_codebase(path)` parses a directory of source files and populates two tables:

- **`code`**: A hierarchical tree of all code and documentation nodes
- **`refs`**: Cross-references (calls, imports, type uses) between nodes

The result is a queryable, navigable representation of the codebase. The process is incremental: unchanged files are loaded from cache; only new or changed files are re-parsed.

---

## Key Design Principle: Full Spanning

Every node in the tree must be **fully spanned** by its children. If a node has any children, those children must collectively cover every line of the parent's source — no gaps.

This is achieved by two kinds of child nodes:

- **Compound nodes**: structurally significant nodes that get their own row — functions, classes, loops, conditionals, try/catch, etc. These are configured per language.
- **Chunk nodes**: catch-all rows that fill gaps between compound nodes. A chunk is a run of consecutive lines in the parent that don't belong to any compound child.

Example:

```python
def myFunc():        # line 1 — function node (compound)
    a = 10           # line 2 ─┐ chunk: "lines 2-2"
    for i in range(a): # line 3 — for node (compound)
        print(i)     # line 4 ─── chunk inside the for: "line 4"
    a = 5            # line 5 ─── chunk: "lines 5-5"
```

The function's children are: `[chunk(2-2), for(3-4), chunk(5-5)]`. These fully span lines 2-5. The `for`'s children are: `[chunk(4-4)]`.

If no compound nodes are found inside a parent, that parent is a **leaf**: it has no children and its full source is stored directly.

---

## Compound Node Configuration

Each language has a small configuration mapping tree-sitter node types to `kind` values. Only mapped types become compound nodes. Everything else becomes part of a chunk.

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

The configuration is deliberately small (~15–20 entries per language). Languages without configuration fall back to treating every file as a single leaf node.

---

## Step-by-Step Loading Process

### Step 1: Discover Files

Walk the directory tree, or run `git ls-files` if the directory is a git repository.

- Skip non-source files and ignored paths (`.gitignore`, `.code_tree/`, `__pycache__/`, `node_modules/`, build artifacts, binary files)
- Detect language per file by extension (`.py → python`, `.go → go`, `.rs → rust`, `.md → markdown`, `.c → c`, etc.)
- Include documentation files (`.md`, `.rst`, `.txt`) — they are parsed too

Result: a list of `(path, language)` pairs.

### Step 2: Check the Cache

Open `.code_tree/index.db` if it exists. This SQLite file contains the previously built `code` and `refs` tables, plus a `files` table:

```sql
CREATE TABLE files (
    path         TEXT PRIMARY KEY,
    hash         TEXT NOT NULL,     -- SHA256 of file contents
    commit_hash  TEXT               -- git commit hash when last indexed (optional)
);
```

For each discovered file, compute its SHA256 hash and compare against the cache. Partition files into:

- **Unchanged**: hash matches cache → skip re-parsing, reuse existing rows
- **Changed**: hash differs → re-parse, replace rows
- **New**: not in cache → parse, insert rows
- **Deleted**: in cache but not on disk → remove rows

If no cache exists, all files are "new."

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

**4a. Run tree-sitter.**

Parse the file using the appropriate language grammar. This produces a concrete syntax tree (CST).

**4b. Create the file node.**

Create a `kind=file` row:
- `name` = filename
- `qname` = relative path from codebase root
- `source` = entire file contents
- `line_start = 1`, `line_end` = total line count
- `summary` = module-level docstring or header comment if present (see Step 5); else NULL

**4c. Walk the CST and extract compound nodes.**

Recursively walk the CST. At each level, find the children that are compound nodes (per the language config). These become rows.

For each compound child:
- `id` = derived from path + qualified name (e.g., `engine/search.py:Searcher._minimax`)
- `parent` = the enclosing compound node's id
- `kind` = mapped kind from config
- `name` = the identifier (for functions/classes) or first line (for loops/conditionals/comments)
- `qname` = dot-joined chain of names from root to this node
- `signature` = the declaration line, for functions and classes; else NULL
- `source` = full text of this node's span in the file
- `line_start`, `line_end` = from tree-sitter's position info
- `n_lines` = line_end - line_start + 1
- `language` = inherited from the file node

**4d. Fill gaps with chunks.**

After collecting the compound children of any node, check for gaps: line ranges in the parent's span not covered by any compound child.

For each gap (contiguous line range between compound children, or before the first / after the last):
- Create a `kind=chunk` row
- `name` = `"lines {start}-{end}"` or `"line {n}"` if single line
- `source` = the text of those lines
- `summary` = NULL
- `signature` = NULL

Chunks are always leaves (no children of their own).

**4e. Set sibling ordering.**

Among all children of a node, set `sibling_order` = 0, 1, 2, ... in ascending `line_start` order. This preserves source order in navigation views.

**4f. Compute n_children.**

Set `n_children` for each node = count of its direct children.

### Step 5: Extract Summaries

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

**Modules (directories):**
- First paragraph of `README.md` if present, else NULL.

**Loops, conditionals, try/catch:**
- Look for a comment on the line immediately above the statement (within the parent's source). If it appears to describe the block (single line, ends with no punctuation or ends with `:`) extract it.
- Otherwise: NULL.

**Chunks:**
- Always NULL. Chunks are residuals; they have no meaningful summary.

**Comments:**
- The comment text itself is the summary (it's both `source` and `summary`).

All summary extraction is heuristic. The `summary` column is NULL when nothing is found — it is never mechanically generated from structure.

### Step 6: Extract Cross-References

For each function, method, or chunk node, scan its `source` for references:

**Calls:** scan for patterns like `name(` or `obj.method(`. For each match:
- Create a `refs` row: `from_id` = current node, `to_name` = matched name, `ref_kind = "call"`, `line` = line number of match
- `to_id = NULL` for now (resolved in Step 7)

**Imports:** for each `kind=import` node, parse the import statement:
- Create a `refs` row: `from_id` = the file node, `to_name` = imported symbol, `ref_kind = "import"`

**Inheritance:** for each `kind=class` node, check the signature for base classes:
- `class Searcher(BaseSearcher):` → `refs` row with `ref_kind = "inherit"`, `to_name = "BaseSearcher"`

This is text-pattern matching on source, not semantic analysis. It will produce some false positives (a variable called `search` used in an expression) and miss indirect calls. This is accepted — good enough for 90% of use cases without requiring a full type checker.

### Step 7: Resolve Cross-Reference Targets

For each `refs` row where `to_id` is NULL:

```sql
SELECT id FROM code 
WHERE name = :to_name 
AND kind IN ('function', 'class', 'variable')
```

- **Exactly one match**: set `to_id` to that match.
- **Multiple matches**: leave `to_id = NULL` (ambiguous without scope analysis).
- **Zero matches**: leave `to_id = NULL` (external dependency or unresolved).

For `ref_kind = "import"`, also update the file's parent module if the import target is in the same codebase.

### Step 8: Update the Cache

Delete all `code` rows where `file` is in the changed/deleted set. Delete all `refs` rows where `from_id` starts with any changed file's prefix.

Insert all newly produced rows.

Update the `files` table with new hashes.

Write to `.code_tree/index.db`.

### Step 9: Return

Return a handle to the populated database. The `code` and `refs` tables are ready for querying.

---

## Incremental Updates After Edits

When the user modifies source code through the tool:

1. **Write the modified file to disk.** The `code` table's `source` column is used to regenerate the file content. Since the spanning invariant holds, every line in the file is covered by exactly one chain of nodes — reconstruction is unambiguous.

2. **Re-index the changed file** (Steps 4–7 for that file only). This takes milliseconds with tree-sitter.

3. **Re-resolve refs pointing into this file.** Any `refs` row where `to_id` was a node in the changed file needs re-resolution (the target node's `id` may have changed if the function was renamed or restructured).

4. **Update ancestor `n_children`** if nodes were added or removed.

LLM-generated summaries are stored in the `code` table. When a file is re-indexed, its nodes' summaries are reset to whatever documentation extraction finds (Step 5). If an LLM summary was previously generated and the source has changed, it is cleared. If the source is unchanged (same hash), the cached LLM summary is preserved.

---

## The Spanning Invariant: Formal Statement

For any node `n` in the `code` table:

- If `n` has no children (`n_children = 0`): `n` is a leaf. Its `source` is stored directly.
- If `n` has children: the children's `(line_start, line_end)` ranges must be non-overlapping, cover every line from `n.line_start + header_lines` to `n.line_end`, and be sorted in ascending order.

Where `header_lines` = the number of lines in `n`'s declaration (signature) that precede the body. For a Python function, `header_lines = 1` (the `def` line). For a class with a multi-line declaration, it may be more.

This invariant ensures:
- The file can always be reconstructed from the leaf nodes' `source` values, concatenated in `sibling_order`
- There is no "lost" source text
- Querying `WHERE source LIKE '%pattern%'` at any level finds all occurrences (because compound nodes' `source` includes their children's text)

---

## File Reconstruction

Given the spanning invariant, any file can be reconstructed:

```sql
-- Get all leaf nodes for a file, in order
SELECT source FROM code
WHERE file = 'engine/search.py'
AND n_children = 0
ORDER BY line_start;
-- Concatenate sources → original file content
```

Or equivalently, the file node's own `source` column is the full file content — stored directly as a convenience.

---

## Language Configuration Reference

Each language config is a small YAML/TOML file mapping tree-sitter node types to `kind` values. Example for Python:

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
```

For an unsupported language (no config file), the entire file becomes a single leaf node. Summary extraction falls back to first-comment heuristic.

---

## Summary of Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Full spanning | Required | Enables file reconstruction; no lost text |
| Gap filling | Chunk nodes | Avoids trivial single-statement rows while maintaining spanning |
| Compound node set | Configurable per language | Languages differ; keep config small |
| Summary extraction | Documentation only (docstrings, comments, READMEs) | Mechanical reformatting adds noise; summaries should convey intent |
| LLM summaries | On demand, not at index time | Cost, latency, and correctness — only generate when user needs it |
| Cross-references | Heuristic (text pattern matching) | No full type checker; good enough for common cases |
| Cache | SHA256 per file | Language-agnostic, works without git, resilient to force-push |
| Edit strategy | Write to disk → re-index | Always correct; tree-sitter re-parse is fast enough |
