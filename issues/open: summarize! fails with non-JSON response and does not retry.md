# `summarize!` fails with "Summary response was not valid JSON" and does not retry

## Summary

When the LLM called by the summary sub-service returns malformed JSON,
`summarize!` throws immediately with no retry. The error propagates to the
agent as a hard exception, which causes the model to abandon tree-based
exploration and fall back to reading whole files.

## Root cause

In `agent/src/Agent/Services/Llm.js`, `extractJsonValue` attempts to parse
the summary LLM's response:

```js
function extractJsonValue(text) {
  const stripped = stripJsonFences(text);
  try {
    return JSON.parse(stripped);
  } catch (_) {
    // fallback: find first {...} block
    const start = stripped.indexOf("{");
    const end = stripped.lastIndexOf("}");
    if (start >= 0 && end > start) {
      return JSON.parse(stripped.slice(start, end + 1));
    }
    throw new Error("Summary response was not valid JSON");
  }
}
```

If the LLM response cannot be parsed (e.g. the model produced prose or
truncated output), the error propagates through:

`extractJsonValue` → `summarizeEvidence` (onError callback) →
`encodeSummaryReplyValue({ error: ... })` → `_coerce_stdin_response` →
`throw(ErrorException(...))` in Julia → `summarize!` throws.

There is no retry at any level of the stack.

This is observed with `deepseek/deepseek-v4-flash` which occasionally returns
non-JSON text for structured output requests.

## Impact

When the error fires during a session, the model loses trust in `summarize!`
and switches to reading entire files via `get_source`, sharply increasing
token consumption.

## Fix

1. **Structured output / JSON mode**: set `response_format: { type: "json_object" }`
   (or equivalent) on the summary LLM call in `summarizeEvidence`. Most
   OpenAI-compatible endpoints support this and eliminate malformed JSON.

2. **Retry on parse failure**: catch the JSON parse error in `summarizeEvidence`
   and retry the API call up to N times (e.g. 2 retries) before giving up.

Both fixes should be applied: structured output reduces failures to near-zero,
retry handles the residual cases.

## Affected files

- `agent/src/Agent/Services/Llm.js` — `extractJsonValue`, `summarizeEvidence`
