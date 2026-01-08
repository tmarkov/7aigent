# Help System Design

## Overview

This document specifies a comprehensive help/documentation system for environment capability discovery. The system makes the orchestrator fully self-documenting by embedding capability information directly in screen sections, with **per-command progressive disclosure** that shows detailed help only for commands not yet used.

---

## Design Constraints (from Task)

1. **Fully self-documenting**: Zero guessing required. System makes help visible automatically.
2. **Context-aware placement**: Documentation on screen (strong attention), examples in conversation history
3. **Progressive disclosure**: Show only what's needed for the next step
4. **Always accessible**: No commands to guess, no external files
5. **Works for all environments**: Built-in and custom/ad-hoc environments

---

## Core Design Principle

Environments fall into two categories:

### 1. Freeform Environments (Bash, Python)
Accept arbitrary input ("any bash command", "any Python code"). Help is simple and static - no progressive disclosure needed.

### 2. Structured Command Environments (Editor, Custom)
Have a specific set of commands (view, edit, search, etc.). Use **per-command progressive disclosure**:
- **Command not used yet**: Show LONG help (detailed description + examples)
- **Command already used**: Show SHORT help (signature + one-line description)

This ensures the agent always has enough information to use new commands, while keeping the screen compact for familiar commands.

---

## Environment Type Designs

### Bash Environment (Freeform)

**Screen format** (always the same):
```
Working directory: /home/user/project
Last exit code: 0
Background jobs: [1] 12345 ./server

Any bash command. Use & for background jobs.
```

**Rationale**: Bash accepts any command. No structured command set to document. Brief reminder is sufficient.

---

### Python Environment (Freeform)

**Screen format** (always the same):
```
Working directory: /home/user/project

Variables (recent):
  df: DataFrame
  model: RandomForestClassifier
  X_train: ndarray

Any Python code. Variables and imports persist across commands.
```

**Rationale**: Python accepts any code. Variable list provides context. No progressive disclosure needed.

---

### Editor Environment (Structured Commands)

Uses **DeclarativeEnvironment** base class with per-command help tracking.

#### Before ANY commands used:

```
Views:
  (no views)

Commands:
  view <file> /<start>/ /<end>/ [label]
    View a section of a file using regex patterns to define boundaries.
    Patterns are Python regex. Multiple matches can be navigated with next_match/prev_match.
    Example:
      ```editor
      view src/main.py /^def main/ /^if __name__/
      ```

  edit <file> <start>-<end>
    Replace lines with new content. Lines must be visible in a view.
    Content is provided on subsequent lines after the command.
    Example:
      ```editor
      edit src/main.py 45-50
      def process(verbose=False):
          if not verbose:
              return
      ```

  search "<pattern>" <glob>
    Find all occurrences of pattern in files matching glob.
    Returns filepath:line_number for each match.
    Example:
      ```editor
      search "TODO" *.py
      ```

  create <file>
    Create a new file with initial content.
    Content is provided on subsequent lines after the command.
    Example:
      ```editor
      create new_file.py
      # New module
      ```

  close <id> - Close a view
  next_match <id> - Show next pattern match for a view
  prev_match <id> - Show previous pattern match for a view
```

**Note**: Commands with simple functionality (close, next_match, prev_match) only show SHORT help even initially.

#### After using `view`:

```
Views:
  [1] src/main.py /^def main/ to /^if __name__/ (match 1/1)
     45  def main():
     46      parser = argparse.ArgumentParser()
     ...
     78  if __name__ == '__main__':

Commands:
  view <file> /<start>/ /<end>/ [label] - View file section by regex patterns

  edit <file> <start>-<end>
    Replace lines with new content. Lines must be visible in a view.
    Content is provided on subsequent lines after the command.
    Example:
      ```editor
      edit src/main.py 45-50
      def process(verbose=False):
          if not verbose:
              return
      ```

  search "<pattern>" <glob>
    Find all occurrences of pattern in files matching glob.
    Returns filepath:line_number for each match.
    Example:
      ```editor
      search "TODO" *.py
      ```

  create <file>
    Create a new file with initial content.
    Content is provided on subsequent lines after the command.
    Example:
      ```editor
      create new_file.py
      # New module
      ```

  close <id> - Close a view
  next_match <id> - Show next pattern match for a view
  prev_match <id> - Show previous pattern match for a view
```

