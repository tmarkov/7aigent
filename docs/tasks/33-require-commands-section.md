# Description

Sometimes the LLM misses the `# Commands` section and places commands directly in the response. Currently, we ignore these commands and treat the task/turn as complete. 

We should require that each message has either a `# Commands` section (if it needs to do work) or a `# Summary` section (if it's done). This makes the LLM's intent explicit and prevents silent failures.

# Scenarios

1. LLM responds with commands in `# Commands` section → commands are executed normally
2. LLM responds with `# Summary` section → turn is complete, no commands executed
3. LLM responds without either section → prompt LLM to add appropriate section
4. LLM responds with both sections → `# Commands` takes precedence, execute commands
5. LLM places commands outside `# Commands` section when either `# Commands` or a `# Summary` section is present → ignore them, they were likely thoughts or considerations.

# Plan

- [ ] Identify where LLM response is parsed for commands
- [ ] Add validation for required section (`# Commands` or `# Summary`)
- [ ] Implement prompting logic when neither section is present
- [ ] Add tests for validation logic
- [ ] Run `nix build .#agent` to verify

# Dependencies

None - this is a self-contained improvement to response parsing.

# Outcome

Every LLM message must have either `# Commands` or `# Summary` section. If neither is present, the agent prompts the LLM to fix the response. No silent failures from misplaced commands.
