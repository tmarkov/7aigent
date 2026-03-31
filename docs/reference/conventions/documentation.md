# Documentation Conventions

This file defines how to write documentation for this project. Follow these conventions when creating or updating any documentation.

## Core Principles

1. **Docs for WHY, code for WHAT**: Documentation explains rationale and architecture, not API details
2. **One topic per file**: Short, focused files with links to related content
3. **Right-sizing**: If it changes with code, it belongs in code; if it explains the system, it belongs in docs
4. **Both LLM and human friendly**: Short files, clear structure, good links

## What Goes Where

### In Source Code
- API documentation (docstrings, rustdoc)
- Function/method behavior
- Type definitions and their purposes
- Implementation notes
- Examples of usage
- "Related files" references

### In Documentation
- High-level architecture
- Design rationale (WHY decisions were made)
- Alternatives considered
- Cross-cutting concerns
- Project-wide conventions
- User/developer guides

## File Structure

### Index Files (README.md)

Every directory should have a `README.md` that:
- Lists the contents of the directory
- Explains what type of content belongs there
- Links to each file with a brief description

Example:
```markdown
# Design Documentation

This directory contains design rationale and architecture decisions.

## Contents

- [agent/](./agent/) - Agent design decisions
- [orchestrator/](./orchestrator/) - Orchestrator design decisions
- [sandbox/](./sandbox/) - Sandbox design decisions
```

### Content Files

Each content file should:
- Start with a clear title (H1)
- Have a brief introduction (1-2 sentences)
- Use headings (H2, H3) to organize content
- Link to related files instead of repeating content
- End with "Related Files" section when applicable

Example structure:
```markdown
# Topic Name

Brief introduction to what this document covers.

## Section

Content here.

### Subsection

More specific content.

## Related Files

- `path/to/code.py` - Implementation
- `path/to/other-doc.md` - Related documentation
```

## Writing Style

### Be Concise
- Short paragraphs (2-4 sentences)
- Bullet lists for multiple items
- Code examples for concrete illustration

### Be Explicit
- "This component does X" not "This component is designed to X"
- "Use Y when Z" not "Y might be useful for Z"

### Link Liberally
- Link to related docs: `[related topic](../other/file.md)`
- Link to source code: `path/to/code.py` (code paths in backticks)
- Prefer relative links for portability

### Show Relationships
- "See also:" for related docs
- "Related files:" for source code connections
- "Prerequisites:" for required reading

## Document Types

### Reference Documentation (`docs/reference/`)
- **Purpose**: Project-wide conventions and specifications
- **Content**: Coding style, testing strategy, configuration
- **Style**: Definitive, prescriptive
- **Examples**: `conventions/rust.md`, `testing.md`

### Design Documentation (`docs/design/`)
- **Purpose**: Architecture and design rationale
- **Content**: WHY decisions were made, alternatives considered
- **Style**: Explanatory, historical
- **Examples**: `agent/architecture.md`, `orchestrator/protocol.md`

### Guides (`docs/guides/`)
- **Purpose**: How-to for users and developers
- **Content**: Step-by-step instructions, tutorials
- **Style**: Task-oriented, practical
- **Examples**: `getting-started.md`, `customize-prompts.md`

### Tasks (`docs/tasks/`)
- **Purpose**: Work tracking
- **Content**: Problem description, plan, progress
- **Style**: Actionable, checklist-based
- **Examples**: `18-restructure-documentation.md`

## What NOT to Document

Don't duplicate in docs what's better in code:

| In Code Instead | Why |
|-----------------|-----|
| Function parameters | Compiler/type checker enforces |
| Return types | Compiler/type checker enforces |
| API endpoints | Docstrings are closer to implementation |
| Configuration options | Schema/defaults in code are authoritative |
| Error codes | Enum/constant definitions are authoritative |

## Maintenance

When code changes:
1. Update docstrings first (in the same PR/commit)
2. Update design docs only if architecture changed
3. Update guides only if user-facing behavior changed

When adding new features:
1. Add docstrings to new code
2. Add design doc if new component or significant change
3. Add guide if user-facing feature

## Related Files

- `docs/reference/conventions/general.md` - General coding conventions
- `docs/reference/conventions/rust.md` - Rust-specific conventions
- `docs/reference/conventions/python.md` - Python-specific conventions
