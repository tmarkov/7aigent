# Task: Implement DeclarativeEnvironment Base Class

## Description

Implement the `DeclarativeEnvironment` base class that enables environments with structured command sets to automatically generate help screens with per-command progressive disclosure. Then refactor the Editor environment to use this base class, replacing its manual command parsing and screen generation with the declarative pattern.

## Context

- **Component**: `orchestrator/declarative.py` (new), `orchestrator/environments/editor.py` (refactor)
- **Related**: Help system design (docs/help-system-design.md)
- **Motivation**: Editor currently has manual command parsing and static screen output. DeclarativeEnvironment will provide automatic help generation, per-command usage tracking, and cleaner command implementation.

## Scenarios

### Scenario 1: Editor commands work identically after refactor

**Situation**: Agent uses editor to view and edit files

**Commands**:
1. `editor: view src/main.py /^def main/ /^if __name__/`
2. `editor: edit src/main.py 45-50` (with content)
3. `editor: search "TODO" *.py`
4. `editor: create new.py` (with content)

**Success criteria**: All commands produce identical output and behavior as before refactor

### Scenario 2: Help screen shows per-command progressive disclosure

**Situation**: Agent uses editor for first time, then uses some commands

**Initial screen**: Shows LONG help for all commands (descriptions + examples)

**After using `view`**: Shows SHORT help for `view`, LONG help for other commands

**After using `view` and `create`**: Shows SHORT help for both, LONG help for remaining

**Success criteria**: Screen adapts correctly based on which commands have been used

### Scenario 3: Custom environment uses DeclarativeEnvironment

**Situation**: Developer creates a timer environment using DeclarativeEnvironment

**Code**:
```python
from orchestrator.declarative import DeclarativeEnvironment, command

class TimerEnvironment(DeclarativeEnvironment):
    """Timer for tracking elapsed time"""

    def __init__(self):
        super().__init__()
        self._start_time = None

    @command(
        signature="start",
        description="Start the timer",
        example="start"
    )
    def start(self):
        self._start_time = time.time()
        return "Timer started"

    def get_state_display(self) -> str:
        return "Timer: Running" if self._start_time else "Timer: Stopped"
```

**Success criteria**: Timer environment works with automatic help generation, command routing, and usage tracking

### Scenario 4: Editor handles multi-line commands correctly

**Situation**: Agent uses `edit` and `create` commands which have multi-line content

**Commands**:
```
editor: create test.py
def foo():
    pass

def bar():
    return 42
```

**Success criteria**: Multi-line content is correctly parsed and passed to command implementation

## Plan

- [ ] Implement `@command` decorator in `orchestrator/declarative.py`
- [ ] Implement `DeclarativeEnvironment` base class with:
  - [ ] Command discovery from decorated methods
  - [ ] Per-command usage tracking
  - [ ] Progressive help screen generation
  - [ ] Command routing to appropriate method
  - [ ] Multi-line command parsing support
- [ ] Write comprehensive tests for DeclarativeEnvironment
- [ ] Refactor Editor environment to extend DeclarativeEnvironment:
  - [ ] Add `@command` decorators to all methods
  - [ ] Remove manual command parsing logic
  - [ ] Implement `get_state_display()` for views
  - [ ] Remove manual screen generation
- [ ] Update Editor tests to verify:
  - [ ] All commands still work correctly
  - [ ] Progressive help is generated
  - [ ] Multi-line commands work
- [ ] Verify all existing editor tests pass
- [ ] Run full build verification: `nix build .#orchestrator`

## Dependencies

- Requires: Understanding of Editor environment implementation
- Requires: Help system design document (docs/help-system-design.md)
- Blocks: Implement help system task

## Outcome

A working `DeclarativeEnvironment` base class that:
1. Automatically discovers commands via `@command` decorator
2. Tracks per-command usage
3. Generates progressive help screens (LONG for unused, SHORT for used)
4. Routes commands to appropriate methods
5. Supports multi-line commands (edit, create)

Editor environment successfully refactored to:
1. Extend DeclarativeEnvironment
2. Use `@command` decorators instead of manual parsing
3. Provide identical functionality as before
4. Automatically generate help screens
5. Pass all existing tests

## Notes

### DeclarativeEnvironment Design Considerations

**Command parsing flexibility**: The base class should allow subclasses to override command parsing. Editor needs custom parsing for multi-line commands, while simple environments might just need the command text.

**Solution**: Provide `_execute_command(method, cmd_text)` hook that subclasses can override.

**Environment name for examples**: The base class needs to know the environment name to wrap examples in markdown code fences (````editor`).

**Solution**: Derive from class name: `self.__class__.__name__.replace('Environment', '').lower()`

**Optional get_state_display**: Not all environments need custom state display.

**Solution**: Make `get_state_display()` optional - use class docstring as default if not implemented.

### Editor Refactor Considerations

**Multi-line commands**: `edit` and `create` take content on subsequent lines. This is non-standard command parsing.

**Solution**: Editor overrides `_execute_command()` to handle multi-line parsing, then calls the appropriate decorated method.

**View state rendering**: Current editor renders views in `get_screen()` with complex logic.

**Solution**: Move view rendering to `get_state_display()` method. Base class calls this and appends command help.

**Backward compatibility**: All command signatures and behavior must remain identical.

**Verification**: Run all existing editor tests - they should pass without modification.

## Example Decorator Usage

```python
@command(
    signature="view <file> /<start>/ /<end>/ [label]",
    description="View a section of a file using regex patterns to define boundaries.\nPatterns are Python regex. Multiple matches can be navigated with next_match/prev_match.",
    example="view src/main.py /^def main/ /^if __name__/"
)
def view(self, filepath: str, start_pattern: str, end_pattern: str, label: str = ""):
    """View command implementation"""
    # Implementation unchanged
    ...
```

The decorator stores metadata, DeclarativeEnvironment generates help automatically.
