# Task: Fix Orchestrator Error Handling

## Description

Replace `success` field with `processed` field that has clear, consistent semantics across all environments. Add `exit_code` field to bash responses for structured exit code data.

## Context

**Exposed by**: Testing rework (Task 20, commits `6536899` through `ffc8c88`)

**Problem**: The `success` field has inconsistent semantics:
- **Bash**: `success` = (exit_code == 0) - conflates execution with outcome
- **Python**: `success` = True always (when REPL responds) - already correct semantics
- **Editor**: `success` = False for parse errors - already correct semantics

**Impact**: Integration tests forced to use fail-dangerous negative assertions:
```rust
// WORKAROUND: Can't use response.success reliably
assert!(!screen.content.contains("Error:") && !screen.content.contains("Invalid"));
```

## Solution

### Core Change

Rename `success` → `processed` with clear semantics:

**`processed = true`** means:
- Orchestrator routed to environment successfully
- Environment's `handle_command()` returned normally (no exception)
- Command was handled (check `output` and optional fields for results)

**`processed = false`** means:
- Routing failed (unknown environment), OR
- Command parsing failed (invalid syntax), OR
- Infrastructure failure (process crash, timeout, unexpected exception)

### Key Examples

| Scenario | `processed` | Additional Fields | Notes |
|----------|-------------|-------------------|-------|
| Bash `echo hello` | `true` | `exit_code: 0` | Success |
| Bash `false` | `true` | `exit_code: 1` | Execution succeeded, operation failed |
| Python `1/0` | `true` | - | Exception in output |
| Editor `view invalid` | `false` | - | Parse error |
| Unknown env | `false` | - | Routing error |
| Process crash | `false` | - | Infrastructure failure |

### Environment-Specific Fields

**Bash only**:
- Add `exit_code: int` field (0-255)
- Structured data we already have (from `echo $?`)
- Critical for tests to distinguish execution from outcome

**Python/Editor**:
- No additional fields needed
- Already have correct `processed` semantics

## Design Rationale

**Why this works**:
1. **Python already correct**: Returns `success=True` when REPL handles command (just rename)
2. **Editor already correct**: Returns `success=False` for parse errors (just rename)
3. **Bash needs fix**: Currently returns `success=(exit_code==0)` - change to always `processed=True` and add `exit_code` field
4. **Infrastructure exceptions caught**: All environments have try/except blocks that catch EOF, TIMEOUT, unexpected exceptions - these return `processed=False`

**Protocol extensibility**: Agent uses permissive JSON parsing (`serde_json::Value`) - adding fields is safe, won't break agent.

## Plan

### Phase 1: Update Orchestrator

**1.1 Update `CommandResponse`** (core_types.py):
```python
@dataclass  # Remove frozen=True to allow adding fields
class CommandResponse:
    output: str
    processed: bool  # Renamed from 'success'
```

**1.2 Update `send_response`** (communication.py line 131):

Change from:
```python
"response": {"output": response.output, "success": response.success}
```

To serialize all fields:
```python
response_dict = {"output": response.output, "processed": response.processed}
# Add environment-specific fields
for field_name in dir(response):
    if not field_name.startswith('_') and field_name not in ('output', 'processed'):
        value = getattr(response, field_name)
        if not callable(value):
            response_dict[field_name] = value
```

**1.3 Update BashEnvironment** (bash.py line 176-179):

Change from:
```python
success = self._exit_code == 0
return CommandResponse(output=output, success=success)
```

To:
```python
response = CommandResponse(output=output, processed=True)
response.exit_code = self._exit_code
return response
```

**1.4 Update other environments** (rename only, no behavior change):
- PythonEnvironment: `success=True` → `processed=True` (line 272)
- EditorEnvironment: All `success=` → `processed=`
- DeclarativeEnvironment: All `success=` → `processed=` (lines 121, 132, 134)
- Executor: All `success=` → `processed=`

**1.5 Update all orchestrator tests**:
- Replace `response.success` with `response.processed`
- Add test for bash `exit_code` field

**1.6 Verify**: `nix build .#orchestrator`

### Phase 2: Update Agent

**2.1 Update `CommandResponse`** (agent/src/types.rs):
```rust
pub struct CommandResponse {
    pub output: String,
    pub processed: bool,  // Renamed from 'success'
}
```

**2.2 Update parsing** (agent/src/container.rs line 180):
```rust
success: message["response"]["processed"].as_bool()...
```

**2.3 Update all agent tests**:
- Replace `success` with `processed`
- Remove workarounds for integration test brittleness

**2.4 Verify**: `nix build .#agent`

### Phase 3: Documentation

- Update protocol.py docstring with `processed` semantics
- Document bash `exit_code` field
- Update CLAUDE.md if needed

## Dependencies

None

## Outcome

After completion:

1. ✅ **Consistent semantics** across all environments
2. ✅ **Integration testing** works with fail-safe assertions
3. ✅ **Bash exit_code** available as structured data
4. ✅ **Extensible** for future environment-specific fields
5. ✅ **Minimal changes** - mostly renaming, only bash behavior changes