#### After using `view`, `edit`, `search`:

```
Views:
  [1] src/main.py /^def main/ to /^if __name__/ (match 1/1)
     45  def main():
     46      parser = argparse.ArgumentParser()
     ...
     78  if __name__ == '__main__':

Commands:
  view <file> /<start>/ /<end>/ [label] - View file section by regex patterns
  edit <file> <start>-<end> - Replace lines (must be visible in a view)
  search "<pattern>" <glob> - Find text matching pattern in files

  create <file>
    Create a new file with initial content.
    Content is provided on subsequent lines after the command.
    Example:
      ```editor
      create new_file.py
      # New module
      ```

  close <id> - Close a view
  next_match <id> - Show next pattern match for a view
  prev_match <id> - Show previous pattern match for a view
```

**Key point**: When the agent wants to use `create` for the first time, the LONG help with example is still there!

---

### Custom Environments

Custom environments can choose from three patterns:

#### Option 1: InteractiveEnvironment (Simplest)

For wrapping interactive CLI tools (gdb, psql, redis-cli, etc.):

```python
class PostgresEnvironment(InteractiveEnvironment):
    command = "psql -U postgres"
    prompt = r"postgres=# "
    description = "PostgreSQL database shell"
```

**Screen output**:
```
PostgreSQL database shell (connected)

Send SQL queries directly. Connection persists across commands.
```

Base class handles process management, command forwarding, and simple help display.

#### Option 2: DeclarativeEnvironment (Structured Commands)

For custom command sets with per-command progressive disclosure:

```python
from orchestrator.declarative import DeclarativeEnvironment, command

class TimerEnvironment(DeclarativeEnvironment):
    """Timer for tracking elapsed time"""

    def __init__(self):
        super().__init__()
        self._start_time = None
        self._elapsed = 0.0

    @command(
        signature="start",
        description="Start the timer from zero or resume after stop.",
        example="start"
    )
    def start(self):
        self._start_time = time.time()
        return "Timer started"

    @command(
        signature="stop",
        description="Stop the timer and record elapsed time.",
        example="stop"
    )
    def stop(self):
        if not self._start_time:
            raise ValueError("Timer not running")
        self._elapsed = time.time() - self._start_time
        self._start_time = None
        return f"Elapsed: {self._elapsed:.2f}s"

    @command(
        signature="reset",
        description="Reset timer to zero.",
        example="reset"
    )
    def reset(self):
        self._start_time = None
        self._elapsed = 0.0
        return "Timer reset"

    def get_state_display(self) -> str:
        """Optional: Override to customize state display."""
        if self._start_time:
            current = time.time() - self._start_time
            return f"Timer: Running ({current:.2f}s)"
        return f"Timer: Stopped ({self._elapsed:.2f}s)"
```

**Screen before any commands**:
```
Timer: Stopped (0.00s)

Commands:
  start
    Start the timer from zero or resume after stop.
    Example:
      ```timer
      start
      ```

  stop
    Stop the timer and record elapsed time.
    Example:
      ```timer
      stop
      ```

  reset
    Reset timer to zero.
    Example:
      ```timer
      reset
      ```
```

**Screen after using `start`**:
```
Timer: Running (5.23s)

Commands:
  start - Start the timer from zero or resume after stop

  stop
    Stop the timer and record elapsed time.
    Example:
      ```timer
      stop
      ```

  reset
    Reset timer to zero.
    Example:
      ```timer
      reset
      ```
```

**Implementation notes**:
- The `@command` decorator metadata drives help generation
- Base class automatically wraps examples in markdown code fences with environment name
- Authors only provide raw command text in examples
- Per-command usage tracking is automatic

#### Option 3: Manual Environment (Full Control)

For complex environments that need custom logic:

