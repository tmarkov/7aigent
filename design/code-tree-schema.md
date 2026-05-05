# Code Tree Schema: A Language-Agnostic Codebase Representation

## Introduction

This document describes a relational schema for storing and querying source code as a queryable, navigable tree structure. The design enables:

- **Progressive disclosure**: Browse code hierarchically (codebase → module → file → function → source)
- **Cross-cutting search**: Find references, dead code, or patterns across the entire codebase
- **Semantic queries**: Filter by properties derived from source (return type, visibility, async, etc.)
- **Language-agnostic**: Single schema works across Python, Go, Rust, Java, JavaScript, etc.
- **Interactive exploration**: Use with R's tidyverse or any relational query engine

The key insight is that code is fundamentally a tree with two types of cross-cutting needs:
1. **Hierarchical navigation** (parent pointers, depth, ordering)
2. **External symbol dependencies** (what identifiers does each piece of code use from outside itself?)

These two needs map naturally to two tables: `code` (the tree) and `symbols` (external identifier references per leaf node).

---

## Core Rationale

### Why a Relational Schema?

Most code analysis tools expose either:
- **ASTs** (trees): powerful for language-specific analysis but expensive to build and query
- **Text** (grep, regex): fast and language-agnostic but crude and fragile

**This design occupies a middle ground:**

**From trees:**
- Hierarchy (parent pointers enable tree traversal)
- Structured querying (filter by kind, depth, location)

**From text:**
- Language-agnostic (works across languages)
- Fast (one-pass extraction; no semantic analysis needed)
- Approximate (good enough for 95% of use cases)

The tradeoff: this schema can't answer questions that require semantic understanding (e.g., "which variables are truly the same binding across scopes?"). But it *can* answer questions that don't require a full type checker, which is most of them.

### Why Two Tables?

**Table 1: `code` (the tree)**
Stores the hierarchical structure. Every query for "find functions," "navigate modules," "show summaries" hits this table.

**Table 2: `symbols` (external identifiers)**
Stores, for each leaf node, the identifiers it uses that are not locally defined — function calls (always) and variable reads from outside the leaf. This enables cross-cutting dependency queries without requiring a full type checker or symbol resolver.

Why separate?
- Most code queries are hierarchical (navigate → filter → read)
- Symbol dependency queries are less common but critical (what does this function depend on? what code mentions this identifier?)
- Symbols must be precomputed at index time (scanning every leaf on-the-fly is expensive)
- Separating them keeps `code` lean and symbol-join queries explicit and debuggable

Why not resolve symbol names to node ids?
- Name-to-node resolution is ambiguous under function overloading and multiple dispatch (e.g. Julia), which would leave most entries unresolved anyway
- Callers can always look up `db.code` by `name` directly; a resolved `to_id` would add complexity with little gain

### Why Store Summaries?

The `summary` column is the **entire value proposition** of this schema.

Traditional approaches:
- **Text search**: `grep "minimax"` finds the function but requires you to read code to understand it
- **Language-specific tools**: IDE go-to-definition shows you the definition, not what it does

This schema:
- Store a curated 1-3 sentence summary at every level
- Browse by reading summaries without diving into code
- Progressive disclosure: read summaries → expand interesting nodes → read source

This is why you can find the minimax function by searching for "search" and "minimax" in summaries, rather than needing to know it's called `_minimax`.

### Why Derive Some Attributes?

Columns like `return_type`, `params`, `visibility`, and `decorators` are **not stored** but derived when needed:

```r
code %>%
  filter(kind == "function") %>%
  mutate(return_type = str_extract(signature, "-> (.+)$"),
         visibility = if_else(str_starts(name, "_"), "private", "public"),
         is_async = str_detect(signature, "^async"))
```

Why?
- They're derivable from `signature` or `source` (cheap regex operations)
- They're not used in navigation (no need to filter by them upfront)
- Storing them would double the schema size with redundant data
- Tidyverse/SQL `mutate` makes derivation trivial and readable

