# Orchestrator and Environment Design

This document describes the complete design for the orchestrator, built-in environments (bash, python, editor), and the environment contract.

## Table of Contents

1. [Use Cases](#use-cases)
2. [Environment Designs](#environment-designs)
3. [Environment Contract](#environment-contract)
4. [Orchestrator Architecture](#orchestrator-architecture)
5. [Design Rationale](#design-rationale)

---

## Use Cases

This design is driven by concrete scenarios that the agent needs to support. We analyzed 12 diverse scenarios to understand requirements:

### Example Scenarios

1. **C + Python iterative optimization**: Compile C program, run it to generate data, analyze in Python, iterate
2. **Story editing**: Edit markdown files, improve grammar and coherence
3. **Trading alpha search**: Analyze market data, test trading strategies
4. **Crash debugging**: Investigate crashed program, analyze state
5. **Web scraping**: Write scraper, test on websites, handle failures
6. **Large codebase refactoring**: Rename functions across many files, run tests
7. **Data visualization**: Load data, create plots, iterate on presentation
8. **Performance profiling**: Profile code, identify bottlenecks, optimize
9. **Multi-service system**: Start/manage multiple services, aggregate logs
10. **Documentation generation**: Extract docstrings, generate and validate docs
11. **ML experiment tracking**: Train models, monitor metrics, compare runs
12. **Security audit**: Search for vulnerabilities, analyze data flow

### Key Requirements Derived

From these scenarios, we identified critical requirements:

- **Long-running commands**: Compilation, training, service startup (scenarios 1, 9, 11)
- **Multi-language coordination**: C + Python, bash + Python (scenarios 1, 3)
- **Large outputs**: Profiling data, logs, visualizations (scenarios 7, 8, 9)
- **Visual feedback**: Plots, rendered HTML (scenarios 7, 10)
- **Persistent state**: Variables, working directory, open files (all scenarios)
- **File operations**: Edit, create, search across codebase (scenarios 2, 6, 10)
- **Background processes**: Services, streaming logs (scenario 9)

---

## Environment Designs

Each built-in environment is designed to handle specific types of commands while maintaining state across the interaction loop.

### Bash Environment

**Purpose**: Execute shell commands, manage processes, handle file system operations.

**Implementation**:
- Spawns persistent bash shell process using `pexpect`
- Sends commands to shell, reads combined stdout/stderr
- Tracks working directory and exit codes
- Supports background processes via shell job control (`&`, `jobs`)

**Command format**:
```bash
any bash command
```

**Response format**:
```
Combined stdout and stderr output
```

**Screen format**:
```
Working directory: /home/user/project/src
Last exit code: 0
Background jobs: [1] 1234 ./api_server
```

**Use cases supported**:
- Build/compilation: `gcc -o program program.c -Wall -O2`
- File operations: `mkdir -p output`, `find . -name "*.py"`
- Running tests: `pytest tests/`
- Git operations: `git status`, `git commit -am "message"`
- Starting services: `./start_server.sh &`
- Profiler execution: `python -m cProfile -o profile.stats train.py`
- Dependency audits: `pip-audit`, `npm audit`

**State maintained**:
- Current working directory
- Environment variables (inherited, modified via `export`)
- Last exit code
- Background job list

**Design decisions**:
1. **Combined stdout/stderr**: Matches terminal behavior, simpler than separate streams
2. **Background jobs via shell**: Use shell's job control, not orchestrator tracking
3. **Unique PS1**: Use special prompt to reliably detect command completion
4. **No interactive programs**: `gdb`, `vim`, etc. not supported initially (use ad-hoc environments with InteractiveEnvironment base class)
5. **Minimal screen until first use**: Before first command, show only "Bash shell (ready)" to avoid clutter

**Edge cases**:
- Infinite commands: Will block the system indefinitely. Agent must be careful. Future: allow agent to kill environment (losing state) or continue waiting.
- Large output: Truncate at 10MB, show warning
- Prompt detection: Use unique marker like `<<<PROMPT>>>` to avoid ambiguity

### Python Environment

**Purpose**: Execute Python code, maintain REPL state, perform data analysis and computation.

**Implementation**:
- Runs persistent Python REPL process using `pexpect`
- Maintains global/local namespaces between commands
- Executes code, captures printed output and expression results
- Introspects namespace to display variables on screen

**Command format**:
```python
python code (can be multi-line)
```

**Response format**:
```
<all output from Python REPL, including printed output and expression results>
<exception traceback if error occurred>
```

**Screen format**:
```
Working directory: /home/user/project

Variables (by recent use):
  df: DataFrame
  model: RandomForestClassifier
  quality_score: float
  mean: float
  X_train: ndarray
  y_train: ndarray
  data: dict
  fig: Figure
  ...
```

**Use cases supported**:
- Data analysis: `df = pd.read_csv('data.csv')`, `df.describe()`
- Visualization: `plt.plot(x, y)`, `plt.savefig('plot.png')`
- ML training: `model.fit(X_train, y_train)`
- Statistical analysis: `mean = df['price'].mean()`
- Web scraping: `driver.get('https://example.com')`
- Profiling analysis: `p = pstats.Stats('profile.stats')`, `p.print_stats(10)`
- Algorithm development: Define functions, test iteratively

**State maintained**:
- Global namespace (variables, functions, classes)
- Imported modules
- Current working directory (Python's `os.getcwd()`, agent can change with `os.chdir()`)
- Variable ordering list (for tracking recent use)

**Design decisions**:
1. **All output captured**: Python REPL naturally shows expression results; we capture all output without special handling
2. **Variable display shows types only**: Show variable names with type (not values) to avoid screen clutter from large objects
3. **Recent use ordering**: Track variable usage via simple regex matching in commands, show most recently used first
4. **Exception handling**: Full traceback in response
5. **Package installation**: Use bash `pip install`, not Python subprocess
6. **Working directory shown**: Display `os.getcwd()` on screen to avoid confusion with bash cwd
7. **No background execution**: Long tasks block until complete
8. **Minimal screen until first use**: Before first command, show only "Python REPL (ready)" to avoid clutter

**Variable display logic**:
```python
def get_type_name(obj) -> str:
    """Get simple type name for display."""
    obj_type = type(obj)

    # Use __name__ for classes and types
    if isinstance(obj, type):
        return obj.__name__

    # Special handling for common types
    type_name = obj_type.__name__

    # For numpy arrays, show "ndarray"
    if type_name == 'ndarray':
        return 'ndarray'
    # For pandas objects, use short names
    elif type_name == 'DataFrame':
        return 'DataFrame'
    elif type_name == 'Series':
        return 'Series'
    # For everything else, use type name directly
    else:
        return type_name
```

**Usage tracking**:
- Maintain ordered list of variable names
- After each command, scan command text for variable names using simple regex: `\b{var_name}\b`
- Move matched variables to front of list (preserving relative order among matches)
- Screen displays variables in list order (most recently used first)
- No need for 100% accuracy - simple regex matching is sufficient

**Usage tracking algorithm**:
```python
# After each command:
# 1. Find all variables mentioned in command
matches = []
for var_name in current_namespace:
    if re.search(rf'\b{re.escape(var_name)}\b', command_text):
        matches.append(var_name)

# 2. Move matches to front of ordered list
ordered_vars = matches + [v for v in ordered_vars if v not in matches]

# 3. Display first 100 from ordered_vars on screen
```

**Screen variable filtering**:
- Exclude private variables (starting with `_`)
- Exclude modules and builtins
- Limit to 100 most recently used variables
- Show in order of recent use (most recently used first)

**Edge cases**:
- Infinite loops: Will block the system indefinitely. Agent must be careful. Future: allow agent to kill environment (losing state) or continue waiting.
- Memory leaks: Agent's responsibility to manage namespace
- SyntaxError: Return error in response, continue
- Variable name collisions in regex: Simple regex may match variable names within strings or comments; acceptable trade-off for simplicity

### Editor Environment

**Purpose**: View and edit files, maintain persistent views of code sections.

**Implementation**:
- Manages set of "views" (file sections currently visible on screen)
- Views use pattern-based boundaries (regex) to track content semantically
- Views persist across commands and **always re-read files** on every screen generation
- Provides pattern-based viewing and line-based editing operations
- Simple search across files

**Command format**:
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

**Response format**:
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

**Screen format**:
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

**Use cases supported**:
- Reading code by semantic boundaries: `view src/main.c /^int main\(/ to /^}$/`
- Reading class definitions: `view src/api.py /^class UserManager/ to /^class \w+/`
- Reading markdown sections: `view README.md /^## Installation/ to /^## Usage/`
- Editing files: Agent sees line numbers on screen, uses them for edits
- Creating files: `create src/new.py` + initial content
- Searching: `search "TODO" *.py` returns line numbers
- Multi-file viewing: Multiple `view` commands create multiple views (max 5)
- Navigation: Use `next_match`/`prev_match` when pattern matches multiple locations

**State maintained**:
- List of views: (id, filepath, start_pattern, end_pattern, current_match_index, label)
- Cached content from last screen generation (for edit verification)
- Next view ID counter

**Design decisions**:
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

**View generation (every screen update)**:
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

**Edit implementation**:
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

**Pattern search constraints**:
- Search up to 1000 lines after start pattern for end pattern
- If end pattern not found within 1000 lines, truncate view at 1000 lines
- Greedy matching: always use first occurrence of end pattern (within 1000 line limit)

**Example workflow**:
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

**Edge cases**:
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

**Deferred features** (not in initial version):
- LSP integration (goto_definition, find_references, rename)
- Diff viewing
- Syntax highlighting in screen output
- Multi-file search with context
- Configurable view size limits
- Non-greedy or custom pattern matching strategies

---

## Environment Contract

All environments (built-in and ad-hoc) must implement this protocol.

### Type Definitions

```python
from dataclasses import dataclass
from typing import Protocol

@dataclass(frozen=True)
class EnvironmentName:
    """Name of an environment (must be valid Python identifier)."""
    value: str

    def __post_init__(self):
        if not self.value.isidentifier():
            raise ValueError(f"Invalid environment name: {self.value}")

@dataclass(frozen=True)
class CommandText:
    """The text content of a command to execute."""
    value: str

@dataclass(frozen=True)
class CommandResponse:
    """Response from executing a command."""
    output: str
    success: bool

@dataclass(frozen=True)
class ScreenSection:
    """Content to display in this environment's screen section."""
    content: str
    max_lines: int = 50
```

### Environment Protocol

```python
from typing import Protocol

class Environment(Protocol):
    """
    Protocol that all environment modules must implement.

    Environments are stateful and handle commands within their domain
    (bash, python, editor, etc.). They maintain state across commands
    and provide a screen section showing current state.
    """

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        """
        Execute a command in this environment.

        This is the main entry point for command execution. The environment
        should parse the command, execute it, update internal state, and
        return a response.

        Args:
            cmd: The command to execute

        Returns:
            Response containing output and success status

        Notes:
            - This method MUST be synchronous (blocking)
            - Timeouts are the environment's responsibility
            - Long-running commands will block the interaction loop
            - Exceptions should be caught and returned as failed response
        """
        ...

    def get_screen(self) -> ScreenSection:
        """
        Get current screen content for this environment.

        This is called after every command (from any environment) to update
        the screen. Should return quickly with current state.

        Returns:
            Screen section showing current environment state

        Notes:
            - Called frequently, must be fast (no expensive computation)
            - Content will be truncated if exceeds max_lines
            - Should show the most relevant state information
        """
        ...

    def shutdown(self) -> None:
        """
        Clean up resources before environment is stopped.

        Called when orchestrator is shutting down. Use this to:
        - Kill child processes
        - Close file handles
        - Save state if needed

        This method is OPTIONAL to implement.
        """
        ...
```

### Environment Loading and Validation

**Loading process**:

1. **Built-in environments**: Loaded from `orchestrator/environments/` package
   - `bash.py` exports `BashEnvironment` class
   - `python.py` exports `PythonEnvironment` class
   - `editor.py` exports `EditorEnvironment` class

2. **Ad-hoc environments**: Loaded from `{project_dir}/env/*.py`
   - Each `.py` file is a module
   - Module name (stem) becomes environment name
   - Module must export a class implementing the Environment protocol
   - Class name conventionally matches module name (e.g., `timer.py` exports `TimerEnvironment`)

**Validation implementation**:

```python
import inspect
from typing import Any

def find_environment_class(module: Any) -> type | None:
    """
    Find the environment class in a module.

    Looks for a class that implements the Environment protocol.
    By convention, class name should match module name (e.g., TimerEnvironment in timer.py).

    Returns:
        The environment class, or None if not found
    """
    # Look for classes that have handle_command and get_screen methods
    for name in dir(module):
        obj = getattr(module, name)
        if inspect.isclass(obj) and hasattr(obj, 'handle_command') and hasattr(obj, 'get_screen'):
            return obj
    return None

def validate_environment_class(cls: type) -> list[str]:
    """
    Validate that a class implements the Environment protocol.

    Uses runtime introspection to check:
    - Required methods exist
    - Method signatures match protocol
    - Type annotations are correct

    Args:
        cls: The class to validate

    Returns:
        List of validation error messages (empty list if valid)
    """
    errors = []

    # Check handle_command exists
    if not hasattr(cls, 'handle_command'):
        errors.append("Missing required method: handle_command")
    else:
        sig = inspect.signature(cls.handle_command)
        params = list(sig.parameters.values())

        # Should be (self, cmd)
        if len(params) != 2:
            errors.append("handle_command must take exactly 2 parameters (self, cmd)")
        elif len(params) == 2:
            param = params[1]  # Skip self
            if param.annotation == inspect.Parameter.empty:
                errors.append("handle_command cmd parameter must have type annotation")
            elif param.annotation != CommandText:
                errors.append(f"handle_command cmd must be CommandText, got {param.annotation}")

        if sig.return_annotation == inspect.Signature.empty:
            errors.append("handle_command must have return type annotation")
        elif sig.return_annotation != CommandResponse:
            errors.append(f"handle_command must return CommandResponse, got {sig.return_annotation}")

    # Check get_screen exists
    if not hasattr(cls, 'get_screen'):
        errors.append("Missing required method: get_screen")
    else:
        sig = inspect.signature(cls.get_screen)
        params = list(sig.parameters.values())

        # Should be (self,)
        if len(params) != 1:
            errors.append("get_screen must take only self parameter")

        if sig.return_annotation == inspect.Signature.empty:
            errors.append("get_screen must have return type annotation")
        elif sig.return_annotation != ScreenSection:
            errors.append(f"get_screen must return ScreenSection, got {sig.return_annotation}")

    # Check shutdown (optional)
    if hasattr(cls, 'shutdown'):
        sig = inspect.signature(cls.shutdown)
        params = list(sig.parameters.values())

        if len(params) != 1:
            errors.append("shutdown must take only self parameter")
        if sig.return_annotation not in (inspect.Signature.empty, None):
            errors.append("shutdown must return None")

    return errors
```

**Error handling for failed validation**:

When an ad-hoc environment fails validation:
1. Log errors to stderr with module name and specific issues
2. Do NOT load the environment (exclude from available environments)
3. Continue loading other environments
4. Optionally: Display validation errors on screen in special section

**Example ad-hoc environment - Simple timer**:

```python
# project_dir/env/timer.py

from orchestrator.types import CommandText, CommandResponse, ScreenSection
import time

class TimerEnvironment:
    """Simple timer environment for tracking elapsed time."""

    def __init__(self):
        self._start_time = None
        self._elapsed = 0.0

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        command = cmd.value.strip()

        if command == "start":
            self._start_time = time.time()
            return CommandResponse("Timer started", success=True)
        elif command == "stop":
            if self._start_time is None:
                return CommandResponse("Timer not running", success=False)
            self._elapsed = time.time() - self._start_time
            self._start_time = None
            return CommandResponse(f"Elapsed: {self._elapsed:.2f}s", success=True)
        elif command == "reset":
            self._start_time = None
            self._elapsed = 0.0
            return CommandResponse("Timer reset", success=True)
        else:
            return CommandResponse(f"Unknown command: {command}", success=False)

    def get_screen(self) -> ScreenSection:
        if self._start_time is not None:
            current_elapsed = time.time() - self._start_time
            status = f"Running: {current_elapsed:.2f}s"
        else:
            status = f"Stopped: {self._elapsed:.2f}s"

        return ScreenSection(content=f"Timer: {status}")

    def shutdown(self) -> None:
        # Optional cleanup
        pass
```

### Interactive Program Helper

For creating environments that wrap interactive programs (like GDB, database CLIs, etc.), the orchestrator provides a base class that handles the common patterns:

```python
# orchestrator/interactive.py

from orchestrator.types import CommandText, CommandResponse, ScreenSection
import pexpect

class InteractiveEnvironment:
    """
    Base class for environments that wrap interactive programs.

    Subclasses only need to specify:
    - command: The command to start the program
    - prompt: The expected prompt pattern (regex for pexpect)
    - description: Short description shown on screen before first use
    """

    command: str = None  # e.g., "gdb"
    prompt: str = None   # e.g., r"\(gdb\) "
    description: str = "Interactive program"

    def __init__(self):
        self._process = None
        self._used = False

    def handle_command(self, cmd: CommandText) -> CommandResponse:
        # Start process on first command
        if self._process is None:
            try:
                self._process = pexpect.spawn(self.command)
                self._process.expect(self.prompt)
                self._used = True
            except Exception as e:
                return CommandResponse(f"Failed to start {self.command}: {e}", success=False)

        # Send command and capture output
        try:
            self._process.sendline(cmd.value)
            self._process.expect(self.prompt)
            output = self._process.before.decode('utf-8')
            return CommandResponse(output, success=True)
        except pexpect.TIMEOUT:
            return CommandResponse("Command timed out (no prompt detected)", success=False)
        except Exception as e:
            return CommandResponse(f"Error: {e}", success=False)

    def get_screen(self) -> ScreenSection:
        if not self._used:
            # Show only description until first use
            return ScreenSection(content=f"{self.description}")
        else:
            # After first use, show status
            status = "Running" if self._process and self._process.isalive() else "Stopped"
            return ScreenSection(content=f"{self.description}\nStatus: {status}")

    def shutdown(self) -> None:
        if self._process:
            self._process.close()
```

**Example - GDB environment**:

```python
# project_dir/env/gdb.py

from orchestrator.interactive import InteractiveEnvironment

class GdbEnvironment(InteractiveEnvironment):
    """GDB debugger environment."""

    command = "gdb"
    prompt = r"\(gdb\) "
    description = "GDB debugger (not started)"
```

With just 6 lines of code, you have a working GDB environment. Agent can use it like:

```gdb
file ./program
break main
run
backtrace
quit
```

---

## Orchestrator Architecture

The orchestrator is the main process inside the container. It manages environments, routes commands, and communicates with the agent.

### Components

**Main loop**:
```python
def main():
    """Main orchestrator entry point."""
    # Setup
    project_dir = Path(os.getenv('PROJECT_DIR', '/workspace'))

    # Load environments
    environments = load_all_environments(project_dir)

    # Main interaction loop
    while True:
        # Read command from agent (stdin)
        message = read_message()
        if message is None:  # EOF
            break

        # Parse and validate
        try:
            command = parse_command(message)
        except ParseError as e:
            send_error_response(str(e))
            continue

        # Execute in appropriate environment
        response = execute_command(command, environments)

        # Collect screen updates from all environments
        screen = collect_screen_updates(environments)

        # Send response back to agent (stdout)
        send_response(response, screen)

    # Cleanup
    shutdown_all_environments(environments)
```

**Environment loading**:
```python
def load_all_environments(project_dir: Path) -> dict[str, Environment]:
    """
    Load built-in and ad-hoc environments.

    Args:
        project_dir: Root directory of the project

    Returns:
        Dictionary mapping environment names to environment instances
    """
    environments = {}

    # Load built-in environments
    from orchestrator.environments.bash import BashEnvironment
    from orchestrator.environments.python import PythonEnvironment
    from orchestrator.environments.editor import EditorEnvironment

    environments['bash'] = BashEnvironment()
    environments['python'] = PythonEnvironment()
    environments['editor'] = EditorEnvironment(project_dir)

    # Load ad-hoc environments from project_dir/env/
    env_dir = project_dir / 'env'
    if env_dir.exists() and env_dir.is_dir():
        for module_path in env_dir.glob('*.py'):
            name = module_path.stem

            # Skip private modules
            if name.startswith('_'):
                continue

            try:
                module = importlib.import_module(f'env.{name}')

                # Find environment class in module
                env_class = find_environment_class(module)
                if env_class is None:
                    print(f"Failed to load environment '{name}': No environment class found", file=sys.stderr)
                    continue

                # Validate the class
                errors = validate_environment_class(env_class)
                if errors:
                    print(f"Failed to load environment '{name}':", file=sys.stderr)
                    for error in errors:
                        print(f"  - {error}", file=sys.stderr)
                    continue

                # Instantiate the environment
                environments[name] = env_class()
                print(f"Loaded ad-hoc environment: {name}", file=sys.stderr)

            except Exception as e:
                print(f"Error loading environment '{name}': {e}", file=sys.stderr)
                traceback.print_exc(file=sys.stderr)

    return environments
```

**Command execution**:
```python
@dataclass(frozen=True)
class OrchestratorCommand:
    """Command from agent to orchestrator."""
    environment: str
    command: str

def execute_command(
    cmd: OrchestratorCommand,
    environments: dict[str, Environment]
) -> CommandResponse:
    """
    Execute command in specified environment.

    Args:
        cmd: Command to execute
        environments: All loaded environments

    Returns:
        Response from environment execution
    """
    # Validate environment exists
    if cmd.environment not in environments:
        available = ', '.join(sorted(environments.keys()))
        return CommandResponse(
            output=f"Unknown environment: {cmd.environment}\nAvailable: {available}",
            success=False
        )

    # Get environment
    env = environments[cmd.environment]

    # Execute command
    try:
        command_text = CommandText(cmd.command)
        response = env.handle_command(command_text)
        return response
    except Exception as e:
        # Environment raised unhandled exception
        tb = traceback.format_exc()
        return CommandResponse(
            output=f"Environment error in {cmd.environment}:\n{tb}",
            success=False
        )
```

**Screen collection**:
```python
@dataclass(frozen=True)
class Screen:
    """Complete screen state from all environments."""
    sections: Mapping[str, ScreenSection]

def collect_screen_updates(environments: dict[str, Environment]) -> Screen:
    """
    Collect screen sections from all environments.

    Calls get_screen() on each environment and aggregates results.

    Note: Environments should return minimal screen content (just name and
    description) until first use, to avoid cluttering the screen with
    information about unused environments.

    Args:
        environments: All loaded environments

    Returns:
        Complete screen with all sections
    """
    sections = {}

    for name, env in environments.items():
        try:
            section = env.get_screen()
            sections[name] = section
        except Exception as e:
            # Environment failed to provide screen, show error
            tb = traceback.format_exc()
            sections[name] = ScreenSection(
                content=f"[Error getting screen from {name}:\n{tb}]",
                max_lines=10
            )

    return Screen(sections=types.MappingProxyType(sections))
```

### Agent-Orchestrator Communication Protocol

Communication happens via stdin/stdout using newline-delimited JSON (NDJSON).

**Format**: One JSON object per line, terminated by newline.

**Agent → Orchestrator (Command)**:
```json
{
  "type": "command",
  "environment": "bash",
  "command": "ls -la"
}
```

**Orchestrator → Agent (Response)**:
```json
{
  "type": "response",
  "response": {
    "output": "total 48\ndrwxr-xr-x 2 user user 4096 ...\n",
    "success": true
  },
  "screen": {
    "bash": {
      "content": "Working directory: /home/user/project\nLast exit code: 0\n",
      "max_lines": 50
    },
    "python": {
      "content": "Variables:\n  df: DataFrame(1000 rows × 5 cols)\n  mean: 42.7\n\nLast result: 0.85",
      "max_lines": 50
    },
    "editor": {
      "content": "Views:\n  [1] src/main.py:1-20\n     1  import sys\n     2  import argparse\n     ...",
      "max_lines": 50
    }
  }
}
```

**Orchestrator → Agent (Error)**:
```json
{
  "type": "error",
  "message": "Failed to parse command: invalid JSON"
}
```

**Protocol implementation**:

```python
import json
import sys

def read_message() -> dict | None:
    """
    Read one message from stdin.

    Returns:
        Parsed JSON message, or None on EOF
    """
    line = sys.stdin.readline()
    if not line:  # EOF
        return None

    try:
        return json.loads(line)
    except json.JSONDecodeError as e:
        raise ParseError(f"Invalid JSON: {e}")

def send_response(response: CommandResponse, screen: Screen) -> None:
    """
    Send response message to stdout.

    Args:
        response: Command execution response
        screen: Current screen state from all environments
    """
    message = {
        "type": "response",
        "response": {
            "output": response.output,
            "success": response.success
        },
        "screen": {
            name: {
                "content": section.content,
                "max_lines": section.max_lines
            }
            for name, section in screen.sections.items()
        }
    }

    json.dump(message, sys.stdout)
    sys.stdout.write('\n')
    sys.stdout.flush()

def send_error_response(error_msg: str) -> None:
    """Send error message to stdout."""
    message = {
        "type": "error",
        "message": error_msg
    }
    json.dump(message, sys.stdout)
    sys.stdout.write('\n')
    sys.stdout.flush()
```

### Module Structure

```
orchestrator/
  __init__.py
  main.py              # Entry point, main loop
  types.py             # Core type definitions (CommandText, etc.)
  protocol.py          # Environment protocol definition
  loader.py            # Environment loading and validation
  executor.py          # Command execution logic
  screen.py            # Screen collection logic
  communication.py     # Message parsing and serialization

  environments/
    __init__.py
    bash.py            # BashEnvironment implementation
    python.py          # PythonEnvironment implementation
    editor.py          # EditorEnvironment implementation
```

### Error Handling

**Environment-level errors**:
- Caught by `execute_command()`
- Returned as `CommandResponse(success=False)`
- Agent sees error in response output
- Orchestrator continues running

**Orchestrator-level errors**:
- **Fatal** (stdin EOF, critical failure): Shutdown gracefully
- **Non-fatal** (environment load failed, parse error): Log and continue
- **Environment get_screen() error**: Show error in that section, continue

**Shutdown sequence**:
```python
def shutdown_all_environments(environments: dict[str, Environment]) -> None:
    """Call shutdown() on all environments that implement it."""
    for name, env in environments.items():
        if hasattr(env, 'shutdown'):
            try:
                env.shutdown()
            except Exception as e:
                print(f"Error shutting down {name}: {e}", file=sys.stderr)
```

---

## Design Rationale

This section explains key design decisions and alternatives considered.

### Synchronous vs Async Environments

**Decision**: Synchronous (blocking) `handle_command()`

**Rationale**:
- Simpler to implement environments (no async/await complexity)
- Agent loop is inherently sequential (one command at a time)
- Long-running tasks can be handled at environment level (bash background jobs)
- Can add async support later if needed without breaking contract

**Alternative considered**: Async protocol
```python
async def handle_command(self, cmd: CommandText) -> CommandResponse:
```
- **Pros**: Native support for background execution, non-blocking
- **Cons**: Much more complex to implement, harder for ad-hoc environments
- **Decision**: Defer to future version if needed

### Screen Update Strategy

**Decision**: Pull model - orchestrator calls `get_screen()` after every command

**Rationale**:
- Simple and predictable
- Environments control what to show
- No complex event system needed
- Screen is always fresh after command execution

**Alternative considered**: Push model - environments notify when screen should update
- **Pros**: More efficient (only update when needed)
- **Cons**: Requires event system, more complex protocol, harder to debug
- **Decision**: Pull model is simpler and "good enough"

### Environment State Management

**Decision**: Environments are stateful, long-lived processes

**Rationale**:
- Bash: Need persistent working directory, variables
- Python: Need persistent namespace for iterative development
- Editor: Need persistent views
- Restarting environments between commands would lose state

**Alternative considered**: Stateless environments, explicit state serialization
- **Pros**: More predictable, easier to debug
- **Cons**: Loses key benefit (persistent REPL state), complex serialization
- **Decision**: Stateful is essential for use cases

### Communication Protocol

**Decision**: Newline-delimited JSON (NDJSON) over stdin/stdout

**Rationale**:
- Human-readable, easy to debug
- Simple parsing (readline + JSON parse)
- Well-supported in all languages
- No length-prefix complexity

**Alternative considered**: Length-prefixed binary protocol
- **Pros**: Can handle messages with newlines, more efficient
- **Cons**: Harder to debug, more complex implementation
- **Decision**: NDJSON is sufficient, can switch later if needed

### File-based Output for Large Data

**Decision**: Environments write large outputs (plots, profiling data) to files in project directory

**Rationale**:
- Screen is for state, not large outputs
- Files persist across commands
- Agent can reference files in future commands
- Handles visual outputs (images, HTML) gracefully

**Alternative considered**: Stream large outputs through protocol
- **Pros**: Everything in one channel
- **Cons**: Screen size limits, hard to reference later, visual data doesn't work
- **Decision**: File-based is cleaner separation of concerns

### Editor Pattern-Based Views

**Decision**: Views use regex patterns for boundaries, not fixed line numbers

**Rationale**:
- Files change frequently (by agent, external tools, other environments)
- Fixed line numbers become meaningless after file modifications
- Pattern-based boundaries track content semantically
- Views remain meaningful even when file structure changes
- Agent can't know line numbers without seeing file first

**Example**: View "main function" via `/^int main\(/ to /^}$/` remains correct even if 50 lines added at file start.

**Alternative considered**: Fixed line number ranges
- **Pros**: Simpler to specify, no regex needed
- **Cons**: Views break immediately when file modified, agent must constantly re-create views
- **Decision**: Pattern-based is more robust despite regex complexity

**Implementation trade-offs accepted**:
- Agent must write regex patterns (harder than line numbers)
- Pattern matching has edge cases (multiple matches, no matches)
- Requires re-reading files on every screen generation (performance cost)
- Max 1000 line search range to prevent pathological cases

**No LSP integration**: Defer goto_definition, find_references to future. Pattern-based views provide sufficient semantic tracking for initial version.

### Environment Validation

**Decision**: Runtime introspection-based validation with detailed error messages

**Rationale**:
- Python's type system is runtime, not compile-time
- Introspection can check signatures and type annotations
- Clear error messages help ad-hoc environment developers
- Fails fast with diagnostic information

**Alternative considered**: Duck typing (no validation)
- **Pros**: Simpler, more flexible
- **Cons**: Errors happen at runtime during command execution, poor UX
- **Decision**: Validation is worth the complexity for better error messages

### No Inter-environment Communication

**Decision**: Environments communicate via filesystem only

**Rationale**:
- Explicit data flow (agent can see files being read/written)
- Simpler architecture (no message passing between environments)
- Sufficient for all identified use cases
- Clear ownership (files vs environment state)

**Alternative considered**: Direct inter-environment channels (pipes, shared memory)
- **Pros**: Faster data transfer, no intermediate files
- **Cons**: Hidden data flow, complex implementation, harder to debug
- **Decision**: Filesystem is explicit and sufficient

### No Automatic Rollback

**Decision**: Agent manages state explicitly (git commits, checkpoints), orchestrator has no rollback

**Rationale**:
- Explicit state management is clearer
- Agent should understand what changed and why
- Type system should prevent invalid states
- Automatic rollback hides problems instead of preventing them

**Alternative considered**: Transaction-based commands with automatic rollback
- **Pros**: Safety net for multi-file operations
- **Cons**: Hidden complexity, hard to debug, doesn't fit philosophy
- **Decision**: Agent uses git explicitly for state management

### Screen Truncation

**Decision**: Environments specify `max_lines`, orchestrator enforces limit

**Rationale**:
- Prevents any single environment from dominating screen
- Environments can hint at priority via `max_lines`
- Simple to implement and understand
- Agent sees most important information

**Alternative considered**: Intelligent priority-based truncation
- **Pros**: Better utilization of screen space
- **Cons**: More complex, unclear how to assign priorities
- **Decision**: Simple line limits are sufficient initially

### Command Timeouts

**Decision**: No timeout mechanism in initial version

**Rationale**:
- pexpect timeout doesn't actually interrupt execution, just stops waiting
- Child process (bash/python) remains blocked, leaving environment in broken state
- Implementing real timeout requires killing and restarting environment (loses state)
- Better to be honest about limitation than provide broken timeout

**Future enhancement**:
- Allow agent to choose: kill environment (lose state) or continue waiting
- Requires orchestrator-level monitoring and explicit agent control
- Deferred until we understand trade-offs in practice

**Alternative considered**: Timeout kills and restarts environment
- **Pros**: System recovers from infinite loops
- **Cons**: Loses all state (variables, cwd), destructive, complex
- **Decision**: Defer to future, agent must be careful for now
