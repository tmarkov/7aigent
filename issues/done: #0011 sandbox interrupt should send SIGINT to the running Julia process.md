# Sandbox interrupt should send SIGINT to the running Julia process

## Summary

The agent currently interrupts long-running Julia execution by sending a
Jupyter `interrupt_request` on the control channel. In practice this is too
weak and too brittle for the sandbox requirements:

- stock IJulia handles `interrupt_request` by throwing `InterruptException` at
  the request task;
- this does not reliably interrupt work blocked in `run(cmd)` or other
  syscall/C-call paths;
- under gVisor systrap, delivery is even less reliable for tight loops because
  progress is only observed at syscall boundaries.

The proper fix is to give the sandbox an explicit **OS-level interrupt path**
that sends `SIGINT` to the running Julia process (or its process group /
container equivalent) without tearing down the whole sandbox.

## Current state

`agent/src/Agent/Services/Jupyter.js` only has protocol-level interrupt:

- send Jupyter `interrupt_request` on the control socket;
- wait for the kernel to handle it.

This matches Jupyter's message path but not the stronger behaviour expected by
the sandbox requirements:

- **S18** says `interrupt_request` results in `SIGINT` reaching Julia;
- **S20** says subprocesses spawned via `run(cmd)` are interrupted as well.

Those requirements are really about **process signalling**, not only about a
control-channel message being delivered.

## Proposed fix

Add a sandbox-managed interrupt operation distinct from sandbox teardown:

1. Expose an API from the sandbox launcher / runner that targets the running
   Julia process or container with `SIGINT`.
2. Use that API from the agent when it decides to interrupt a `julia_repl`
   execution.
3. Keep the interrupt scoped to the current execution; do **not** terminate the
   launcher or destroy the kernel unless recovery fails.
4. Make the runner-specific implementation explicit:
   - `bwrap`: signal the Julia child directly;
   - `runsc`: use the runner's container signal mechanism to deliver `SIGINT`.

## Why not fix this in IJulia startup code?

An attempted workaround replaced `IJulia.run_kernel()` with custom startup
logic and a custom `interrupt_request` handler. That pushes process-management
policy into kernel bootstrap code and still does not provide a clean,
runner-aware interrupt contract.

The interrupt mechanism should instead live at the **sandbox boundary**, where
the process/container ownership information already exists.

## Related issues

- **#0008** wires timeout-driven interrupt decisions into the agent. That work
  is incomplete until the interrupt path is robust.
- **#0010** audits agent tests. The interrupt-related requirements there cannot
  be considered fully proven until the sandbox exposes the correct SIGINT-based
  interrupt behaviour.
