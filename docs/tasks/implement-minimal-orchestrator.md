# Description

Implement a minimal working orchestrator that can communicate with an agent and execute commands in the bash environment. This provides early validation of the architecture and enables testing with a real environment before implementing the remaining environments.

This is a subset of the full orchestrator-core task, focusing only on what's needed to get bash working end-to-end.

# Plan

- [x] Implement communication.py module
  - [x] Implement read_message() for NDJSON parsing
  - [x] Implement send_response() for NDJSON serialization
  - [x] Implement send_error_response()
  - [x] Handle EOF and parse errors

- [x] Implement executor.py module (minimal version)
  - [x] Implement execute_command()
  - [x] Route commands to bash environment only
  - [x] Handle unknown environment errors
  - [x] Catch and report environment exceptions

- [x] Implement screen.py module (minimal version)
  - [x] Implement collect_screen_updates()
  - [x] Call get_screen() on bash environment
  - [x] Handle get_screen() exceptions
  - [x] Build Screen object (no aggregation needed yet)
  - [x] Apply max_lines truncation

- [x] Implement main.py module (minimal version)
  - [x] Implement main() entry point
  - [x] Main interaction loop
  - [x] Hardcode bash environment (no loading yet)
  - [x] Read commands from stdin
  - [x] Execute and collect screen
  - [x] Send responses to stdout
  - [x] Handle EOF for shutdown
  - [x] Implement shutdown for bash environment

- [x] Write tests
  - [x] Test message parsing and serialization
  - [x] Test command routing to bash
  - [x] Test screen collection from bash
  - [x] Test error handling at each layer
  - [x] Test shutdown sequence

- [x] Manual integration testing
  - [x] Test stdin/stdout communication manually
  - [x] Send bash commands via NDJSON
  - [x] Verify screen updates
  - [x] Test error cases end-to-end

- [x] Run formatters and linters

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
