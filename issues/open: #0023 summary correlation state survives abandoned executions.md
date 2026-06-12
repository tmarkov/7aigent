# Summary correlation state survives abandoned executions

The Jupyter transport stores each summary `comm_open` payload in
`pendingSummaryReplies`, but removes it only when the matching reserved
`input_request` loader completes. If execution fails or is interrupted before
that input request arrives, the entry remains for the lifetime of the agent.

`comm_close` and execution completion should remove correlation state owned by
the affected summary request. Cleanup must preserve the valid cross-channel
race where `comm_open` arrives before `input_request`.

Add an A20b regression test that repeatedly abandons summary executions and
proves that pending and expired correlation state remains bounded.
