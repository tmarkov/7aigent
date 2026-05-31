# #0018 — Sandbox missing common tools (nix, git, etc.)

## Summary

The sandbox PATH (`sandbox/default.nix:102-110`) only includes:
- `julia`
- `coreutils`
- `bash`
- `iputils`

This means the agent cannot use `git`, `nix`, or any other standard Linux
tools from the REPL. The `.git` directory is bind-mounted read-only, but the
`git` binary itself is not available, so the agent cannot run git commands
even though `git_stage` and `git_commit` are exposed as direct tools.

## Impact

- The agent cannot run `nix build` or `nix flake check` to verify code
  compiles, so it can only catch syntax errors via `Meta.parseall` (which
  misses some compilation errors).
- The agent cannot use `git diff`, `git log`, or other git inspection
  commands from the REPL, despite the git-aware CodeTree integration making
  git data available.
- Common tools like `grep`, `find`, `less`, `curl` are absent, forcing the
  agent to use Julia for tasks that would be trivial in a shell.

## Expected behavior

The sandbox should include all common tools expected on a Linux system,
particularly `git` and `nix`.

## Location

`sandbox/default.nix:102-110` — the `sandbox_path` definition.
