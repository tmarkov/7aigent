# Description

Implement the editor environment, which provides pattern-based file viewing and line-based editing. This is the most complex environment and should be implemented after learning from bash and Python.

# Plan

- [ ] Implement EditorEnvironment class
  - [ ] Implement view state management
  - [ ] Implement handle_command() method
  - [ ] Implement get_screen() method
  - [ ] Implement view ID generation

- [ ] Implement view command
  - [ ] Parse view command (filepath, start_pattern, end_pattern, optional label)
  - [ ] Implement pattern matching logic
  - [ ] Handle multiple matches
  - [ ] Enforce 3 view maximum
  - [ ] Auto-close oldest view when adding 4th

- [ ] Implement view generation
  - [ ] File reading with caching per refined design
  - [ ] Pattern regex compilation and matching
  - [ ] 1000 line search limit
  - [ ] Line number display
  - [ ] 200 character line truncation
  - [ ] Content caching for edit verification

- [ ] Implement next_match/prev_match commands
  - [ ] Navigate between multiple pattern matches
  - [ ] Update current_match_index
  - [ ] Display match count (N/M)

- [ ] Implement edit command
  - [ ] Parse edit command with multi-line content
  - [ ] Find view containing line numbers
  - [ ] Verify cached content matches current file
  - [ ] Perform line replacement
  - [ ] Write file

- [ ] Implement create command
  - [ ] Parse create command with multi-line content
  - [ ] Create new file
  - [ ] Handle existing file error

- [ ] Implement close command
  - [ ] Remove view by ID

- [ ] Handle edge cases (per simplified design)
  - [ ] File deleted: keep broken view, show [BROKEN]
  - [ ] Patterns not found: keep broken view, show [BROKEN]
  - [ ] End pattern not found within 1000 lines: truncate and mark
  - [ ] Binary file detection
  - [ ] File changed during edit: reject with error
  - [ ] Edit outside view: reject with error

- [ ] Write tests
  - [ ] Test view creation and display
  - [ ] Test pattern matching
  - [ ] Test multiple match navigation
  - [ ] Test edit verification
  - [ ] Test file creation
  - [ ] Test view closing
  - [ ] Test all edge cases
  - [ ] Test maximum view limit

- [ ] Manual testing
  - [ ] Test with real code files (C, Python, Rust)
  - [ ] Test with markdown files
  - [ ] Test external file modifications
  - [ ] Test pattern robustness

- [ ] Run formatters and linters

# Dependencies

- Requires: Orchestrator types (implement-orchestrator-types.md)
- Requires: Refined design with simplifications applied
- Recommended: Learn from bash and Python implementations first

# Outcome

A working editor environment with pattern-based views and line-based editing, ready for agent use.
