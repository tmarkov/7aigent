# Python Environment Design

The Python environment provides a persistent REPL for executing Python code, maintaining namespace state, and performing data analysis.

## Purpose

Execute Python code, maintain REPL state, perform data analysis and computation. This is the primary environment for:
- Data analysis (pandas, numpy)
- Machine learning (scikit-learn, pytorch)
- Visualization (matplotlib)
- Algorithm development
- Statistical analysis

## Design Decisions

### All Output Captured

Python REPL naturally shows expression results. We capture all output without special handling. This means:
- Printed output appears in response
- Expression results appear in response
- Tracebacks appear in response for errors

### Variable Display Shows Types Only

Show variable names with type (not values) to avoid screen clutter from large objects. A DataFrame or trained model would overwhelm the screen with its string representation.

**Trade-off**: Agent can't see values at a glance. Must explicitly print or inspect variables.

### Recent Use Ordering

Track variable usage via simple regex matching in commands, show most recently used first. This keeps relevant variables visible without manual organization.

**Trade-off**: Simple regex may match variable names within strings or comments. Acceptable for the use case—ordering is helpful but not critical.

### Working Directory Shown

Display `os.getcwd()` on screen to avoid confusion with bash cwd. Python maintains its own working directory, which can differ from bash.

### No Background Execution

Long tasks block until complete. Unlike bash, Python doesn't support background execution.

**Trade-off**: Long-running computations block everything. Agent must be aware of this limitation.

### Minimal Screen Until First Use

Before the first command, show only "Python REPL (ready)" to avoid clutter.

## State Maintained

- Global namespace (variables, functions, classes)
- Imported modules
- Current working directory (Python's `os.getcwd()`)
- Variable ordering list (for tracking recent use)

## Edge Cases

- **Infinite loops**: Will block the system indefinitely. Agent must be careful.
- **Memory leaks**: Agent's responsibility to manage namespace
- **SyntaxError**: Return error in response, continue
- **Variable name collisions in regex**: Simple regex may match variable names within strings; acceptable trade-off

## Related Files

- `orchestrator/environments/python.py` - Implementation
- `orchestrator/interactive.py` - Base class for process management
- `docs/design/orchestrator/protocol.md` - Communication protocol
