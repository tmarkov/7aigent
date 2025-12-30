# Description

Implement a minimal working orchestrator that can communicate with an agent and execute commands in the bash environment. This provides early validation of the architecture and enables testing with a real environment before implementing the remaining environments.

This is a subset of the full orchestrator-core task, focusing only on what's needed to get bash working end-to-end.

# Plan

- [ ] Implement communication.py module
  - [ ] Implement read_message() for NDJSON parsing
  - [ ] Implement send_response() for NDJSON serialization
  - [ ] Implement send_error_response()
  - [ ] Handle EOF and parse errors

- [ ] Implement executor.py module (minimal version)
  - [ ] Implement execute_command()
  - [ ] Route commands to bash environment only
  - [ ] Handle unknown environment errors
  - [ ] Catch and report environment exceptions

- [ ] Implement screen.py module (minimal version)
  - [ ] Implement collect_screen_updates()
  - [ ] Call get_screen() on bash environment
  - [ ] Handle get_screen() exceptions
  - [ ] Build Screen object (no aggregation needed yet)
  - [ ] Apply max_lines truncation

- [ ] Implement main.py module (minimal version)
  - [ ] Implement main() entry point
  - [ ] Main interaction loop
  - [ ] Hardcode bash environment (no loading yet)
  - [ ] Read commands from stdin
  - [ ] Execute and collect screen
  - [ ] Send responses to stdout
  - [ ] Handle EOF for shutdown
  - [ ] Implement shutdown for bash environment

- [ ] Write tests
  - [ ] Test message parsing and serialization
  - [ ] Test command routing to bash
  - [ ] Test screen collection from bash
  - [ ] Test error handling at each layer
  - [ ] Test shutdown sequence

- [ ] Manual integration testing
  - [ ] Test stdin/stdout communication manually
  - [ ] Send bash commands via NDJSON
  - [ ] Verify screen updates
  - [ ] Test error cases end-to-end

- [ ] Run formatters and linters

# Scope Limitations

This is a **minimal** version. Excluded from this task (deferred to full orchestrator-core):

- Loading environments from modules (just hardcode bash for now)
- Environment loader.py module (not needed yet)
- Multiple environments (just bash)
- Ad-hoc environment loading
- Aggregating screens from multiple environments

The goal is to get something working quickly to validate the design, not to build the complete system.

# Dependencies

- Requires: Orchestrator types (implement-orchestrator-types.md) ✅
- Requires: Bash environment (implement-bash-environment.md) ✅

# Outcome

A working minimal orchestrator that:
- Reads NDJSON commands from stdin
- Executes bash commands
- Returns NDJSON responses with screen updates
- Handles errors gracefully
- Validates the orchestrator design early

# Follow-up

After this task, the full orchestrator-core task will:
- Add environment loading system
- Support multiple environments simultaneously
- Add ad-hoc environment loading
- Handle screen aggregation from multiple environments
