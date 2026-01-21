# Agent-Orchestrator Protocol Reference

This document specifies the JSON message formats for communication between the agent and orchestrator over stdin/stdout.

## Transport

Communication uses newline-delimited JSON (NDJSON):
- One JSON object per line
- Terminated by newline (`\n`)
- UTF-8 encoding

## Message Types

### Command (Agent → Orchestrator)

Sent by the agent to execute a command in an environment.

```json
{
  "type": "command",
  "environment": "bash",
  "command": "ls -la"
}
```

**Fields:**
- `type`: Always `"command"`
- `environment`: Name of the environment to execute in (string)
- `command`: Command text to execute (string)

**Example commands:**

```json
{"type": "command", "environment": "bash", "command": "git status"}
```

```json
{"type": "command", "environment": "python", "command": "import numpy as np\nprint(np.__version__)"}
```

```json
{"type": "command", "environment": "editor", "command": "view src/main.py /^def main/ /^if __name__/"}
```

### Response (Orchestrator → Agent)

Sent by the orchestrator after executing a command, includes command output and updated screen state.

```json
{
  "type": "response",
  "response": {
    "output": "total 48\ndrwxr-xr-x 2 user user 4096 ...\n",
    "success": true
  },
  "screen": {
    "bash": {
      "content": "Working directory: /workspace\nLast exit code: 0\n",
      "max_lines": 50
    },
    "python": {
      "content": "Python REPL (ready)",
      "max_lines": 50
    },
    "editor": {
      "content": "Editor (no views)",
      "max_lines": 50
    }
  }
}
```

**Fields:**
- `type`: Always `"response"`
- `response`: Object containing command execution results
  - `output`: Command output (string, may be empty)
  - `success`: Whether command succeeded (boolean)
- `screen`: Object mapping environment names to screen sections
  - Each key is an environment name (string)
  - Each value is a screen section object:
    - `content`: Screen content (string)
    - `max_lines`: Maximum lines for this section (integer)

### Error (Orchestrator → Agent)

Sent when the orchestrator encounters a protocol or system error (not a command execution error).

```json
{
  "type": "error",
  "message": "Unknown environment: foo\nAvailable: bash, python, editor"
}
```

**Fields:**
- `type`: Always `"error"`
- `message`: Human-readable error message (string)

**Error types:**
- Unknown environment
- Invalid JSON in command
- Missing required fields
- Environment initialization failure

## Protocol Flow

### Normal Execution

```
Agent                               Orchestrator
  |                                      |
  |--- command (bash: "ls") ----------->|
  |                                      | (executes command)
  |                                      | (collects screen)
  |<-- response (output + screen) ------|
  |                                      |
  |--- command (python: "1+1") -------->|
  |                                      | (executes command)
  |                                      | (collects screen)
  |<-- response (output + screen) ------|
  |                                      |
  |--- EOF (close stdin) -------------->|
  |                                      | (shutdown environments)
  |                                      | (exit)
```

### Error Handling

```
Agent                               Orchestrator
  |                                      |
  |--- command (foo: "bar") ----------->|
  |                                      | (unknown environment)
  |<-- error ("Unknown env...") --------|
  |                                      |
  |--- command (bash: "ls") ----------->|
  |                                      | (executes command)
  |<-- response (success=true) ---------|
```

Note: Environment-level errors (command failures) return `response` with `success=false`, not `error`.

## Screen State

The screen shows the current state of all loaded environments. Each environment provides a section showing its most relevant state.

### Screen Section Guidelines

**Before first use:**
Environments should return minimal content until first command:
```json
{"content": "Python REPL (ready)", "max_lines": 50}
```

**After use:**
Environments should show relevant state:
```json
{
  "content": "Working directory: /workspace/src\nLast exit code: 0\nBackground jobs: [1] 1234 ./server",
  "max_lines": 50
}
```

### Screen Truncation

- Orchestrator enforces `max_lines` limit per section
- If content exceeds `max_lines`, oldest lines are dropped
- Each environment controls its own `max_lines` value (default: 50)

## Example Session

### Initial Command

**Agent sends:**
```json
{"type": "command", "environment": "bash", "command": "pwd"}
```

**Orchestrator responds:**
```json
{
  "type": "response",
  "response": {
    "output": "/workspace",
    "success": true
  },
  "screen": {
    "bash": {
      "content": "Working directory: /workspace\nLast exit code: 0",
      "max_lines": 50
    },
    "python": {
      "content": "Python REPL (ready)",
      "max_lines": 50
    },
    "editor": {
      "content": "Editor (no views)",
      "max_lines": 50
    }
  }
}
```

### Python Command

**Agent sends:**
```json
{"type": "command", "environment": "python", "command": "import pandas as pd\ndf = pd.read_csv('data.csv')\nprint(df.shape)"}
```

**Orchestrator responds:**
```json
{
  "type": "response",
  "response": {
    "output": "(1000, 5)",
    "success": true
  },
  "screen": {
    "bash": {
      "content": "Working directory: /workspace\nLast exit code: 0",
      "max_lines": 50
    },
    "python": {
      "content": "Working directory: /workspace\n\nVariables (by recent use):\n  df: DataFrame\n  pd: module",
      "max_lines": 50
    },
    "editor": {
      "content": "Editor (no views)",
      "max_lines": 50
    }
  }
}
```

### Command Failure

**Agent sends:**
```json
{"type": "command", "environment": "bash", "command": "cat nonexistent.txt"}
```

**Orchestrator responds:**
```json
{
  "type": "response",
  "response": {
    "output": "cat: nonexistent.txt: No such file or directory",
    "success": false
  },
  "screen": {
    "bash": {
      "content": "Working directory: /workspace\nLast exit code: 1",
      "max_lines": 50
    },
    "python": {
      "content": "Working directory: /workspace\n\nVariables (by recent use):\n  df: DataFrame\n  pd: module",
      "max_lines": 50
    },
    "editor": {
      "content": "Editor (no views)",
      "max_lines": 50
    }
  }
}
```

### Protocol Error

**Agent sends:**
```json
{"type": "command", "environment": "unknown", "command": "test"}
```

**Orchestrator responds:**
```json
{
  "type": "error",
  "message": "Unknown environment: unknown\nAvailable: bash, python, editor"
}
```

## Implementation Notes

### Reading Messages

```python
import json
import sys

def read_message() -> dict | None:
    """Read one message from stdin."""
    line = sys.stdin.readline()
    if not line:  # EOF
        return None
    return json.loads(line)
```

### Sending Messages

```python
def send_response(response: CommandResponse, screen: Screen) -> None:
    """Send response to stdout."""
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
```

### Shutdown

Agent closes stdin (EOF) when session completes. Orchestrator:
1. Detects EOF on stdin read
2. Calls `shutdown()` on all environments
3. Exits cleanly

## See Also

- [Environment Protocol](environment-protocol.md) - Environment implementation contract
- [Configuration Reference](configuration.md) - Agent configuration options
