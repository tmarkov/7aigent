# A14–A16: Timeout interrupt checks not wired up

`agent/src/Agent/Programs/Timeout.purs` implements the full timeout logic
(`isCheckDue`, `buildTimeoutCheckRequest`, `interpretTimeoutResponse`) but
none of its functions are called from the session runner or anywhere else in
the agent. A14–A16 are therefore unimplemented.

## Observed behaviour

Long-running `julia_repl` calls (>30 s, sometimes >180 s) produce zero
`timeout_response` events in the session log. The runner never polls the LLM
to ask whether to interrupt.

## Expected behaviour (A14–A16)

While a `julia_repl` tool call is running, the runner should:

1. Poll `isCheckDue(elapsed, lastCheckAt)` and, when a checkpoint is due,
   send an out-of-band LLM request (`buildTimeoutCheckRequest`) asking
   whether to interrupt.
2. Log the check and the LLM response as a `timeout_response` event (not
   appended to conversation history).
3. If the LLM answers yes, send `interrupt_request` to the Jupyter control
   channel and return the partial output with `\n[interrupted]` appended.
4. If no, schedule the next check and continue waiting.

## Fix

Wire `Timeout` into the runner's tool-execution loop (likely
`ToolExecution.purs` or `Session.purs`) so that while the Jupyter execute
future is pending, the runner concurrently checks elapsed time and fires
interrupt-check requests at the A14 schedule.
