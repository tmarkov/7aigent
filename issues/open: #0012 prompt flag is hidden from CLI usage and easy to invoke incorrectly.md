# Prompt flag is hidden from CLI usage and easy to invoke incorrectly

## Summary

The agent CLI accepts an initial task prompt only via `-p <prompt>`, but the
usage text does not mention `-p`, and prompt-mode invocation is easy to get
wrong when launched through `nix run`.

## Observed behaviour

During self-testing, this invocation failed before the agent even started a
session:

```sh
nix run .#agent /tmp/workspace -- "Add a new tool for the agent to restart the Julia REPL."
```

The process exited with:

```text
Unknown command: Add a new tool for the agent to restart the Julia REPL. Follow AGENTS.md.. Usage: 7aigent [<dir>] [sessions|resume <id>|mcp <port>]
```

The actual working form was:

```sh
nix run .#agent -- /tmp/workspace -p "Add a new tool for the agent to restart the Julia REPL."
```

## Root cause

`agent/src/Agent/Programs/CLI.purs` only extracts prompts from `-p <prompt>`.
The parser does not accept a positional prompt argument, and the usage string
omits `-p`, so the help text does not describe the supported interface.

When launched via `nix run`, putting the workspace path before `--` also means
the path is consumed by `nix`, not by the program, which makes the failure mode
even less obvious.

## Impact

- New users can believe prompt-mode is broken.
- Automated self-test workflows can fail before the first session starts.
- The error message points at an “unknown command” instead of explaining the
  actual prompt syntax.

## Proposed fix

Choose one of these and document it clearly:

1. Accept a positional prompt argument in addition to `-p`.
2. Keep `-p` only, but update the usage text and README examples to show it.
3. Detect the common `nix run .#agent /path -- "task"` mistake and print a
   targeted hint about `nix run .#agent -- /path -p "task"`.
