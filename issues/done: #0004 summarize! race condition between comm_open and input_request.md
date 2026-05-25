# `summarize!` race condition: `input_request` may arrive before `comm_open`

## Summary

The `summarize!` RPC protocol sends a `comm_open` iopub message to register
the request, then separately sends an `input_request` via stdin to wait for
the reply. If the `input_request` arrives at the Node.js handler before the
`comm_open` has been processed, the reply promise is not yet registered and
the call fails with "Summary request state was missing".

## Protocol overview

```
Julia (sandbox)                         Node.js (agent)
─────────────────────────────────────────────────────────
IJulia.Comm(...) ──[comm_open iopub]──► handleSummaryComm
                                          sets pendingSummaryReplies[commId]
IJulia.readprompt(prompt) ─[input_request stdin]──► handleInputRequest
                                          waitForPendingSummary(commId) ← polls 1s
                                          reads pendingSummaryReplies[commId]
```

The race: `iopub` and `stdin` are separate ZMQ sockets processed in separate
async loops (`iopubLoop` / `stdinLoop`). There is no ordering guarantee
between them. Node.js may process `input_request` from stdin before it has
processed `comm_open` from iopub.

## Current mitigation

`waitForPendingSummary` polls `pendingSummaryReplies` for up to 1 second
(100 × 10ms sleeps) before returning `null`:

```js
async function waitForPendingSummary(commId) {
  const deadline = Date.now() + 1000;
  while (Date.now() < deadline) {
    const pendingReply = pendingSummaryReplies.get(commId);
    if (pendingReply) return pendingReply;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return null;
}
```

1 second is likely sufficient under normal conditions but is not guaranteed
under load or on slow systems. When it fires, the error propagates back to
Julia and `summarize!` throws.

## Fix

Increase the poll window (e.g. to 5 seconds), or replace the polling loop
with a proper `Promise` that resolves when the `comm_open` is received — for
example by registering a one-time resolver in `pendingSummaryReplies` before
the `input_request` arrives, then resolving it from `handleSummaryComm`.

## Affected files

- `agent/src/Agent/Services/Jupyter.js` — `waitForPendingSummary`,
  `handleSummaryComm`, `handleInputRequest`