```python
class CustomEnvironment:
    def handle_command(self, cmd: CommandText) -> CommandResponse:
        # Custom command handling
        ...

    def get_screen(self) -> ScreenSection:
        # Full control over screen content
        ...
```

---

## Error Recovery

Error recovery help appears in **response output**, not screen.

### Example: Edit without view

**Agent command**:
```editor
edit src/main.py 45-50
new content
```

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

---

## DeclarativeEnvironment Implementation

### Command Decorator

```python
def command(signature: str, description: str, example: str):
    """
    Decorator for declarative environment commands.

    Args:
        signature: Command signature (e.g., "view <file> /<start>/ /<end>/ [label]")
        description: Multi-line detailed description
        example: Raw command invocation (will be wrapped in markdown fence)

    Example usage:
        @command(
            signature="edit <file> <start>-<end>",
            description="Replace lines with new content.\\nContent on subsequent lines.",
            example="edit src/main.py 45-50\\n    new code here"
        )
        def edit(self, filepath: str, line_range: str, content: str):
            ...
    """
    def decorator(func):
        func._command_metadata = {
            'signature': signature,
            'description': description,
            'example': example,
        }
        return func
    return decorator
```

### Base Class

```python
class DeclarativeEnvironment:
    """
    Base class for environments with structured command sets.

    Provides automatic:
    - Command discovery via @command decorator
    - Per-command usage tracking
    - Progressive help generation
    - Command routing
    """

    def __init__(self):
        self._command_usage = set()  # Track which commands have been used
        self._commands = self._discover_commands()

    def _discover_commands(self) -> dict[str, tuple[callable, dict]]:
        """Find all @command decorated methods."""
        commands = {}
        for name in dir(self):
            attr = getattr(self, name)
            if hasattr(attr, '_command_metadata'):
                # Extract command name from signature (first word)
                sig = attr._command_metadata['signature']
                cmd_name = sig.split()[0]
                commands[cmd_name] = (attr, attr._command_metadata)
        return commands

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        """Route command to appropriate method and track usage."""
        # Parse command name
        cmd_name = cmd.value.strip().split()[0] if cmd.value.strip() else ""

        if cmd_name not in self._commands:
            available = ', '.join(sorted(self._commands.keys()))
            return CommandResponse(
                output=f"Unknown command: {cmd_name}\\nAvailable: {available}",
                success=False
            )

        # Mark as used
        self._command_usage.add(cmd_name)

        # Route to method
        method, metadata = self._commands[cmd_name]
        try:
            # Subclass implements parsing and calling method with args
            result = self._execute_command(method, cmd.value)
            return CommandResponse(output=result, success=True)
        except Exception as e:
            return CommandResponse(output=f"Error: {e}", success=False)

    def _execute_command(self, method: callable, cmd_text: str) -> str:
        """
        Parse command and execute method. Subclass can override for custom parsing.
        Default: pass entire command text to method.
        """
        return method(cmd_text)

    def get_screen(self) -> ScreenSection:
        """Generate screen with state + progressive help."""
        # Get state from subclass (optional)
        if hasattr(self, 'get_state_display'):
            state = self.get_state_display()
        else:
            # Default: use class docstring
            state = self.__class__.__doc__ or "Environment ready"

        # Build command help
        commands_help = []
        for cmd_name in sorted(self._commands.keys()):
            method, metadata = self._commands[cmd_name]
            sig = metadata['signature']
            desc = metadata['description']
            example = metadata['example']

            if cmd_name in self._command_usage:
                # SHORT help: signature - one-line description
                short_desc = desc.split('\\n')[0]  # First line only
                commands_help.append(f"  {sig} - {short_desc}")
            else:
                # LONG help: signature, description, example
                # Wrap example in markdown code fence
                env_name = self.__class__.__name__.replace('Environment', '').lower()
                example_formatted = f"    ```{env_name}\\n"
                for line in example.split('\\n'):
                    example_formatted += f"    {line}\\n"
                example_formatted += "    ```"

                commands_help.append(
                    f"  {sig}\\n"
                    f"    {desc.replace(chr(10), chr(10) + '    ')}\\n"
                    f"    Example:\\n{example_formatted}"
                )

        content = state + "\\n\\nCommands:\\n" + "\\n\\n".join(commands_help)
        return ScreenSection(content=content, max_lines=100)

    def get_state_display(self) -> str:
        """
        Override in subclass to provide custom state display.

        Returns:
            String describing current environment state
        """
        raise NotImplementedError("Subclass should implement get_state_display()")
