# Python Environment

**Purpose**: Execute Python code, maintain REPL state, perform data analysis and computation.

## Implementation

- Runs persistent Python REPL process using `pexpect`
- Maintains global/local namespaces between commands
- Executes code, captures printed output and expression results
- Introspects namespace to display variables on screen

## Command format

```python
python code (can be multi-line)
```

## Response format

```
<all output from Python REPL, including printed output and expression results>
<exception traceback if error occurred>
```

## Screen format

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

## Use cases supported

- Data analysis: `df = pd.read_csv('data.csv')`, `df.describe()`
- Visualization: `plt.plot(x, y)`, `plt.savefig('plot.png')`
- ML training: `model.fit(X_train, y_train)`
- Statistical analysis: `mean = df['price'].mean()`
- Web scraping: `driver.get('https://example.com')`
- Profiling analysis: `p = pstats.Stats('profile.stats')`, `p.print_stats(10)`
- Algorithm development: Define functions, test iteratively

## State maintained

- Global namespace (variables, functions, classes)
- Imported modules
- Current working directory (Python's `os.getcwd()`, agent can change with `os.chdir()`)
- Variable ordering list (for tracking recent use)

## Design decisions

1. **All output captured**: Python REPL naturally shows expression results; we capture all output without special handling
2. **Variable display shows types only**: Show variable names with type (not values) to avoid screen clutter from large objects
3. **Recent use ordering**: Track variable usage via simple regex matching in commands, show most recently used first
4. **Exception handling**: Full traceback in response
5. **Package installation**: Use bash `pip install`, not Python subprocess
6. **Working directory shown**: Display `os.getcwd()` on screen to avoid confusion with bash cwd
7. **No background execution**: Long tasks block until complete
8. **Minimal screen until first use**: Before first command, show only "Python REPL (ready)" to avoid clutter

## Variable display logic

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

## Usage tracking

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

## Screen variable filtering

- Exclude private variables (starting with `_`)
- Exclude modules and builtins
- Limit to 100 most recently used variables
- Show in order of recent use (most recently used first)

## Edge cases

- Infinite loops: Will block the system indefinitely. Agent must be careful. Future: allow agent to kill environment (losing state) or continue waiting.
- Memory leaks: Agent's responsibility to manage namespace
- SyntaxError: Return error in response, continue
- Variable name collisions in regex: Simple regex may match variable names within strings or comments; acceptable trade-off for simplicity

## Related Documents

- [Environment Contract](environments.md)
- [Bash Environment Design](bash-environment.md)
- [Editor Environment Design](editor-environment.md)
- [Orchestrator Overview](overview.md)
