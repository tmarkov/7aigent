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
2. **Cross-file references** (calls, imports, type uses)

These two needs map naturally to two tables: `code` (the tree) and `refs` (the cross-references).

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

**Table 2: `refs` (cross-references)**
Stores relationships between nodes that cross tree boundaries: function calls, imports, type uses, inheritance.

Why separate?
- Most code queries are hierarchical (navigate → filter → read)
- Cross-file queries are less common but critical (dead code, dependency graph, call chains)
- Refs must be precomputed at index time (building them on-the-fly is expensive)
- Separating them keeps `code` lean and the ref-join queries explicit and debuggable

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

- **`source`**: Full source text
  - Includes the entire function/class/file body
  - Yes, this is redundant (children's source appears in parent), but it makes queries simpler
  - In tidyverse: `code %>% filter(kind == "function", str_detect(source, "unsafe"))`
  - Without full source at the function level, you'd need to join up to the file

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

## Schema: `refs` Table

Cross-file references (calls, imports, type uses, etc.).

```sql
CREATE TABLE refs (
  from_id       TEXT NOT NULL,
  to_name       TEXT NOT NULL,
  to_id         TEXT,
  line          INTEGER,
  ref_kind      TEXT
);

CREATE INDEX idx_refs_to ON refs(to_name);
CREATE INDEX idx_refs_from ON refs(from_id);
```

### Columns

- **`from_id`**: Node containing the reference (FK to `code.id`)
- **`to_name`**: Identifier being referenced (e.g., `_minimax`, `eval_position`)
- **`to_id`**: Resolved target node (FK to `code.id`, NULL if external/unresolved)
- **`line`**: Line number within the source where the reference occurs
- **`ref_kind`**: Type of reference

### Reference Kinds

| Kind | Meaning | Example |
|------|---------|---------|
| `call` | Function/method call | `_minimax(board, depth, not maximizing)` |
| `import` | Import or require | `from engine.eval import eval_position` |
| `type_use` | Type reference | `-> tuple[int, Move]` |
| `read` | Variable/field read | `x + 1` |
| `write` | Variable/field assignment | `x = 5` |
| `inherit` | Class inheritance | `class Searcher(ABC)` |

### Why Separate?

This table enables queries that cross tree boundaries:
- Dead code: `SELECT * FROM code c WHERE kind='function' AND NOT EXISTS (SELECT 1 FROM refs WHERE to_name = c.name)`
- Callers of X: `SELECT from_id FROM refs WHERE to_name = 'X' AND ref_kind = 'call'`
- Dependency graph: `SELECT DISTINCT c1.file, c2.file FROM refs r JOIN code c1 ON r.from_id = c1.id JOIN code c2 ON r.to_id = c2.id WHERE c1.file != c2.file`

These are **precomputed** at index time because:
- Building the `refs` table requires scanning the entire codebase
- Queries like "what calls this?" must answer in milliseconds
- Live extraction would be too slow for interactive use

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
| `source` | Negligible | The data itself; must be stored |
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
| `is_recursive` | Inner join `refs` on same `to_name` and `from_id` | Find recursive functions |
| `is_tested` | Join with test file's `refs` | Coverage analysis |
| `complexity` | NestDepth of `source` via regex | Find overly complex functions |
| `has_unsafe` | `str_detect(source, "unsafe")` | Security audit |
| `external_callers` | `COUNT(refs.from_id WHERE to_name = name)` | Find entry points |

### Never Stored

| Omitted | Why |
|---------|-----|
| AST node | Use `source` + language-specific regex; don't embed parsed AST |
| Type information | Would require semantic analysis (language-specific compiler/type-checker) |
| Data flow graph | Too language-specific; precompute only `refs` (direct calls/imports) |
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

-- T6: Dead code (functions never called)
SELECT c.name, c.qname 
FROM code c
WHERE c.kind = 'function'
AND NOT EXISTS (
  SELECT 1 FROM refs r 
  WHERE r.to_name = c.name AND r.from_id != c.id
);

-- Functions larger than 50 lines
SELECT name, qname, file, n_lines 
FROM code 
WHERE kind = 'function' AND n_lines > 50
ORDER BY n_lines DESC;
```

In tidyverse:

```r
code %>%
  filter(kind == "function") %>%
  mutate(return_type = str_extract(signature, "-> (.+)$")) %>%
  filter(return_type == "int")

code %>%
  filter(kind == "function") %>%
  anti_join(refs, by = c("name" = "to_name")) %>%
  select(name, qname)
```

### Cross-Cutting Analysis (Refs)

Find relationships across tree boundaries:

```sql
-- T3: All functions that call _minimax
SELECT c.name, c.qname, c.file
FROM refs r 
JOIN code c ON r.from_id = c.id
WHERE r.to_name = '_minimax' AND r.ref_kind = 'call';

-- T12: File dependencies (who calls across file boundaries?)
SELECT DISTINCT c1.file AS from_file, c2.file AS to_file
FROM refs r
JOIN code c1 ON r.from_id = c1.id
JOIN code c2 ON r.to_id = c2.id
WHERE c1.file != c2.file
AND r.ref_kind = 'call';

-- T5: Impact analysis (what must change if eval_position changes?)
-- Direct callers
SELECT c.name, c.qname 
FROM refs r 
JOIN code c ON r.from_id = c.id
WHERE r.to_name = 'eval_position';
```

---

## Integration with R / Tidyverse

The schema is designed for fluent tidyverse workflows:

```r
library(tidyverse)
library(DBI)
con <- dbConnect(RSQLite::SQLite(), "codebase.db")

code <- tbl(con, "code")
refs <- tbl(con, "refs")

# Navigate
expanded <- c("root", "engine", "engine/search", "searcher")
code %>% filter(parent %in% expanded) %>% arrange(depth)

# Filter
code %>%
  filter(kind == "function") %>%
  mutate(lines = n_lines, visibility = if_else(str_starts(name, "_"), "private", "public")) %>%
  filter(lines > 50, visibility == "public")

# Aggregate
code %>%
  filter(kind == "function") %>%
  group_by(file) %>%
  summarize(n = n(), total_lines = sum(n_lines), avg_lines = mean(n_lines))

# Join and analyze
code %>%
  filter(kind == "function") %>%
  anti_join(refs %>% filter(ref_kind == "call"), by = c("name" = "to_name")) %>%
  select(name, file, summary)
```

---

## Index Strategy

```sql
CREATE INDEX idx_code_parent ON code(parent);
CREATE INDEX idx_code_kind ON code(kind);
CREATE INDEX idx_code_file ON code(file);
CREATE INDEX idx_code_qname ON code(qname);

CREATE INDEX idx_refs_to ON refs(to_name);
CREATE INDEX idx_refs_from ON refs(from_id);
CREATE INDEX idx_refs_kind ON refs(ref_kind);
```

Most queries use `parent` (navigation), `kind` (filtering), or refs `to_name` (cross-references). Index these.

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

The two-table design (`code` + `refs`) separates the common case (hierarchical navigation) from the complex case (cross-file analysis).

**The core value proposition: summaries at every level, enabling browsing by concept rather than by name.**
