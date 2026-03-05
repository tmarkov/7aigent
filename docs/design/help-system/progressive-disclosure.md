# Progressive Disclosure

This document describes how the help system uses progressive disclosure to balance completeness with screen space efficiency.

## The Problem

Static help systems face a dilemma:
- **Too much detail**: Screen filled with documentation, reduces space for actual state
- **Too little detail**: Agent can't discover or use commands effectively

## Solution: Per-Command Progressive Disclosure

For structured command environments (Editor, custom commands), track usage **per command**:
- **Command never used**: Show LONG help (signature + detailed description + example)
- **Command already used**: Show SHORT help (signature + one-line description)

This gives the agent exactly the information needed for the next step while keeping screen compact.

## Why Per-Command (Not Per-Environment)

**Alternative considered**: Collapse ALL help after first command in an environment.

**Problem**: Information loss. If Editor has 7 commands and agent uses `view`, it still needs detailed help for `edit`, `search`, `create`, etc.

**Per-command tracking**: Each command transitions from LONG → SHORT independently, showing detailed help exactly when needed.

## Example: Editor Environment

### Initial Screen (No Commands Used)

```
==================== EDITOR ====================
Views:
  (no views)

Commands:
  view <label> <matcher> in <glob> | <operations>
    Create a persistent labeled view by executing a query pipeline.
    Matchers: /pattern/, line N, line N-M (in specific file only)
    Operations: context N, while-indent, until-blank, filter, limit
    Example:
      <editor>
      view main /^def main/ in src/*.py | while-indent

</editor>

  peek <matcher> in <glob> | <operations>
    Transiently view content without creating a persistent view.
    Same syntax as view but results are discarded after screen refresh.
    Example:
      <editor>
      peek /TODO/ in **/*.py | context 3 | limit 5

</editor>

  edit <file> <start>-<end>
    Replace lines with new content. Lines must be visible in a view.
    Content is provided on subsequent lines after the command.
    Example:
      <editor>
      edit src/main.py 45-50
      def process(verbose=False):
          if not verbose:
              return

</editor>

  create <file>
    Create a new file with initial content.
    Content is provided on subsequent lines after the command.
    Example:
      <editor>
      create new_file.py
      # New module

</editor>

  close label <name> - Close view by label
  close pattern <glob> - Close all views matching label pattern
  close file <path> - Close all views of a file
  close all - Close all views
```

**Note**: Simple commands (close variants) only show SHORT help even initially - they're self-explanatory.

### After Using `view`

```
==================== EDITOR ====================
Views:
  [main] src/main.py
     45  def main():
     46      parser = argparse.ArgumentParser()
     ...
     78      return 0

Commands:
  view <label> <matcher> in <glob> | <operations> - Create persistent labeled view
  peek <matcher> in <glob> | <operations> - Transiently view content

  edit <file> <start>-<end>
    Replace lines with new content. Lines must be visible in a view.
    Content is provided on subsequent lines after the command.
    Example:
      <editor>
      edit src/main.py 45-50
      def process(verbose=False):
          if not verbose:
              return

</editor>

  create <file>
    Create a new file with initial content.
    Content is provided on subsequent lines after the command.
    Example:
      <editor>
      create new_file.py
      # New module

</editor>

  close label <name> - Close view by label
  close pattern <glob> - Close all views matching label pattern
  close file <path> - Close all views of a file
  close all - Close all views
```

**Changes**:
- `view` collapsed to one line (agent already knows how to use it)
- `peek` also collapsed (similar to view)
- `edit` and `create` still show full help (not yet used)
- Screen space freed for the view content

### After Using `view`, `edit`, `peek`

