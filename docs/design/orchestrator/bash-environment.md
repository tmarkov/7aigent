# Bash Environment

**Purpose**: Execute shell commands, manage processes, handle file system operations.

## Implementation

- Spawns persistent bash shell process using `pexpect`
- Sends commands to shell, reads combined stdout/stderr
- Tracks working directory and exit codes
- Supports background processes via shell job control (`&`, `jobs`)

## Command format

<bash>
any bash command
</bash>

## Response format

```
Combined stdout and stderr output
```

## Screen format

```
Working directory: /home/user/project/src
Last exit code: 0
Background jobs: [1] 1234 ./api_server
```

## Use cases supported

- Build/compilation: `gcc -o program program.c -Wall -O2`
- File operations: `mkdir -p output`, `find . -name "*.py"`
- Running tests: `pytest tests/`
- Git operations: `git status`, `git commit -am "message"`
- Starting services: `./start_server.sh &`
- Profiler execution: `python -m cProfile -o profile.stats train.py`
- Dependency audits: `pip-audit`, `npm audit`

## State maintained

- Current working directory
- Environment variables (inherited, modified via `export`)
- Last exit code
- Background job list

## Design decisions

1. **Combined stdout/stderr**: Matches terminal behavior, simpler than separate streams
2. **Background jobs via shell**: Use shell's job control, not orchestrator tracking
3. **Unique PS1**: Use special prompt to reliably detect command completion
4. **No interactive programs**: `gdb`, `vim`, etc. not supported initially (use ad-hoc environments with InteractiveEnvironment base class)
5. **Minimal screen until first use**: Before first command, show only "Bash shell (ready)" to avoid clutter

## Edge cases

- Infinite commands: Will block the system indefinitely. Agent must be careful. Future: allow agent to kill environment (losing state) or continue waiting.
- Large output: Truncate at 10MB, show warning
- Prompt detection: Use unique marker like `<<<PROMPT>>>` to avoid ambiguity

## Related Documents

- [Environment Contract](environments.md)
- [Python Environment Design](python-environment.md)
- [Editor Environment Design](editor-environment.md)
- [Orchestrator Overview](overview.md)
