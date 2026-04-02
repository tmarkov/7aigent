# Description

When the orchestrator returns a very large response, it should be automatically summarized before adding it to the conversation. Large responses fill up the context window unnecessarily.

Need to:
- Define a threshold for "too large" responses
- Implement automatic summarization when threshold is exceeded
- Keep essential information while reducing verbosity

# Scenarios

1. Orchestrator returns small response (under threshold) → added to conversation as-is
2. Orchestrator returns large response (over threshold) → summarized before adding to conversation
3. Summarized response includes key outcomes, file changes, and relevant state
4. Summarization doesn't lose critical information needed for subsequent turns
5. User can configure or disable summarization threshold

# Plan

- [ ] Determine appropriate size threshold for orchestrator responses
- [ ] Identify where orchestrator responses are added to conversation
- [ ] Design summarization strategy (what to keep, what to compress)
- [ ] Implement size detection logic
- [ ] Implement summarization logic (may use LLM or rule-based)
- [ ] Add configuration option for threshold (0 = disabled)
- [ ] Add tests for summarization logic
- [ ] Run `nix build .#agent` and `nix build .#orchestrator` to verify

# Dependencies

Task 35 (model data in config) - may need to configure summarization model separately.

# Outcome

Large orchestrator responses are automatically summarized to prevent context window bloat. Essential information is preserved while verbose output is compressed.
