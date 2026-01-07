# Description

Implement the agent in Rust that manages the interaction loop with the LLM and communicates with the orchestrator.

# Plan

- [ ] Define core types
  - [ ] Define EnvironmentName newtype
  - [ ] Define CommandText newtype
  - [ ] Define message types for NDJSON protocol
  - [ ] Define LLMError enum with thiserror
  - [ ] Define OrchestratorError enum with thiserror

- [ ] Implement orchestrator communication
  - [ ] Implement NDJSON message sending
  - [ ] Implement NDJSON message receiving
  - [ ] Spawn orchestrator subprocess
  - [ ] Handle stdin/stdout pipes
  - [ ] Implement send_command()
  - [ ] Implement receive_response()
  - [ ] Handle EOF and parse errors

- [ ] Implement LLM client abstraction
  - [ ] Define LLMClient trait
  - [ ] Implement for Anthropic Claude API
  - [ ] Handle rate limiting with exponential backoff
  - [ ] Handle timeouts
  - [ ] Handle auth errors
  - [ ] Pattern match errors for appropriate handling

- [ ] Implement message management
  - [ ] System message construction
  - [ ] Task message
  - [ ] Screen message formatting
  - [ ] Conversation history management
  - [ ] Simple truncation strategy for history

- [ ] Implement response parsing
  - [ ] Parse LLM response for markdown code blocks
  - [ ] Extract environment name from language marker
  - [ ] Extract command text from code block
  - [ ] Handle parsing errors

- [ ] Implement main interaction loop
  - [ ] Initialize messages
  - [ ] Call LLM with context
  - [ ] Parse response for command
  - [ ] Send command to orchestrator
  - [ ] Receive response and screen update
  - [ ] Update conversation history
  - [ ] Update screen message
  - [ ] Loop until task complete

- [ ] Error handling
  - [ ] LLM errors with retry logic
  - [ ] Orchestrator errors with graceful shutdown
  - [ ] Diagnostic messages to stderr

- [ ] Write tests
  - [ ] Test message serialization/deserialization
  - [ ] Test command parsing from LLM responses
  - [ ] Test error handling and retries
  - [ ] Mock LLM client for testing
  - [ ] Mock orchestrator for testing

- [ ] Run formatters and linters
  - [ ] rustfmt
  - [ ] clippy with strict settings

# Dependencies

- Requires: Orchestrator implemented and tested
- Requires: Refined design with protocol specified

# Outcome

A working agent that can manage the LLM interaction loop and communicate with the orchestrator.