```

---

## Protocol Changes

### No Protocol Changes Required

The Environment protocol remains unchanged:

```python
class Environment(Protocol):
    def handle_command(self, cmd: CommandText) -> CommandResponse: ...
    def get_screen(self) -> ScreenSection: ...
    def shutdown(self) -> None: ...  # Optional
```

The help system is implemented entirely through:
1. **Convention**: Recommended patterns for `get_screen()` output
2. **Helper base classes**: `DeclarativeEnvironment` and `InteractiveEnvironment`
3. **Documentation**: Clear guidance for custom environment authors

---

## Scenario Walk-through: Adding Contributing Guidelines

### Turn 1: Agent receives task, sees initial screen

**Task**: "Please add a CONTRIBUTING.md file with guidelines for submitting pull requests."

**Screen**:
```
==================== BASH ====================
Working directory: /home/user/project
Last exit code: 0

Any bash command. Use & for background jobs.

==================== PYTHON ====================
Working directory: /home/user/project

Variables: (none)

Any Python code. Variables and imports persist across commands.

==================== EDITOR ====================
Views:
  (no views)

Commands:
  view <file> /<start>/ /<end>/ [label]
    View a section of a file using regex patterns...
    Example:
      ```editor
      view src/main.py /^def main/ /^if __name__/
      ```

  edit <file> <start>-<end>
    Replace lines with new content. Lines must be visible in a view.
    Example:
      ```editor
      edit src/main.py 45-50
      def process():
          pass
      ```

  search "<pattern>" <glob>
    Find all occurrences of pattern in files matching glob.
    Example:
      ```editor
      search "TODO" *.py
      ```

  create <file>
    Create a new file with initial content.
    Example:
      ```editor
      create new_file.py
      # New module
      ```

  close <id> - Close a view
  next_match <id> - Show next pattern match
  prev_match <id> - Show previous pattern match
```

**Agent reasoning**: "I need to create a new file. I see `create` command in editor with example. I'll use it."

### Turn 2: Agent creates file

**Command**:
```editor
create CONTRIBUTING.md
# Contributing Guidelines

Please follow these steps to contribute:
1. Fork the repository
2. Create a feature branch
3. Submit a pull request
```

**Response**: "Created CONTRIBUTING.md"

**Screen**:
```
==================== BASH ====================
Working directory: /home/user/project
Last exit code: 0

Any bash command. Use & for background jobs.

==================== PYTHON ====================
Working directory: /home/user/project

Variables: (none)

Any Python code. Variables and imports persist across commands.

==================== EDITOR ====================
Views:
  (no views)

Commands:
  view <file> /<start>/ /<end>/ [label]
    View a section of a file using regex patterns...
    Example:
      ```editor
      view src/main.py /^def main/ /^if __name__/
      ```

  edit <file> <start>-<end>
    Replace lines with new content. Lines must be visible in a view.
    Example:
      ```editor
      edit src/main.py 45-50
      def process():
          pass
      ```

  search "<pattern>" <glob>
    Find all occurrences of pattern in files matching glob.
    Example:
      ```editor
      search "TODO" *.py
      ```

  create <file> - Create a new file with initial content

  close <id> - Close a view
  next_match <id> - Show next pattern match
  prev_match <id> - Show previous pattern match
