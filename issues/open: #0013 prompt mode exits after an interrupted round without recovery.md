# Prompt mode exits after an interrupted round without recovery

## Summary

When the agent is started with `-p <task>`, it always exits after the first
round. If that round is interrupted by a timeout-driven tool interrupt, the
session ends immediately even though the task is clearly incomplete.

## Observed behaviour

In a self-test run of the starter task, the agent:

1. explored for several turns without creating todos or editing files;
2. called `summarize!` on all chunks of `ToolExecution.purs`;
3. hit the 30-second timeout check;
4. chose to interrupt;
5. received a partial summarized table with `[interrupted]`;
6. ended the session with `session_end.reason = "prompt"` and no further
   recovery, reflection, or retry.

The workspace had no code changes at the end of the run.

## Root cause

`agent/src/Agent/Runner/Session.purs` ends any `maybePrompt` session after the
first round:

```purescript
Nothing, Just _ -> do
    finishSession ... SessionEndedPrompt
```

At the same time, `runRound` skips reflection when `runReactLoop` reports
`interrupted = true`. That means an interrupted tool call in prompt mode gets no
recovery turn and no reflection feedback; control just returns to the user.

## Impact

- One-shot prompt sessions are brittle: a single slow tool call can consume the
  entire autonomous run.
- Timeout interruption helps avoid hangs, but it also increases the chance that
  prompt-mode sessions end without useful progress.
- Prompt and config tuning can reduce the frequency, but cannot fully solve the
  underlying control-flow problem.

## Proposed fix

Prompt mode should keep going after an interrupted round unless a hard error
occurs or the reflection step marks the task complete. For example:

1. if a round ends with `interrupted = true`, inject a recovery message and run
   another turn in the same session; or
2. allow reflection to run after interrupted rounds so it can steer the next
   step before exiting; or
3. only use `SessionEndedPrompt` after a non-interrupted round has reached a
   stable stopping point.

## Related issues

- `#0011` covers the robustness of the interrupt mechanism itself.
- This issue is about the agent runner’s prompt-mode control flow after an
  interrupt has already happened.
