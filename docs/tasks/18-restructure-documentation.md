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
- [ ] Create `_archive/` directory
- [ ] Move all current docs (except tasks/ and reference/conventions/documentation.md) to `_archive/`
- [ ] Create new directory structure

### Phase 2: Create Index Files
- [ ] Create `docs/README.md` (main index)
- [ ] Create `docs/reference/README.md`
- [ ] Create `docs/reference/conventions/README.md`
- [ ] Create `docs/design/README.md`
- [ ] Create `docs/design/agent/README.md`
- [ ] Create `docs/design/orchestrator/README.md`
- [ ] Create `docs/design/orchestrator/environments/README.md`
- [ ] Create `docs/design/sandbox/README.md`
- [ ] Create `docs/guides/README.md`

### Phase 3: Migrate Reference Docs
- [ ] Analyze `docs/_archive/reference/coding-style.md`
- [ ] Extract general conventions → `docs/reference/conventions/general.md`
- [ ] Extract Rust conventions → `docs/reference/conventions/rust.md`
- [ ] Extract Python conventions → `docs/reference/conventions/python.md`
- [ ] Create `docs/reference/conventions/documentation.md`
- [ ] Analyze `docs/_archive/development/testing.md`
- [ ] Create `docs/reference/testing.md`
- [ ] Analyze `docs/_archive/reference/configuration.md`
- [ ] Determine if config docs should be in code or docs

### Phase 4: Migrate Design Docs - Agent
- [ ] Analyze `docs/_archive/design/agent/` files
- [ ] Identify what belongs in code vs docs
- [ ] Create `docs/design/agent/architecture.md` (high-level)
- [ ] Create `docs/design/agent/context-management.md` (rationale)
- [ ] Create `docs/design/agent/cost-control.md` (rationale)
- [ ] Create `docs/design/agent/sandboxing.md` (rationale)
- [ ] Update source code doc comments for types/APIs

### Phase 5: Migrate Design Docs - Orchestrator
- [ ] Analyze `docs/_archive/design/orchestrator/` files
- [ ] Identify what belongs in code vs docs
- [ ] Create `docs/design/orchestrator/architecture.md` (high-level)
- [ ] Create `docs/design/orchestrator/protocol.md` (rationale)
- [ ] Create `docs/design/orchestrator/environments/bash.md`
- [ ] Create `docs/design/orchestrator/environments/editor.md`
- [ ] Create `docs/design/orchestrator/environments/python.md`
- [ ] Create `docs/design/orchestrator/environments/system.md`
- [ ] Update source code doc comments for environments

### Phase 6: Migrate Design Docs - Sandbox
- [ ] Analyze `docs/_archive/design/sandbox/` files
- [ ] Create `docs/design/sandbox/bubblewrap.md`
- [ ] Create `docs/design/sandbox/security.md`
- [ ] Create `docs/design/sandbox/customization.md`

### Phase 7: Migrate Guides
- [ ] Analyze `docs/_archive/getting-started.md`
- [ ] Create `docs/guides/getting-started.md`
- [ ] Analyze `docs/_archive/how-to/customize-prompts.md`
- [ ] Create `docs/guides/customize-prompts.md`

### Phase 8: Handle Analysis Docs
- [ ] Analyze `docs/_archive/analysis/` files
- [ ] Determine if any have lasting value (design rationale)
- [ ] Fold relevant content into design docs
- [ ] Discard outdated analysis

### Phase 9: Rework AGENTS.md
- [ ] Review current AGENTS.md content
- [ ] Identify content that belongs in reference/ (e.g., user-story based design cycle)
- [ ] Move design workflow to `docs/reference/design-workflow.md`
- [ ] Move implementation checklist to `docs/reference/implementation-checklist.md`
- [ ] Move pitfalls to `docs/reference/common-pitfalls.md`
- [ ] Keep only essential instructions in AGENTS.md:
  - Run tests via `nix build .#agent` or `nix build .#orchestrator`
  - Never ignore or skip tests
  - Always `git add` new files immediately
  - Build frequently to catch issues early
  - Other critical workflow items
- [ ] Replace detailed content with links to relevant documentation:
  - Link to `docs/reference/conventions/` for coding style
  - Link to `docs/reference/testing.md` for testing strategy
  - Link to `docs/reference/design-workflow.md` for design process
  - Link to `docs/reference/implementation-checklist.md` for implementation
  - Link to `docs/reference/common-pitfalls.md` for pitfalls
- [ ] Ensure AGENTS.md serves as concise entry point for agents

### Phase 10: Cleanup
- [ ] Verify all links work
- [ ] Verify no orphaned content in _archive
- [ ] Remove _archive directory
- [ ] Update any references in code comments

## Dependencies

- None (documentation-only task)

## Outcome

Documentation that is:
- Easy to navigate (clear structure, indexes at every level)
- Clear purpose (reference for conventions, design for rationale, guides for how-to)
- Not duplicating code (API docs in source, rationale in docs)
- LLM and human friendly (short files, good links)