The principle: **store immutable structure and hard-to-compute summaries. Derive everything else on the fly.**

---

## Schema: `code` Table

The tree structure.

```sql
CREATE TABLE code (
  -- === TREE STRUCTURE ===
  id            TEXT PRIMARY KEY,
  parent        TEXT,
  depth         INTEGER NOT NULL,
  sibling_order INTEGER DEFAULT 0,

  -- === IDENTITY ===
  kind          TEXT NOT NULL,
  name          TEXT NOT NULL,
  qname         TEXT,
  language      TEXT,

  -- === CONTENT ===
  summary       TEXT,
  source        TEXT,
  signature     TEXT,

  -- === LOCATION ===
  file          TEXT,
  line_start    INTEGER,
  line_end      INTEGER,

  -- === METRICS ===
  n_lines       INTEGER,
  n_children    INTEGER
);
```

### Node Kinds

Code structure is classified into these kinds, which map across languages:

| Kind | Maps to | Example |
|------|---------|---------|
| `codebase` | The root; one per project | `chess` (the root node) |
| `module` | Package, namespace, directory | `engine`, `ui` (Python packages) |
| `file` | Source file | `engine/search.py` |
| `class` | Class, struct, interface, trait | `Searcher`, `Board` |
| `function` | Function, method, subroutine | `search`, `_minimax`, `legal_moves` |
| `block` | Structural block | `for`, `while`, `if`, `try/catch` |
| `import` | Import, require, include statement | `from engine.eval import eval_position` |
| `variable` | Module/class-level constant or field | `PST` (piece-square table) |
| `type` | Type def, typedef, alias | `type Piece = ...` |
| `comment` | Docstrings, doc comments | Module docstring, class docstring |

### Tree Structure

Each node has:
- **`id`**: Unique identifier (e.g., `engine/search.Searcher._minimax`)
- **`parent`**: Parent node's ID (NULL for root)
- **`depth`**: Distance from root (0 = codebase, 1 = module, 2 = file, 3 = class/function, 4 = method)
- **`sibling_order`**: Position among siblings (by source line number for ordering)

The `parent` pointer is sufficient to reconstruct the full path from root to any node.

### Identity

- **`kind`**: Classification (see above)
- **`name`**: Short identifier (e.g., `_minimax`, `search.py`, `engine`)
- **`qname`**: Qualified name for disambiguation (e.g., `engine.search.Searcher._minimax`)
- **`language`**: Programming language (inherited from the containing file)

Example progression:
```
codebase:chess
  module:engine
    file:search.py (language=python)
      class:Searcher
        function:search (qname=engine.search.Searcher.search)
        function:_minimax (qname=engine.search.Searcher._minimax)
```

### Content

- **`summary`**: 1-3 sentence human-readable summary
  - "Recursive minimax with alpha-beta pruning"
  - "Board representation and move generation"
  - **This is the key value-add and cannot be derived**

- **`source`**: Full source text — **leaf nodes only** (`n_children = 0`)
  - Stored only at leaves; non-leaf nodes carry structural metadata but no source text
  - Any file can be reconstructed by concatenating its leaf nodes' `source` in `line_start` order
  - Searching `source` across all rows finds every occurrence in the codebase (leaves cover every line exactly once)
  - Storing source at every level would cause O(depth) redundancy — the same text repeated in every ancestor

- **`signature`**: Declaration line only (stored for convenience, derivable from source)
  - `def _minimax(self, board, depth, maximizing) -> tuple[int, Move]`
  - Used constantly in queries (T1: functions with return type X)
  - Worth pre-extracting to avoid regex on every query

### Location

- **`file`**: Relative file path from codebase root
  - `engine/search.py`
  - Used for grouping (dependency graph), filtering, and error reporting

- **`line_start`, `line_end`**: First and last line in the file
  - Enables precise navigation in editors
  - Needed when writing modified code back to disk
  - Could add `byte_start`, `byte_end` for language servers

