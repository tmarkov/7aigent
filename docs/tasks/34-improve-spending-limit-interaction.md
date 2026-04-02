# Description

Improve the spending limit interaction in two ways:

1. **Remove pointless warning**: Currently, when approaching the spending limit, we give a warning and ask whether to continue. This is unnecessary - the user set the limit, they know it's there.

2. **Prompt when limit reached**: When the limit is reached, instead of crashing with an error, prompt the user whether to stop or increase the limit.

# Scenarios

1. Spending approaches limit (e.g., 90% of limit) → no warning, continue normally
2. Spending reaches limit → prompt user: "Limit reached. Enter new limit [default: stop]:"
3. User enters nothing or the same/lower limit (chooses to stop) → end session gracefully
4. User chooses to increase limit → do it and continue the session
5. User increases limit multiple times in a session → works correctly

# Plan

- [ ] Find current spending limit warning/error code
- [ ] Remove the "approaching limit" warning
- [ ] Replace limit-reached error with user prompt
- [ ] Implement limit increase flow (ask for new value, update config, but not the config file)
- [ ] Add tests for new interaction flow
- [ ] Run `nix build .#agent` and `nix build .#orchestrator` to verify

# Dependencies

None - this is a self-contained improvement to cost tracking.

# Outcome

No more warnings when approaching the spending limit. When limit is reached, user is prompted to stop or increase the limit. Sessions no longer crash due to spending limits.