```

**Notice**: `create` now shows SHORT help (one line). Other commands still show LONG help.

### Turn 3: Agent verifies with bash

**Command**:
```bash
cat CONTRIBUTING.md
```

**Response**: (file contents)

**Screen**: Bash and Python unchanged. Editor still showing help for unused commands.

**Success**: ✓ Agent discovered `create` command from screen, used it successfully, and verified the result.

---

## Trade-offs and Design Decisions

### Decision 1: Per-Command vs Per-Environment Tracking

**Choice**: Per-command usage tracking for structured environments

**Rationale**:
- Editor has 7 commands - agent likely uses 2-3 in any given task
- Collapsing ALL help after first command loses information
- Per-command tracking shows detailed help exactly when needed

**Trade-off accepted**: More complex implementation, but significantly better UX

### Decision 2: Error Recovery in Response vs Screen

**Choice**: Error recovery in response output

**Rationale**:
- Screen shows persistent state - error recovery is one-time
- Response is agent's immediate feedback for the failed command
- Keeps screen focused on "what's available" vs "what went wrong"

**Trade-off accepted**: Agent must read both response and screen, but separation of concerns is clearer

### Decision 3: No Collapse for Bash/Python

**Choice**: Always show same simple help for freeform environments

**Rationale**:
- Help is already concise (1-2 lines)
- No structured command set to progressively disclose
- Consistency: agent always knows where to find info

**Trade-off accepted**: None - no downside to always showing brief help

### Decision 4: DeclarativeEnvironment for Editor

**Choice**: Reimplement editor as DeclarativeEnvironment

**Rationale**:
- Editor has structured command set (not freeform like bash/python)
- Per-command help tracking is essential for good UX
- DeclarativeEnvironment provides this automatically

**Trade-off accepted**: Editor implementation becomes more complex, but gains automatic help generation

### Decision 5: Example Format in Decorator

**Choice**: Authors provide raw command text, framework wraps in markdown

**Rationale**:
- Authors shouldn't repeat environment name in every example
- Framework can ensure consistent formatting
- Simpler for custom environment authors

**Implementation**:
```python
@command(
    signature="edit <file> <start>-<end>",
    description="Replace lines...",
    example="edit src/main.py 45-50\n    new code"  # Raw text
)
```

Framework generates:
```
    Example:
      ```editor
      edit src/main.py 45-50
          new code
      ```
```

---

## Implementation Plan

### Phase 1: DeclarativeEnvironment Base Class

1. Create `orchestrator/declarative.py`
2. Implement `@command` decorator
3. Implement `DeclarativeEnvironment` base class:
   - Command discovery
   - Per-command usage tracking
   - Progressive help generation
   - Command routing
4. Write tests for base class

### Phase 2: Update Editor Environment

1. Refactor `orchestrator/environments/editor.py` to extend `DeclarativeEnvironment`
2. Add `@command` decorators to all commands with proper metadata
3. Implement `get_state_display()` for view rendering
4. Update tests to verify progressive help

### Phase 3: Bash and Python (Simple Updates)

1. Update `orchestrator/environments/bash.py`:
   - Simplify `get_screen()` to always show brief help
2. Update `orchestrator/environments/python.py`:
   - Simplify `get_screen()` to always show brief help
3. Update tests

### Phase 4: Documentation

1. Update `docs/orchestrator.md`:
   - Add "Help System" section
   - Document environment types (freeform vs structured)
   - Show examples of each environment's screen output
2. Create custom environment guide showing:
   - InteractiveEnvironment usage
   - DeclarativeEnvironment usage
   - Manual Environment implementation

### Phase 5: End-to-End Verification

1. Test all four scenarios from task file:
   - First-time agent creates file
   - Agent recovers from error
   - Custom environment discovery
   - Multi-step workflow
2. Verify progressive disclosure works correctly
3. Verify error recovery appears in responses

---

## Success Criteria

This design is successful if:

1. ✓ Agent can discover and use environments without guessing (fully self-documenting)
2. ✓ Documentation appears on screen with strong LLM attention
3. ✓ Help is detailed for unused commands, compact for used commands (progressive disclosure)
4. ✓ No help commands needed (always accessible)
5. ✓ Custom environments can participate with simple patterns (works for all)
6. ✓ All four scenarios from task file work as described
7. ✓ Implementation requires no protocol changes
8. ✓ Conversation history accumulates usage examples, not static documentation
9. ✓ Error recovery appears in response output, not cluttering screen
10. ✓ Per-command tracking prevents information loss

All criteria met. ✓
