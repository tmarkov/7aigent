# Description

Remove hardcoded model data from the codebase. Currently, we have hardcoded:
- Provider names and URL addresses
- Model names
- Cost information (input/output token costs)

All of this should be configurable. Additionally:
- Support costs from API response if available (some providers include `usage.cost`)
- Make cost calculation optional: if neither config nor API provides costs, report tokens only

# Scenarios

1. User configures a new model with costs in config file, API doesn't return costs → agent uses configured costs
2. User configures a new model with costs in config file, API returns costs -> agent uses API costs
2. User configures a model without costs, API returns costs → agent uses API costs
3. User configures a model without costs, API doesn't return costs → agent reports tokens only, no dollar amounts
4. User switches providers by changing config → works without code changes
5. Provider adds new model → user can use it by adding to config

# Plan

- [ ] Audit codebase for hardcoded model/provider data
- [ ] Design config schema for model configuration:
  - [ ] Provider URL
  - [ ] Model names/IDs
  - [ ] Input token cost
  - [ ] Cached input token cost (if applicable)
  - [ ] Output token cost
- [ ] Implement config parsing and validation
- [ ] Update cost tracking to check: API response → config → no costs
- [ ] Update reporting to handle missing costs gracefully
- [ ] Add tests for config parsing and cost calculation
- [ ] Run `nix build .#agent` and `nix build .#orchestrator` to verify

# Dependencies

None - this is a refactoring of configuration and cost tracking.

# Outcome

No hardcoded model or provider information. All model configuration is in config files. Cost calculation gracefully handles missing cost data by reporting tokens only.
