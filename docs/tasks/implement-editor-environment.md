# Description

Implement the editor environment, which provides pattern-based file viewing and line-based editing. This is the most complex environment and should be implemented after learning from bash and Python.

# Plan

- [x] Implement EditorEnvironment class
  - [x] Implement view state management
  - [x] Implement handle_command() method
  - [x] Implement get_screen() method
  - [x] Implement view ID generation

- [x] Implement view command
  - [x] Parse view command (filepath, start_pattern, end_pattern, optional label)
  - [x] Implement pattern matching logic
  - [x] Handle multiple matches
  - [x] Enforce 3 view maximum
  - [x] Auto-close oldest view when adding 4th

- [x] Implement view generation
  - [x] File reading (re-reads on every screen generation)
  - [x] Pattern regex compilation and matching
  - [x] 1000 line search limit
  - [x] Line number display
  - [x] 200 character line truncation
  - [x] Content caching for edit verification

- [x] Implement next_match/prev_match commands
  - [x] Navigate between multiple pattern matches
  - [x] Update current_match_index
  - [x] Display match count (N/M)

- [x] Implement edit command
  - [x] Parse edit command with multi-line content
  - [x] Find view containing line numbers
  - [x] Verify cached content matches current file
  - [x] Perform line replacement
  - [x] Write file

- [x] Implement create command
  - [x] Parse create command with multi-line content
  - [x] Create new file
  - [x] Handle existing file error

- [x] Implement close command
  - [x] Remove view by ID

- [x] Implement search command
  - [x] Parse search command with pattern and glob
  - [x] Regex matching across files
  - [x] Return matching lines with file:line:content format

- [x] Handle edge cases (per simplified design)
  - [x] File deleted/not found: remove broken view after displaying [BROKEN]
  - [x] Patterns not found: remove broken view after displaying [BROKEN]
  - [x] End pattern not found within 1000 lines: truncate and mark
  - [x] Binary file detection
  - [x] File changed during edit: reject with error
  - [x] Edit outside view: reject with error

- [x] Write tests
  - [x] Test view creation and display
  - [x] Test pattern matching
  - [x] Test multiple match navigation
  - [x] Test edit verification
  - [x] Test file creation
  - [x] Test view closing
  - [x] Test search command
  - [x] Test all edge cases
  - [x] Test maximum view limit

- [ ] Manual testing (deferred - automated tests cover all functionality)
  - [ ] Test with real code files (C, Python, Rust)
  - [ ] Test with markdown files
  - [ ] Test external file modifications
  - [ ] Test pattern robustness

- [x] Run formatters and linters

# Dependencies

- Requires: Orchestrator types (implement-orchestrator-types.md)
- Requires: Refined design with simplifications applied
- Recommended: Learn from bash and Python implementations first

# Outcome

A working editor environment with pattern-based views and line-based editing, ready for agent use.
