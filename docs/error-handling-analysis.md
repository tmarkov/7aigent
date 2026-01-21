# Error Handling Analysis: Terminating vs. Graceful Errors

## Overview

This document analyzes error handling in the orchestrator-agent communication protocol, identifying errors that currently terminate execution but should instead provide graceful feedback to the LLM.

## Current Architecture

### Communication Flow

1. **Agent** sends command via stdin to **Orchestrator**
2. **Orchestrator** processes command and sends response via stdout
3. **Agent** receives response and either:
   - Continues execution (normal response or failed command)
   - Terminates execution (error response)

### Response Types

#### Normal Response (Non-terminating)
```json
{
    "response": {
        "output": "command output here",
        "success": true/false
    },
    "screen": {
        "bash": {"content": "...", "max_lines": 50},
        "python": {"content": "...", "max_lines": 50}
    }
}
```

#### Error Response (Terminating)
```json
{
    "type": "error",
    "message": "error description"
}
```

## Error Categories

### 1. Errors That Currently Terminate

#### 1.1 Unknown Environment Error ⚠️ SHOULD BE GRACEFUL

**Location:** `orchestrator/executor.py:55-60`

**Trigger:** LLM uses non-existent environment (e.g., `text`, `javascript`)

**Current Behavior:**
```python
raise UnknownEnvironmentError(
    f"Unknown environment: {env_name.value!r}. "
    f"Available environments: {available}"
)
```
- Caught in `main.py:65-68`
- Sends error response via `send_error_response()`
- Agent receives error and terminates

**Example:**
```
❌ Error: Failed to receive response from orchestrator
  Caused by: Orchestrator returned error: Unknown environment: 'text'.
  Available environments: bash, python, editor
```

**Why This Should Be Graceful:**
- LLM can recover by using correct environment
- Error message is already helpful and actionable
- No corruption or invalid state

**Recommended Fix:** Return failed CommandResponse instead of raising exception

---

#### 1.2 Parse Errors ✅ SHOULD REMAIN TERMINATING (mostly)

**Location:** `orchestrator/communication.py:45-100`

**Triggers:**
- Invalid JSON syntax
- Missing required fields (`env`, `command`)
- Invalid field types
- Invalid environment name format (not a valid identifier)

**Current Behavior:**
- Caught in `main.py:53-56`
- Sends error response via `send_error_response()`
- Agent receives error and terminates

**Examples:**
```
Parse error: Invalid JSON: Expecting value: line 1 column 1 (char 0)
Parse error: Missing required field: 'env'
Parse error: Field 'env' must be a string
Parse error: Invalid environment name: '123abc' (must be valid identifier)
```

**Analysis:**

Most parse errors indicate bugs in the agent's command generation logic:
- Missing fields → agent parser bug
- Wrong types → agent parser bug
- Invalid JSON → communication layer bug

**Exception:** Invalid environment name format could occur if LLM generates malformed environment names. However, this is rare and would likely indicate a deeper issue.

**Recommendation:** Keep terminating for now, but monitor. If LLM frequently generates invalid environment names, make this graceful.

---

#### 1.3 Process Termination Errors ✅ SHOULD REMAIN TERMINATING

**Triggers:**
- Orchestrator process crashes
- Orchestrator process exits unexpectedly
- Pipe/communication channel broken

**Current Behavior:**
- Agent detects EOF or broken pipe
- Returns `ContainerError::BrokenPipe` or similar
- Terminates execution

**Why This Should Remain Terminating:**
- No way to recover (orchestrator is gone)
- Indicates serious system-level failure
- Cannot send commands or receive responses

---

### 2. Errors That Currently Continue (Graceful)

#### 2.1 Command Execution Failures ✅ CORRECT

**Examples:**
- `ls nonexistent_file` → "No such file or directory"
- `python syntax error` → Python traceback
- `editor view nonexistent.py` → "File not found"

**Current Behavior:**
- Environment returns `CommandResponse(success=False, output=error_message)`
- Agent receives normal response
- Error output sent to LLM as user message
- LLM can see error and retry

**Why This Is Correct:**
- LLM can learn from errors and fix them
- Part of normal task execution flow
- No corruption or invalid state

---

## Errors That Should Change from Terminating to Graceful

### Summary Table

| Error Type | Current Behavior | Should Be | Priority | Fix Location |
|------------|-----------------|-----------|----------|--------------|
| Unknown environment | Terminating | Graceful | **HIGH** | `executor.py:55-60` |
| Invalid env name format | Terminating | *Monitor* | LOW | `communication.py` |

---

## Recommended Changes

### 1. Unknown Environment Error (HIGH PRIORITY)

**Change:** Return failed CommandResponse instead of raising exception

**Before:** (`executor.py:54-60`)
```python
if env_name not in environments:
    available = ", ".join(name.value for name in environments.keys())
    raise UnknownEnvironmentError(
        f"Unknown environment: {env_name.value!r}. "
        f"Available environments: {available}"
    )
```

**After:**
```python
if env_name not in environments:
    available = ", ".join(name.value for name in environments.keys())
    return CommandResponse(
        output=f"Unknown environment: {env_name.value!r}. "
               f"Available environments: {available}",
        success=False
    )
```

**Impact:**
- LLM receives error as user message
- Can retry with correct environment
- Execution continues
- No agent code changes needed

**Side Effect:**
- `UnknownEnvironmentError` exception no longer raised
- Remove exception handling in `main.py:65-68`
- Can delete `UnknownEnvironmentError` class if unused elsewhere

---

### 2. Invalid Environment Name Format (MONITOR)

**Current Status:** Keep terminating for now

**Rationale:**
- Rare occurrence (requires LLM to generate malformed identifier)
- Likely indicates agent parser bug, not LLM error
- If this becomes common, revisit

**Future Change (if needed):**
- Same as unknown environment
- Return failed CommandResponse instead of parse error

---

## Implementation Plan

1. **Change `executor.py`:**
   - Replace `raise UnknownEnvironmentError` with `return CommandResponse`
   - Keep error message format identical

2. **Update `main.py`:**
   - Remove `UnknownEnvironmentError` catch block (lines 65-68)
   - Exception no longer raised, handled internally in `execute_command()`

3. **Clean up:**
   - Consider removing `UnknownEnvironmentError` class if only used for this
   - Or keep it for backward compatibility / documentation

4. **Test:**
   - Verify unknown environment returns failed response
   - Verify LLM receives error and can retry
   - Verify execution continues

---

## Acceptance Criteria

After implementation, the following should work:

```
[Step 1] Calling LLM...
=== ASSISTANT ===
Let me check the file.

```text
This is some explanation
```

=== ORCHESTRATOR ===
Unknown environment: 'text'. Available environments: bash, python, editor

[Step 2] Calling LLM...
=== ASSISTANT ===
Sorry, let me use the correct environment.

```bash
cat file.txt
```

=== ORCHESTRATOR ===
[file contents]
```

The agent should continue to Step 2 instead of terminating at Step 1.

---

## Future Considerations

### Additional Graceful Errors

Consider making these graceful in the future if they occur frequently:

1. **Environment initialization failures**
   - Current: Likely terminates during startup
   - Could gracefully disable environment and continue with others

2. **Resource limit errors**
   - Current: Depends on implementation
   - Could return failed response with resource limit message

3. **Timeout errors**
   - Current: Depends on implementation
   - Could return failed response with timeout message

### Error Recovery Patterns

For graceful errors, consider adding:
- Structured error codes (not just string messages)
- Suggestions for fixes in error messages
- Automatic retries with backoff (agent-side)
- Error analytics and monitoring
