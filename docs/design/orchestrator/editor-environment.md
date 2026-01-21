# Editor Environment

**Purpose**: View and edit files, maintain persistent views of code sections.

## Implementation

- Manages set of "views" (file sections currently visible on screen)
- Views use pattern-based boundaries (regex) to track content semantically
- Views persist across commands and **always re-read files** on every screen generation
- Provides pattern-based viewing and line-based editing operations
- Simple search across files

## Command format

```editor
view <filepath> /<start_pattern>/ /<end_pattern>/ [<label>]
edit <filepath> <start_line>-<end_line>
<new content on subsequent lines>
search "<pattern>" <glob>
create <filepath>
<initial content on subsequent lines>
close <view_id>
next_match <view_id>
prev_match <view_id>
```

**Multi-line command parsing**: For `edit` and `create` commands, the first line contains the command and parameters. All subsequent lines are treated as content to write.

**Pattern-based views**: Views are defined by start and end regex patterns, not fixed line numbers. This allows views to remain meaningful even when files are modified. The agent specifies patterns in the view command, and the editor finds all matches in the file.

## Response format

```
view: "Added view [id] filepath /<start>/ to /<end>/"
edit: "Edited filepath lines start-end"
search: "Matches:
  filepath:line_num: matched line
  ..."
create: "Created filepath"
close: "Closed view [id]"
next_match: "Showing match N/M"
prev_match: "Showing match N/M"
```

## Screen format

```
Views:
  [1] src/main.py /^def main/ to /^if __name__/ (match 1/1)
     45  def main():
     46      parser = argparse.ArgumentParser()
     ...
     78  if __name__ == '__main__':

  [2] src/api.py /^class APIHandler/ to /^class \w+/ (match 1/2) "APIHandler"
    120  class APIHandler:
    121      def __init__(self):
    122          self.routes = {}
    ...
    156  class RequestParser:  # End pattern match
```

**Pattern matching**: When multiple matches exist for a pattern pair, the view shows which match is currently displayed (e.g., "match 1/2"). Use `next_match` and `prev_match` commands to cycle through matches.

## Use cases supported

- Reading code by semantic boundaries: `view src/main.c /^int main\(/ to /^}$/`
- Reading class definitions: `view src/api.py /^class UserManager/ to /^class \w+/`
- Reading markdown sections: `view README.md /^## Installation/ to /^## Usage/`
- Editing files: Agent sees line numbers on screen, uses them for edits
- Creating files: `create src/new.py` + initial content
- Searching: `search "TODO" *.py` returns line numbers
- Multi-file viewing: Multiple `view` commands create multiple views (max 5)
- Navigation: Use `next_match`/`prev_match` when pattern matches multiple locations

## State maintained

- List of views: (id, filepath, start_pattern, end_pattern, current_match_index, label)
- Cached content from last screen generation (for edit verification)
- Next view ID counter

## Design decisions

1. **Pattern-based views**: Views use regex patterns for boundaries, not fixed line numbers
2. **Always re-read files**: No mtime checking or caching. Re-read EVERY time screen is generated.
3. **Views persist**: Once added, view stays until explicitly closed or patterns not found
4. **Maximum views**: 5 views max, close oldest when adding 6th
5. **Maximum view size**: 1000 lines per view (truncate if match is larger)
6. **Search is transient**: Returns list in response, not a persistent view
7. **Labels are optional**: For semantic meaning (e.g., "main function")
8. **Minimal screen until first use**: Before any views opened, show only "Editor (no views)"
9. **Edit verification**: Can only edit lines visible in a view; verify content matches before edit
10. **Pattern updates**: If boundary line is edited, pattern updated to literal text (escaped)
11. **Broken views auto-removed**: If patterns not found, view removed from list

## View generation (every screen update)

```
For each view:
1. Re-read entire file from disk
2. Find all occurrences of start_pattern
3. For each start match, search up to 1000 lines for end_pattern
4. If end pattern found, extract content from start to end
5. If end pattern not found within 1000 lines, extract 1000 lines and mark as truncated
6. Select match based on current_match_index
7. Cache content and line numbers for edit verification
8. Display with line numbers
9. If no start pattern found, remove view and show [BROKEN]
```

## Edit implementation

```
edit <filepath> <start_line>-<end_line>
<new content>

Process:
1. Find view containing these line numbers
2. Verify view's cached content matches current file at those lines
3. If mismatch: reject edit (file changed)
4. Replace lines [start_line, end_line] inclusive with new content
5. Write file
6. If edited line is a boundary, update pattern to literal match
```

## Pattern search constraints

- Search up to 1000 lines after start pattern for end pattern
- If end pattern not found within 1000 lines, truncate view at 1000 lines
- Greedy matching: always use first occurrence of end pattern (within 1000 line limit)

## Example workflow

```
Agent: editor: view src/main.c /^int main\(/ /^}$/

Screen shows:
  [1] src/main.c /^int main\(/ to /^}$/ (match 1/2)
    45  int main() {
    46      printf("Hello\n");
    47      return 0;
    48  }

Agent notices this is wrong function (wanted main(), got main_helper())

Agent: editor: next_match 1

Screen updates:
  [1] src/main.c /^int main\(/ to /^}$/ (match 2/2)
    120  int main(int argc, char** argv) {
    121      setup();
    122      run();
    123      return 0;
    124  }

Agent edits line 121:

Agent: editor: edit src/main.c 121-121
    initialize();

Response: "Edited src/main.c lines 121-121"

Next screen generation:
  [1] src/main.c /^int main\(/ to /^}$/ (match 2/2)
    120  int main(int argc, char** argv) {
    121      initialize();  # View automatically shows updated content
    122      run();
    123      return 0;
    124  }

If file externally modified (e.g., main() deleted):
  [1] src/main.c [BROKEN: patterns not found]
  # View automatically removed
```

## Edge cases

- File deleted: View shows `[ERROR: file not found]`, then removed
- Patterns not found: View shows `[BROKEN: patterns not found]`, then removed
- End pattern not found within 1000 lines: Truncate view at 1000 lines, show `[TRUNCATED: end pattern not found within 1000 lines]`
- Too many views: Auto-close oldest when adding 6th view
- Empty file: Patterns won't match, view not created
- Binary file: Detect and refuse with error message
- Multiple matches: Show match indicator (1/3), use next_match/prev_match to navigate
- Edit outside view: Reject with error "Can only edit lines visible in a view"
- File changed during edit: Reject with error showing expected vs actual content
- Boundary line edited: Pattern automatically updated to literal (escaped) text

## Deferred features (not in initial version)

- LSP integration (goto_definition, find_references, rename)
- Diff viewing
- Syntax highlighting in screen output
- Multi-file search with context
- Configurable view size limits
- Non-greedy or custom pattern matching strategies

## Related Documents

- [Environment Contract](environments.md)
- [Bash Environment Design](bash-environment.md)
- [Python Environment Design](python-environment.md)
- [Orchestrator Overview](overview.md)
