# Editor Environment Design

The editor environment provides query-based file viewing and editing. All views are procedural—they re-execute queries on every screen refresh, ensuring views always show current file content even as files change.

## Purpose

View and edit files, search across the codebase, maintain persistent views of code sections. This is the primary environment for:
- Code exploration and understanding
- File editing and creation
- Multi-file search
- Persistent views of code sections

## Core Principle: Procedural Views

**All views are queries, not snapshots.**

When files change, the screen regenerates by re-executing all view queries. This ensures the screen always shows current content at the correct locations.

```
Agent: view /def process_data/ in file.py | while-indent
→ Stores QUERY, not line numbers

File edited, lines shift
→ Screen regeneration re-executes query
→ Finds /def process_data/ at NEW location
→ Expands from current position
→ Screen shows correct content
```

This is why the editor CANNOT support direct line number access for persistent views—line numbers become stale immediately.

## Design Decisions

### Query-Based Views

Views are defined by pattern matchers, not fixed line numbers. This allows views to remain meaningful even when files are modified.

**Trade-off**: Agent cannot jump to a specific line by number for persistent views. Must use `peek` for line-based access (transient, one-time).

### Labeled Views

Each persistent view has a mandatory label. Same label overwrites previous view. This:
- Prevents accidental view proliferation
- Makes view management explicit
- Enables targeted operations (close, sed)

### Hard Limits

- **Peek limit**: 300 lines per peek (transient, not stored)
- **Total view limit**: 3000 lines across all views
- **Query limit**: 50 active queries

These limits prevent runaway screen growth and ensure the agent can see all relevant content.

### Edit Requires View

Files can only be edited if the target lines are visible in an active view. This prevents editing stale content—if the file has changed since the view was last generated, the edit is rejected.

**Trade-off**: Agent must view before editing. Extra step, but prevents accidental overwrites.

### Line-Based Editing

Despite pattern-based views, editing uses line numbers. The agent specifies exact line ranges to replace. This is because:
- Pattern-based editing is ambiguous (which match?)
- Line ranges are precise and unambiguous
- Agent can see the exact lines in the view

## Pipeline Operations

### Expansion Operations

- `context N` — Add N lines above and below
- `up N` / `down N` — Expand in one direction
- `while-indent` — Expand while indented (captures code blocks)
- `until /pattern/` — Expand down until pattern matches
- `up-until /pattern/` — Expand up until pattern matches
- `until-blank` — Expand down until blank line

### Filtering Operations

- `filter /pattern/` — Keep only windows matching pattern
- `exclude /pattern/` — Remove windows matching pattern
- `limit N` — Keep only first N windows

## Commands

- `view <label> <matcher> in <glob> | <operations>` — Persistent labeled view
- `peek <matcher> in <glob> | <operations>` — Transient one-time read
- `edit <file> <start>-<end>` — Replace lines (must be visible)
- `create <file>` — Create new file with content
- `close label <name>` — Remove specific view
- `close pattern <glob>` — Remove views matching pattern
- `close all` — Remove all views
- `sed <label> /pattern/replacement/[flags]` — Search-replace in visible lines

## Related Files

- `orchestrator/environments/editor/` — Implementation (query-based pipeline)
- `orchestrator/environments/editor/parser.py` — Command parsing
- `orchestrator/environments/editor/queries.py` — Query execution
- `docs/design/orchestrator/protocol.md` — Communication protocol
