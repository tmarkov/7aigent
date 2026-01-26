# Task: Fix Orchestrator Error Handling

## Description

Orchestrator currently returns `success: true` even when commands fail or are malformed, with error information only in the response message text. This makes it difficult to distinguish success from failure programmatically and forces tests to use brittle negative assertions.

## Context

- **Component**: Orchestrator command execution and response handling
- **Current behavior**: Always returns `success: true`, puts errors in message text
- **Problem**: Tests must check for error strings like "Error:", "Invalid" to detect failures
- **Impact**: Brittle testing, harder to programmatically detect failures

## Motivation

When an environment receives a malformed command (e.g., `view` with invalid syntax), the orchestrator currently:
1. Returns `CommandResponse` with `success: true`
2. Includes helpful error message in `output` field (for LLM to fix the command)

This is problematic because:
- Tests can't distinguish success from failure by checking `success` field
- Must use negative assertions ("doesn't contain Error:") which are fail-dangerous
- External tools/scripts can't easily detect failures

## Scenarios

(To be defined during design phase)

## Plan

(To be defined during design phase - this is a placeholder task created during testing rework)

## Dependencies

None

## Outcome

(To be defined during design phase)