### Metrics

- **`n_lines`**: Line count of this node's source
  - Used for filtering ("show me functions larger than 50 lines")
  - Used for statistics and complexity analysis
  - Cheap to compute once; expensive to recompute repeatedly

- **`n_children`**: Direct child count
  - `n_children == 0` indicates a leaf (show source directly)
  - Used in UI rendering decisions
  - Quick way to know if a node is expandable

---

## Schema: `symbols` Table

External identifier references, extracted from leaf nodes.

```sql
CREATE TABLE symbols (
  node_id  TEXT NOT NULL,   -- FK to code.id; always a leaf (n_children = 0)
  symbol   TEXT NOT NULL,
  kind     TEXT NOT NULL    -- 'call' or 'var_ref'
);

CREATE INDEX idx_symbols_node   ON symbols(node_id);
CREATE INDEX idx_symbols_symbol ON symbols(symbol);
CREATE INDEX idx_symbols_kind   ON symbols(kind);
```

### Columns

- **`node_id`**: The leaf node containing the reference (FK to `code.id`)
- **`symbol`**: The identifier name (e.g., `_minimax`, `eval_position`, `Board`)
- **`kind`**: Either `call` (a function or method called) or `var_ref` (a variable read from outside this leaf)

### Extraction Rules

**Call symbols** — always recorded, even if a function of the same name is defined elsewhere in `db.code`. This ensures overloaded functions and higher-order uses are never silently dropped.

**Variable reference symbols** — recorded only when the identifier is not locally defined within the same leaf. Local definitions are identified per language by the config's definition patterns (assignment targets, loop variables, parameters, explicit declarations, etc.).

No name-to-node resolution is performed. `symbols` records names only. To find where a symbol is defined, query `db.code` by `name`.

### Why Not Resolve to Node IDs?

