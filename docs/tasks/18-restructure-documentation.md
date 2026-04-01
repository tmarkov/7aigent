# Task: Restructure Documentation

## Problem

The current documentation structure is confusing and poorly organized:
- Unclear boundaries between doc types (analysis vs design vs reference)
- Task graveyard with 31 numbered files and gaps
- Duplicate/versioned docs (editor-environment.md AND editor-environment-v2.md)
- Scattered entry points (architecture.md, getting-started.md, README.md)
- Mixed purposes (what/why/how mixed together)
- Information that should be in source code duplicated in docs

## Context

- Affects: All of docs/ except tasks/
- Related: AGENTS.md (critical info for agents)
- Goal: Short, focused files with links; both LLM and human friendly

## Principles

1. **Docs for WHY, code for WHAT**: Documentation explains rationale and architecture, not API details
2. **One topic per file**: Short, focused files with links to related content
3. **Right-sizing**: If it changes with code, it belongs in code; if it explains the system, it belongs in docs
4. **Preserve tasks**: Task files remain as-is
5. **Follow documentation conventions**: Use `docs/reference/conventions/documentation.md` as the guide for all documentation work

## Important: Documentation Guide

**The file `docs/reference/conventions/documentation.md` has already been created.**

- This file defines how to write documentation for this project
- It should be preserved during migration (not archived)
- Use it as the guide when creating all other documentation files
- Follow its conventions for file structure, writing style, and content organization

## Target Structure

```
docs/
├── README.md                      # Index with links
├── reference/                     # Project-wide conventions
│   ├── README.md
│   ├── conventions/               # Per-language conventions
│   │   ├── README.md
│   │   ├── rust.md
│   │   ├── python.md
│   │   ├── general.md
│   │   └── documentation.md
│   └── testing.md
├── design/                        # WHY decisions, architecture
│   ├── README.md
│   ├── agent/                     # Agent design
│   │   ├── README.md
│   │   ├── architecture.md
│   │   ├── context-management.md
│   │   ├── cost-control.md
│   │   └── sandboxing.md
│   ├── orchestrator/              # Orchestrator design
│   │   ├── README.md
│   │   ├── architecture.md
│   │   ├── environments/
│   │   │   ├── README.md
│   │   │   ├── bash.md
│   │   │   ├── editor.md
│   │   │   ├── python.md
│   │   │   └── system.md
│   │   └── protocol.md
│   └── sandbox/
│       ├── README.md
│       ├── bubblewrap.md
│       ├── security.md
│       └── customization.md
├── guides/
│   ├── README.md
│   ├── getting-started.md
│   └── customize-prompts.md
├── tasks/                         # Keep as-is
└── _archive/                      # Old docs during migration
```

## Plan

### Phase 1: Setup
- [x] Create `_archive/` directory
- [x] Move all current docs (except tasks/ and reference/conventions/documentation.md) to `_archive/`
- [x] Create new directory structure

### Phase 2: Create Index Files
- [x] Create `docs/README.md` (main index)
- [x] Create `docs/reference/README.md`
- [x] Create `docs/reference/conventions/README.md`
- [x] Create `docs/design/README.md`
- [x] Create `docs/design/agent/README.md`
- [x] Create `docs/design/orchestrator/README.md`
- [x] Create `docs/design/orchestrator/environments/README.md`
- [x] Create `docs/design/sandbox/README.md`
- [x] Create `docs/guides/README.md`

### Phase 3: Migrate Reference Docs
- [x] Analyze `docs/_archive/reference/coding-style.md`
- [x] Extract general conventions → `docs/reference/conventions/general.md`
- [x] Extract Rust conventions → `docs/reference/conventions/rust.md`
- [x] Extract Python conventions → `docs/reference/conventions/python.md`
- [x] Create `docs/reference/conventions/documentation.md` (already existed from earlier phase)
- [x] Analyze `docs/_archive/development/testing.md`
- [x] Create `docs/reference/testing.md`
- [x] Analyze `docs/_archive/configuration.md`
- [x] Determine if config docs should be in code or docs (decision: in code, not docs)

### Phase 4: Migrate Design Docs - Agent
- [x] Analyze `docs/_archive/design/agent/` files
- [x] Identify what belongs in code vs docs
- [x] Create `docs/design/agent/architecture.md` (high-level)
- [x] Create `docs/design/agent/context-management.md` (rationale)
- [x] Create `docs/design/agent/cost-control.md` (rationale)
- [x] Create `docs/design/agent/sandboxing.md` (rationale)
- [x] Update source code doc comments for types/APIs

### Phase 5: Migrate Design Docs - Orchestrator
- [x] Analyze `docs/_archive/design/orchestrator/` files
- [x] Identify what belongs in code vs docs
- [x] Create `docs/design/orchestrator/architecture.md` (high-level)
- [x] Create `docs/design/orchestrator/protocol.md` (rationale)
- [x] Create `docs/design/orchestrator/environments/bash.md`
- [x] Create `docs/design/orchestrator/environments/editor.md`
- [x] Create `docs/design/orchestrator/environments/python.md`
- [x] Create `docs/design/orchestrator/environments/system.md`
- [x] Update source code doc comments for environments

### Phase 6: Migrate Design Docs - Sandbox
- [x] Analyze `docs/_archive/design/sandbox/` files
- [x] Create `docs/design/sandbox/bubblewrap.md`
- [x] Create `docs/design/sandbox/security.md`
- [x] Create `docs/design/sandbox/customization.md`

### Phase 7: Migrate Guides
- [x] Analyze `docs/_archive/getting-started.md`
- [x] Create `docs/guides/getting-started.md`
- [x] Analyze `docs/_archive/how-to/customize-prompts.md`
- [x] Create `docs/guides/customize-prompts.md`

### Phase 8: Handle Analysis Docs
- [x] Analyze `docs/_archive/analysis/` files
- [x] Determine if any have lasting value (design rationale) - None, all are historical records
- [x] Fold relevant content into design docs - Already done (error-handling informed design)
- [x] Discard outdated analysis - Kept as historical records in _archive

### Phase 9: Rework AGENTS.md
- [x] Review current AGENTS.md content
- [x] Identify content that belongs in reference/ (e.g., user-story based design cycle)
- [x] Move design workflow to `docs/reference/design-workflow.md`
- [x] Move implementation checklist to `docs/reference/implementation-checklist.md`
- [x] Move pitfalls to `docs/reference/common-pitfalls.md`
- [x] Keep only essential instructions in AGENTS.md:
  - Run tests via `nix build .#agent` or `nix build .#orchestrator`
  - Never ignore or skip tests
  - Always `git add` new files immediately
  - Build frequently to catch issues early
  - Other critical workflow items
- [x] Replace detailed content with links to relevant documentation:
  - Link to `docs/reference/conventions/` for coding style
  - Link to `docs/reference/testing.md` for testing strategy
  - Link to `docs/reference/design-workflow.md` for design process
  - Link to `docs/reference/implementation-checklist.md` for implementation
  - Link to `docs/reference/common-pitfalls.md` for pitfalls
- [x] Ensure AGENTS.md serves as concise entry point for agents

### Phase 10: Cleanup
- [x] Verify all links work
- [x] Verify no orphaned content in _archive
- [x] Remove _archive directory
- [x] Update any references in code comments

## Dependencies

- None (documentation-only task)

## Outcome

Documentation that is:
- Easy to navigate (clear structure, indexes at every level)
- Clear purpose (reference for conventions, design for rationale, guides for how-to)
- Not duplicating code (API docs in source, rationale in docs)
- LLM and human friendly (short files, good links)
