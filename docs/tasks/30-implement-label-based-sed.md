# Task: Implement Label-Based Sed for Editor Environment

## Description

Add a `sed` command to the editor environment that performs search-and-replace operations on content currently visible in a specific view. This allows agents to make targeted changes across multiple files using semantic references (view labels) rather than requiring exact file paths and line numbers.

## Context

- **Component**: `orchestrator/environments/editor/` (add to environment.py, parser.py)
- **Related**: Task 26 (query-based pipeline system), Task 07 (original editor environment)
- **Motivation**: Agents frequently need to make systematic replacements across code. Currently they must:
  1. View files to see content
  2. Edit each file individually with exact line ranges
  3. Re-view to verify changes
  
  Label-based sed simplifies this by operating on already-visible content, ensuring safety (agent sees what it's changing) and enabling multi-file operations in a single command.

## Scenarios

### Scenario 1: Single-File Replacement

**Situation**: Agent has a view showing TODO comments in a Python file and wants to mark them as done.

**Workflow**:
```xml
<editor>
  view todos /TODO/ in src/main.py | context 1
</editor>
<!-- Shows: -->
<!--   45 | # TODO: Fix this -->
<!--   46 |   x = old_function() -->
<!--   87 | # TODO: Add error handling -->
<!--   88 |   process() -->

<editor>
  sed todos /TODO/DONE/g
</editor>
<!-- Response: -->
<!--   Replaced 2 occurrences in 1 file -->
<!--   src/main.py: 45, 87 -->

<editor>
  view todos /TODO/ in src/main.py | context 1
</editor>
<!-- Shows no matches (all TODOs replaced) -->
```

**Success criteria**:
- Only visible lines are modified (lines 45, 87, not other files or hidden lines)
- Multiple occurrences on same line handled correctly
- Response clearly shows what was changed

### Scenario 2: Multi-File Replacement

**Situation**: Agent has a view showing all imports across multiple files and wants to rename an imported module.

**Workflow**:
```xml
<editor>
  view imports /from old_module import/ in **/*.py
</editor>
<!-- Shows imports in: -->
<!--   src/main.py: 3 -->
<!--   src/utils.py: 12 -->
<!--   src/processor.py: 7 -->

<editor>
  sed imports /from old_module/from new_module/g
</editor>
<!-- Response: -->
<!--   Replaced 3 occurrences in 3 files -->
<!--   src/main.py: 3 -->
<!--   src/utils.py: 12 -->
<!--   src/processor.py: 7 -->
```

**Success criteria**:
- Changes made across all files in view
- Each file's changes tracked separately
- Clear summary of what was changed where

### Scenario 3: Pattern with Capture Groups

**Situation**: Agent needs to refactor function calls to use keyword arguments.

**Workflow**:
```xml
<editor>
  view calls /process_data\(/ in src/**/*.py | while-indent | limit 10
</editor>
<!-- Shows function calls -->

<editor>
  sed calls /process_data\((\w+),\s*(\w+)\)/process_data(input=$1, output=$2)/g
</editor>
<!-- Response: -->
<!--   Replaced 5 occurrences in 2 files -->
<!--   src/processor.py: 45, 67, 89 -->
<!--   src/handler.py: 23, 34 -->
```

**Success criteria**:
- Capture groups ($1, $2, etc.) work in replacement
- Regex escaping handled correctly
- Multiple matches per line handled

### Scenario 4: Error Cases

**Situation**: Agent makes mistakes using sed.

**Workflow**:
```xml
<!-- Non-existent label -->
<editor>
  sed nonexistent /old/new/
</editor>
<!-- Response: -->
<!--   Error: No view found with label 'nonexistent' -->
<!--   Active views: imports, calls -->

<!-- Invalid regex -->
<editor>
  sed imports /unclosed[/new/
</editor>
<!-- Response: -->
<!--   Error: Invalid regex pattern: unclosed[ -->
<!--   Details: unterminated character class at position 8 -->

<!-- View with no visible lines -->
<editor>
  view empty /NONEXISTENT_PATTERN/ in src/*.py
</editor>
<editor>
  sed empty /old/new/
</editor>
<!-- Response: -->
<!--   Error: View 'empty' has no visible lines to operate on -->
```

**Success criteria**:
- Clear error messages for common mistakes
- Suggest available labels when label not found
- Show regex parse errors with position

### Scenario 5: Safety - Only Visible Lines

**Situation**: Agent tries to sed a view that shows limited context, ensuring hidden lines aren't affected.

**Workflow**:
```xml
<editor>
  view section /^## Introduction/ in README.md | until /^## /
</editor>
<!-- Shows lines 10-25 (Introduction section) -->
<!-- Line 10: ## Introduction -->
<!-- Line 25: ## Next Section (not included) -->

<editor>
  sed section /Introduction/Overview/
</editor>
<!-- Response: -->
<!--   Replaced 1 occurrence in 1 file -->
<!--   README.md: 10 -->

<!-- Lines outside the view (e.g., other sections) are NOT changed -->
<!-- Even if they contain "Introduction" -->
```

**Success criteria**:
- Only lines visible in the view are modified
- Other occurrences of pattern in same file but outside view are unchanged
- This is a core safety property

## Plan

### Design Verification
- [ ] Review existing editor environment architecture
- [ ] Confirm sed command fits into DeclarativeEnvironment pattern
- [ ] Design error handling strategy

### Implementation
- [ ] Add sed command signature to environment.py
  - [ ] Parse command: `sed <label> /pattern/replacement/[flags]`
  - [ ] Validate label exists
  - [ ] Validate regex pattern
  - [ ] Support flags: g (global), i (case-insensitive)

- [ ] Implement sed logic in environment.py
  - [ ] Get all windows for label from WindowManager
  - [ ] Group windows by file
  - [ ] For each file, apply substitution to visible line ranges only
  - [ ] Track changes per file
  - [ ] Write modified files
  - [ ] Return summary of changes

- [ ] Add tests
  - [ ] Test single-file replacement
  - [ ] Test multi-file replacement
  - [ ] Test capture groups
  - [ ] Test flags (g, i)
  - [ ] Test error cases (invalid label, invalid regex, empty view)
  - [ ] Test safety (only visible lines modified)

### Documentation
- [ ] Update help.md with sed command documentation
- [ ] Add examples to command help

### Verification
- [ ] Run `nix build .#orchestrator` to verify all checks pass
- [ ] Manual testing with TUI or orchestrator directly

## Dependencies

- Task 26 (Reimplement Editor Environment) - must be complete
- Editor environment must have working view/peek commands
- WindowManager must track active views by label

## Outcome

A working `sed` command that:
- Operates on content visible in a named view
- Supports regex patterns with capture groups
- Supports flags (g for global, i for case-insensitive)
- Works across multiple files when view spans files
- Provides clear error messages for invalid inputs
- Only modifies lines currently visible in the view (safety)
- Returns a summary of changes made