Languages with overloading (C++, Julia's multiple dispatch) have multiple `db.code` nodes sharing the same `name`. A call to `foo` in Julia could resolve to any of dozens of methods depending on argument types — information not available without a type checker. Storing an unresolved `to_id = missing` for the majority of entries would make the table largely useless. Names-only has perfect recall at the cost of requiring the caller to disambiguate when needed.

### What This Enables

```sql
-- All leaf nodes that call _minimax
SELECT c.id, c.file, c.line_start
FROM symbols s JOIN code c ON s.node_id = c.id
WHERE s.symbol = '_minimax' AND s.kind = 'call';

-- All external symbols used by a given function (navigate to its leaves first)
SELECT DISTINCT s.symbol, s.kind
FROM symbols s
JOIN code c ON s.node_id = c.id
WHERE c.file = 'engine/search.py'
  AND c.line_start >= 42 AND c.line_end <= 80;

-- Which files reference eval_position?
SELECT DISTINCT c.file
FROM symbols s JOIN code c ON s.node_id = c.id
WHERE s.symbol = 'eval_position';
```

---

## Column Rationale Reference

### Stored Columns (Why Not Derived?)

| Column | Cost | Rationale |
|--------|------|-----------|
| `id` | — | Primary key; fundamental |
| `parent` | Negligible | Defines the tree structure; used in every navigation query |
| `depth` | Negligible | Used in every display query for indentation |
| `sibling_order` | Negligible | Preserves source order; essential for display |
| `kind` | Negligible | Fundamental classification; used in most filters |
| `name` | Negligible | Human-readable identifier; used everywhere |
| `qname` | Negligible | Disambiguation; critical when multiple `parse()` functions exist |
| `language` | Negligible | Used to choose regex/parser for mutations |
| `summary` | **High** | **Cannot be reliably derived from source code** |
| `source` | Negligible | Leaf nodes only; the data itself. Non-leaf source would be O(depth) redundant. |
| `signature` | Low | Derivable from `source`, but used in ~90% of function queries; worth caching |
| `file` | Negligible | Physical location; used constantly |
| `line_start`, `line_end` | Negligible | Enables precise navigation and rewriting |
| `n_lines` | Negligible | Used in statistics; cheap to compute at index time |
| `n_children` | Negligible | Used in display logic; cheap to compute at index time |

### Derived Columns (Compute in Queries)

| Attribute | Derivation | Use Case |
|-----------|-----------|----------|
| `return_type` | `str_extract(signature, "-> (.+)$")` | T1: Find functions returning int |
| `params` | `str_extract(signature, "\\((.*)\\)")` | T4: Functions with N parameters |
| `visibility` | `if_else(str_starts(name, "_"), "private", "public")` | T9: Generate tests for public methods |
| `is_async` | `str_detect(signature, "^async")` | Async/await analysis |
| `is_recursive` | Join `symbols` where `symbol = name` and `node_id` is a leaf of the same function | Find recursive functions |
| `is_tested` | Join with test file's `symbols` where `symbol = name` | Coverage analysis |
| `complexity` | NestDepth of `source` via regex on leaf nodes | Find overly complex functions |
| `has_unsafe` | `str_detect(source, "unsafe")` on leaf nodes | Security audit |
| `external_callers` | `COUNT(symbols where symbol = name AND kind = 'call')` | Find entry points |

### Never Stored

| Omitted | Why |
|---------|-----|
| AST node | Use `source` + language-specific regex; don't embed parsed AST |
| Type information | Would require semantic analysis (language-specific compiler/type-checker) |
| Data flow graph | Too language-specific; precompute only `symbols` (external identifier uses) |
| Embeddings | Store separately if/when needed for similarity search |
| Session state (expanded_set) | Hold in application memory, not the database |

---

## Example Queries

### Progressive Disclosure (Navigation)

Browse the tree by expanding nodes:

```sql
-- Show root and its immediate children
SELECT depth, kind, name, summary 
FROM code 
WHERE parent IS NULL OR parent IN ('root');

-- Expand engine module
SELECT depth, kind, name, summary 
FROM code 
WHERE parent IN ('root', 'engine')
ORDER BY depth, sibling_order;

-- Expand engine and show functions inside
SELECT depth, kind, name, summary 
FROM code 
WHERE parent IN ('root', 'engine', 'engine/search', 'searcher')
ORDER BY depth, sibling_order;
```

In tidyverse:

```r
expanded <- c("root", "engine", "engine/search", "searcher")
code %>%
  filter(parent %in% expanded) %>%
  arrange(depth, sibling_order) %>%
  transmute(
    indent = str_dup("  ", depth),
    display = glue("{indent}{kind}: {name} — {summary}")
  )
```

### Flat Queries (Search/Filter)

Find nodes matching criteria, ignoring hierarchy:

```sql
-- T1: Functions returning int
SELECT name, qname, signature 
FROM code 
WHERE kind = 'function' AND signature LIKE '%-> int%';

-- Functions larger than 50 lines
SELECT name, qname, file, n_lines 
FROM code 
WHERE kind = 'function' AND n_lines > 50
ORDER BY n_lines DESC;

-- Search source text across all leaf nodes
SELECT c.file, c.line_start, c.source
FROM code c
WHERE c.n_children = 0 AND c.source LIKE '%unsafe%';
```

In tidyverse:

```r
code %>%
  filter(kind == "function") %>%
  mutate(return_type = str_extract(signature, "-> (.+)$")) %>%
  filter(return_type == "int")

# Find all leaves containing "unsafe"
code %>%
  filter(n_children == 0, str_detect(source, "unsafe")) %>%
  select(file, line_start, source)
```

### Cross-Cutting Analysis (Symbols)

Find identifier dependencies across the tree:

```sql
-- All leaf nodes that call _minimax
SELECT c.file, c.line_start
FROM symbols s JOIN code c ON s.node_id = c.id
WHERE s.symbol = '_minimax' AND s.kind = 'call';

-- All external symbols used within a function's leaves
SELECT DISTINCT s.symbol, s.kind
FROM symbols s JOIN code c ON s.node_id = c.id
WHERE c.file = 'engine/search.py'
  AND c.line_start >= 42 AND c.line_end <= 80;

-- Which files reference eval_position?
SELECT DISTINCT c.file
FROM symbols s JOIN code c ON s.node_id = c.id
WHERE s.symbol = 'eval_position';

-- Functions whose leaves call _minimax (navigate up from leaf to enclosing function)
SELECT DISTINCT p.name, p.qname, p.file
FROM symbols s
JOIN code leaf ON s.node_id = leaf.id
JOIN code p    ON p.kind = 'function'
              AND p.file = leaf.file
              AND p.line_start <= leaf.line_start
              AND p.line_end   >= leaf.line_end
WHERE s.symbol = '_minimax' AND s.kind = 'call';
```

---

## Integration with Julia / DataFrames.jl

The schema is designed for fluent DataFrames.jl workflows:

```julia
using CodeTree, DataFrames, DataFramesMeta

db = load("path/to/codebase", config)
code    = db.code     # CodeTree <: AbstractDataFrame
symbols = db.symbols  # CodeSymbols <: AbstractDataFrame

# Navigate — expand a set of nodes
expanded = ["root", "engine", "engine/search", "Searcher"]
@subset(code, :parent .∈ Ref(expanded)) |> x -> sort(x, [:depth, :sibling_order])

# Filter functions by signature
@subset(code, :kind .== "function", contains.(:signature, "-> Int"))

# Read a leaf's source
@subset(code, :n_children .== 0, :file .== "engine/search.py") |>
  x -> sort(x, :line_start) |>
  x -> join(x.source)

# Which leaves call _minimax?
innerjoin(
  @subset(symbols, :symbol .== "_minimax", :kind .== "call"),
  code, on = :node_id => :id
) |> x -> select(x, :file, :line_start)
```

---

## Index Strategy

```sql
CREATE INDEX idx_code_parent ON code(parent);
CREATE INDEX idx_code_kind   ON code(kind);
CREATE INDEX idx_code_file   ON code(file);
CREATE INDEX idx_code_qname  ON code(qname);

CREATE INDEX idx_symbols_node   ON symbols(node_id);
CREATE INDEX idx_symbols_symbol ON symbols(symbol);
CREATE INDEX idx_symbols_kind   ON symbols(kind);
```

Most queries use `parent` (navigation), `kind` (filtering), or `symbol` (cross-references). Index these.

---

## Future Extensions

**Without changing the core schema:**

1. **Multi-language support**: `language` column already supports it; regex in `summary` extraction differs per language
2. **Semantic queries**: Add a `vector` column to `code` with embeddings for similarity search
3. **Evolution tracking**: Add `commit_hash`, `timestamp` to track changes over time
4. **Author/ownership**: Add `author`, `owner` for team analysis
5. **Metrics history**: Separate table `metrics_history(node_id, timestamp, complexity, coverage, ...)`
6. **Comments/annotations**: Separate table for user notes on nodes

**Advanced additions (require semantic analysis):**

- Type signatures (resolve overloads, inheritance chains)
- Data flow graph (which variable values influence which outputs?)
- Symbol table (exact scope binding, not just "name appears somewhere")

These would require language-specific processing. The current schema provides a solid foundation for building on top.

---

## Summary

This schema is designed for **interactive, exploratory analysis of codebases**:

1. **Progressive disclosure** via `parent` pointers and `depth`
2. **Fast queries** via flat table design and strategic indexes
3. **Language-agnostic** via `kind` classification and regex on `source`/`signature`
4. **Practical** by storing structure and summaries, deriving attributes on the fly
5. **Queryable** via standard SQL, tidyverse, pandas, or any relational interface

The two-table design (`code` + `symbols`) separates the common case (hierarchical navigation) from the dependency case (what does this code use from outside itself?).

**The core value proposition: summaries at every level, enabling browsing by concept rather than by name.**
