# #0022 — Network errors are not retried

## Summary

`classifyApiError` in `Llm.purs` only classifies three error types as
transient: HTTP 429, HTTP 5xx, and timeouts. Any other error — including
network failures like connection refused, DNS resolution failure, or
connection reset — falls through to `Nothing` and is treated as a
non-transient error that is never retried.

## Root cause

`agent/src/Agent/Services/Llm.purs:148-153`:

```purescript
classifyApiError err =
    case toMaybe err.statusCode of
        Just status -> Just (HttpStatus status)
        Nothing | err.isTimeout -> Just NetworkTimeout
        Nothing | looksLikeTimeout err.message -> Just NetworkTimeout
        Nothing -> Nothing  -- ← all other errors: no retry
```

And `agent/src/Agent/Programs/Retry.purs:40-43`:

```purescript
isTransient (HttpStatus 429) = true
isTransient (HttpStatus n) = n >= 500 && n < 600
isTransient NetworkTimeout = true
```

When an unclassified error reaches the call site (`Llm.purs:120-121`), it
immediately returns `Left (LlmApiError ...)` with no retry.

## Impact

A momentary wifi dropout, DNS blip, or provider connection reset kills the
entire agent session. These are the most common transient failures in
practice, and they are the easiest to recover from with a retry.

## Expected behavior

All errors should be retried up to `max_api_retries` with exponential
backoff. There are no real-world non-transient API errors that benefit from
failing fast mid-session — configuration errors (bad key, wrong endpoint)
fail on every call regardless, and the retry cost is trivial.

At minimum, `classifyApiError` should classify all network errors (no status
code, not a timeout) as transient rather than unclassified. The unclassified
`Nothing` branch should not exist.

Additionally, the error details should be logged so that persistent failures
can be diagnosed.

## Location

- `agent/src/Agent/Services/Llm.purs:148-153` — `classifyApiError`
- `agent/src/Agent/Programs/Retry.purs:40-43` — `isTransient`
