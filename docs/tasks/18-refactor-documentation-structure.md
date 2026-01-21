# Task: Refactor Documentation Structure

## Problem

Current documentation has several issues that make it hard to navigate and maintain:
- Large monolithic files (design/agent/: 1664 lines, design/orchestrator/: 1304 lines, etc.)
- Mixed concerns (design specs, analysis documents, review reports all at top level)
- No clear entry point for new readers
- Tasks not ordered topologically by dependencies
- Historical/obsolete content mixed with current design

## Context

This refactoring supports the project goals defined in CLAUDE.md:
1. Short documentation files (<100 lines each)
2. Use of links between different documentation files
3. Make things easy to find
4. Separation of concerns: tasks, design specs, reference docs, development guides
5. Tasks ordered topologically with file names matching order

## Scenarios

1. **New contributor wants to understand the project**: Should find clear entry point (docs/README.md → getting-started.md → architecture.md) without reading 1000+ line files

2. **Developer implementing new environment**: Needs to find environment contract and examples - should be in focused reference/environment-protocol.md, not buried in large design/orchestrator/

3. **User customizing sandbox**: Wants to understand shell_prefix customization - should find this in design/sandbox/customization.md, not in section 5.1.2 of 1060-line design/sandbox/

4. **Working through tasks in order**: Task file names should reflect dependency order (01-plan.md, 02-orchestrator-design.md, etc.) so it's obvious what comes next

5. **Understanding past design decisions**: Can find historical analysis documents in analysis/ directory with clear "these are historical" context

## Plan

### Phase 1: Create New Structure
- [x] Create directory structure (design/, reference/, development/, analysis/)
- [x] Create docs/README.md (navigation hub)
- [x] Create docs/getting-started.md (quick start guide)
- [x] Create docs/architecture.md (high-level overview with links)
- [x] Create README.md files for each subdirectory

### Phase 2: Split Large Design Docs
- [x] Split design/agent/ into design/agent/*.md (overview, architecture, types, sandboxing, context-management, cost-control)
- [x] Split design/orchestrator/ into design/orchestrator/*.md (overview, architecture, environments, bash-environment, python-environment, editor-environment)
- [x] Split design/sandbox/ into design/sandbox/*.md (overview, bubblewrap, customization, security)
- [x] Split design/help-system/ into design/help-system/*.md (overview, declarative-environments, progressive-disclosure)

### Phase 3: Organize Reference Material
- [x] Create reference/environment-protocol.md (extract from design/orchestrator/)
- [x] Create reference/agent-orchestrator-protocol.md (extract from design/orchestrator/ and design/agent/)
- [x] Create reference/configuration.md (all config options)
- [x] Move reference/coding-style.md to reference/coding-style.md

### Phase 4: Reorganize Development Docs
- [x] Create development/contributing.md
- [x] Create development/testing.md
- [x] Move development/technology.md to development/development/technology.md
- [x] Create development/build-system.md (Nix build details)

### Phase 5: Archive Analysis Documents
- [x] Create analysis/README.md explaining these are historical
- [x] Merge agent-complexity-analysis.md + agent-complexity-addendum.md → analysis/agent-complexity.md
- [x] Rename agent-implementation-vs-design.md → analysis/agent-implementation-review.md
- [x] Move orchestrator-review-report.md → analysis/orchestrator-review.md
- [x] Move error-handling-analysis.md → analysis/error-handling-analysis.md

### Phase 6: Renumber and Reorder Tasks
- [x] Identify correct topological order from tasks/README.md dependency graph
- [x] Rename task files with numeric prefixes (01-, 02-, 03-, etc.)
- [x] Update tasks/README.md checklist to match new file names
- [x] Update cross-references in CLAUDE.md if needed

### Phase 7: Update Cross-References
- [x] Update all links in moved/split files to point to new locations
- [x] Update CLAUDE.md references to docs
- [x] Update README.md references to docs
- [x] Verify all links work (no broken links)

## Dependencies

None - this is documentation-only work that doesn't affect code.

## Outcome

Documentation that is:
- **Navigable**: Clear hierarchy with README.md files guiding exploration
- **Maintainable**: Small files (<100 lines) easy to update
- **Findable**: Logical organization (design/ vs reference/ vs development/ vs analysis/)
- **Linked**: Related content connected via hyperlinks
- **Ordered**: Tasks numbered topologically showing clear path through project

Success criteria:
- Files in docs/design/, docs/reference/, docs/development/ are focused on single topics (exceptions: 6 comprehensive design documents exceed 150 lines but remain cohesive: types.md (209), environments.md (224), editor-environment.md (203), bubblewrap.md (307), customization.md (253), security.md (186))
- All cross-references updated and working
- Tasks numbered in dependency order
- New contributor can understand project structure from docs/README.md in <10 minutes
