# #0020 — Compaction corrupts session context

## Summary

When conversation context hits the `compaction_threshold` (tested at 120000
tokens), the compaction process can corrupt the session state, resulting in
all subsequent LLM calls returning 0 input tokens and 0 output tokens.

## Reproduction

Observed in run 2 of agent testing with `compaction_threshold = 120000`. The
session was working normally until compaction triggered at ~120K tokens per
request. After compaction, all subsequent calls returned empty responses with
0 tokens.

## Analysis

The compaction logic (`Agent/Programs/Compaction.purs`,
`Agent/Runner/Session.purs:1049-1053`):
1. Builds a compaction plan preserving initial/final messages
2. Calls LLM with a compaction prompt to summarize the middle
3. Replaces the middle with the summary
4. Validates post-compaction size against threshold

If the post-compaction request still exceeds the threshold, it fails with
`CompactionError`. The corruption may occur when the compacted conversation
is malformed (e.g., missing required message structure) or when the API
rejects the rebuilt context silently.

## Expected behavior

Compaction should never corrupt the session. If compaction fails or produces
an invalid conversation state, it should fall back gracefully (e.g., keep the
original context and warn, or trim older messages without summarization).

## Workaround

Increased `compaction_threshold` to 300000 to avoid triggering compaction.
This only works if per-request tokens stay below 300K.

## Location

- `agent/src/Agent/Programs/Compaction.purs:26-51`
- `agent/src/Agent/Runner/Session.purs:1049-1053`