```
==================== EDITOR ====================
Views:
  [main] src/main.py
     45  def main():
     46      parser = argparse.ArgumentParser()
     ...
     78      return 0

Commands:
  view <label> <matcher> in <glob> | <operations> - Create persistent labeled view
  peek <matcher> in <glob> | <operations> - Transiently view content
  edit <file> <start>-<end> - Replace lines (must be visible in a view)

  create <file>
    Create a new file with initial content.
    Content is provided on subsequent lines after the command.
    Example:
      <editor>
      create new_file.py
      # New module

</editor>

  close label <name> - Close view by label
  close pattern <glob> - Close all views matching label pattern
  close file <path> - Close all views of a file
  close all - Close all views
```

**Key insight**: When agent needs `create` for the first time, LONG help with example is still there!

## Freeform Environments (No Progressive Disclosure)

### Bash Environment

**Screen** (always the same):
```
Working directory: /home/user/project
Last exit code: 0
Background jobs: [1] 12345 ./server

Any bash command. Use & for background jobs.
```

**Rationale**: Bash accepts any command. No structured command set to progressively disclose. Brief reminder is sufficient.

### Python Environment

**Screen** (always the same):
```
Working directory: /home/user/project

Variables (recent):
  df: DataFrame
  model: RandomForestClassifier
  X_train: ndarray

Any Python code. Variables and imports persist across commands.
```

**Rationale**: Python accepts any code. Variable list provides context. No commands to learn.

## Error Recovery (Response, Not Screen)

Error recovery help appears in **response output**, not on screen.

### Example: Edit Without View

**Agent command**:
<editor>
edit src/main.py 45-50
new content
</editor>

**Response** (success=False):
```
Cannot edit - no view contains line 45

To edit a file:
  1. Create a view first: view src/main.py /^def main/ /^$/
  2. See line numbers in the view on screen
  3. Edit using those lines: edit src/main.py 45-50

The view command is shown above in the Commands section.
```

**Screen** (unchanged):
```
Views:
  (no views)

Commands:
  view <file> /<start>/ /<end>/ [label]
    View a section of a file using regex patterns...
  ...
```

**Rationale**:
- Error recovery is one-time contextual help → belongs in response
- Screen shows persistent state and available commands
- Agent can see both: error recovery steps + detailed help for `view` command

## Design Trade-offs

### Decision: Per-Command Tracking

**Benefit**: Agent always has detailed help for unused commands
**Cost**: More complex implementation than per-environment tracking
**Verdict**: Worth it - significantly better UX

### Decision: Short Help Format

**Format**: `signature - one-line description`

**Alternative considered**: Only show signature

**Chosen format rationale**:
- Signature alone doesn't explain what command does
- One-line description provides context without bulk
- Agent can pattern-match on previous usage in conversation history

### Decision: Example Format

**Authors provide raw command text**:
<python>
@command(
    signature="edit <file> <start>-<end>",
    description="Replace lines...",
    example="edit src/main.py 45-50\n    new code"  # Raw
)
</python>

**Framework wraps in markdown**:
```
    Example:
      <editor>
      edit src/main.py 45-50
          new code
      
</editor>
```

**Rationale**:
- Authors shouldn't repeat environment name
- Framework ensures consistent formatting
- Simpler for custom environment authors

## Implementation in DeclarativeEnvironment

The progressive disclosure logic is implemented in `DeclarativeEnvironment.get_screen()`:

<python>
for cmd_name in sorted(self._commands.keys()):
    method, metadata = self._commands[cmd_name]
    sig = metadata['signature']
    desc = metadata['description']
    example = metadata['example']

    if cmd_name in self._command_usage:
        # SHORT: Used command
        short_desc = desc.split('\n')[0]
        commands_help.append(f"  {sig} - {short_desc}")
    else:
        # LONG: Unused command
        commands_help.append(format_long_help(sig, desc, example))
</python>

Usage tracking happens in `handle_command()`:
<python>
self._command_usage.add(cmd_name)
</python>

## Related Documents

- [Help System Overview](overview.md) - Overall design principles
- [Declarative Environments](declarative-environments.md) - Base class API and usage
- [Orchestrator Architecture](../orchestrator/) - Environment protocol
