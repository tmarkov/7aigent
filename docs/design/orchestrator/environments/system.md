# System Environment Design

The system environment provides project context, git status, and directory structure information. It displays static project information that helps the agent understand the working context.

## Purpose

Display project-level context that doesn't fit in other environments:
- Current working directory
- Git status (branch, modified files, untracked files)
- Directory structure overview
- AGENTS.md content (project-specific instructions)

## Design Decisions

### Read-Only Display

The system environment is read-only. It doesn't accept commands—it only displays information. This is intentional:
- Project context should always be visible
- No risk of accidental modification
- Simpler implementation (no command parsing)

### Git Status Integration

Uses `git status --porcelain` for machine-readable output. This provides:
- Modified files (M)
- Untracked files (??)
- Staged files (A, M with index)

**Trade-off**: Requires git to be installed and the project to be a git repo. Falls back gracefully if not.

### AGENTS.md Visibility

If the project has an AGENTS.md file, its content is included in the system screen. This ensures project-specific instructions are always visible to the agent.

### Directory Tree

Shows a simplified directory tree (top-level directories and files). This gives the agent quick context about project structure without needing to list files manually.

## Screen Format

```
Project directory: /workspace

=== AGENTS.md (Project-specific instructions) ===
# Instructions for LLM Agents
... (content of AGENTS.md)

=== Git Status ===
On branch: main
Modified: src/main.py
Untracked: new_file.py

=== Directory Contents ===
total 120
drwxr-xr-x  1 user user   520 Apr  1 00:52 .
drwxr-xr-x 10 user user   260 Apr  1 11:09 ..
drwxr-xr-x  1 user user   184 Mar 31 13:01 .7aigent
drwxr-xr-x  1 user user   134 Mar 27 18:50 agent
...
```

## Related Files

- `orchestrator/environments/system.py` - Implementation
- `docs/design/orchestrator/protocol.md` - Communication protocol
