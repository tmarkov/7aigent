# Prompt-mode runs can exceed the configured budget by millions of tokens

## Summary

In self-testing, a prompt-mode run consumed roughly **3 million cumulative input
tokens** while the workspace config nominally targeted about **1 million**
(`max_tokens_per_turn = 50000`, `max_turns_per_round = 20`). The session kept
issuing tool-call turns long after the expected budget envelope.

## Observed behaviour

Starter-task rerun in a fresh copy of `test/code/self` produced:

- `67` `token_usage` events
- `66` `llm_response` / `tool_call` cycles
- `27` turns with `input_tokens > 50000`
- `total_session_input_tokens = 2,919,488` before the run was stopped
- `0` `compaction` events in the session log

The run did make partial code changes, but it stayed in exploration/repair loops
far beyond the intended autonomous budget.

## Root cause

The current controls do not bound prompt-mode sessions tightly enough:

1. `max_turns_per_round` does not cap the full number of inner ReACT
   tool-call cycles the way users expect from a “turn budget”.
2. There is no explicit **total session token budget** across main LLM calls
   and auxiliary summary queries.
3. Compaction did not trigger in this runaway session, so the prompt kept
   growing until each call was around 60k input tokens.

## Impact

- Self-test iterations can become unexpectedly expensive.
- Prompt tuning alone cannot guarantee the budget target the config appears to
  promise.
- Long exploratory loops become much harder to compare fairly across runs.

## Proposed fix

Add budget controls that match user expectations:

1. enforce a hard total-session budget across all LLM calls relevant to the run;
2. cap the inner ReACT tool-call loop directly, not only reflection rounds;
3. make compaction trigger reliably before prompt-mode sessions reach runaway
   prompt sizes;
4. surface the remaining budget in steering / logs so the model can react
   before the hard stop.
