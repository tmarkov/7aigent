# `summarize!` hangs when `timedwait` cannot interrupt blocked ZMQ thread

## Summary

`summarize!` can hang indefinitely because the Julia-side timeout mechanism
(`timedwait`) cannot preempt the ZMQ C blocking call inside
`IJulia.readprompt`.

## Root cause

In `SevenAigentREPL/Summarize.jl`, `_request_summaries_via_comm` does:

```julia
response_task = @async IJulia.readprompt(prompt)
wait_status = timedwait(() -> istaskdone(response_task), SUMMARY_RPC_TIMEOUT_SECS)
if wait_status != :ok
    Base.throwto(response_task, InterruptException())
    throw(ErrorException("Summary RPC timed out waiting for frontend response."))
end
```

`IJulia.readprompt` calls `zmq_recv` (a C function) which blocks the OS
thread. Julia's cooperative scheduler cannot interrupt a task blocked in a C
call. `timedwait` will therefore never see `istaskdone(response_task) == true`,
and will spin forever — the `:timed_out` branch is unreachable in practice,
so `SUMMARY_RPC_TIMEOUT_SECS` provides no real protection.

The `@async` wrapper does not help: the task is marked as runnable, but it
never actually yields back to the scheduler.

## Workaround in place

A 30-second `Promise.race` timeout was added on the Node.js side in
`agent/src/Agent/Services/Jupyter.js` (`handleInputRequest`). When it fires,
Node sends an error `input_reply`, which unblocks the Julia `readprompt` call
and lets `_coerce_stdin_response` propagate the error. This prevents the
infinite hang but adds a 30-second delay per timed-out call.

## Correct fix

Use `Threads.@spawn` to run `IJulia.readprompt` on a separate OS thread so
that Julia's scheduler is not blocked, and `timedwait` works as intended.

Note: a previous attempt to use `Threads.@spawn` failed with
"cannot switch to task running on another thread" because Julia's `timedwait`
implementation uses task switching internally that is not compatible with
cross-thread communication in all Julia versions. The fix may require
restructuring the timeout logic (e.g. using a `Channel` or `Timer`).

## Affected files

- `sandbox/SevenAigentREPL/Summarize.jl` — `_request_summaries_via_comm`
- `agent/src/Agent/Services/Jupyter.js` — `handleInputRequest` (workaround)
