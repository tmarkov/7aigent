# Description

Implement the help/documentation system designed in `docs/help-system-design.md`. This system enables LLM agents to discover environment capabilities through self-documenting screen displays without requiring guesswork or external documentation.

# Scenarios

(Same scenarios as design task - implementation must satisfy these)

1. **Create new file in unfamiliar project**: Agent creates CONTRIBUTING.md without prior knowledge
2. **Recover from command error**: Agent learns from error and completes edit successfully
3. **Use custom environment**: Agent discovers and uses postgres environment
4. **Multi-step workflow**: Agent uses bash → editor → python workflow effectively

# Plan

- [ ] Read and understand `docs/help-system-design.md` thoroughly
- [ ] Identify all components that need modification:
  - [ ] Core types (if screen format changes)
  - [ ] Environment protocol (if new methods needed)
  - [ ] Individual environments (bash, python, editor)
  - [ ] Orchestrator core (screen collection logic)
  - [ ] Communication protocol (if message format changes)
- [ ] For each component:
  - [ ] Implement changes according to design
  - [ ] Write comprehensive tests
  - [ ] Verify against scenarios
- [ ] End-to-end testing:
  - [ ] Test Scenario 1 (create file)
  - [ ] Test Scenario 2 (error recovery)
  - [ ] Test Scenario 3 (custom environment)
  - [ ] Test Scenario 4 (multi-environment workflow)
- [ ] Update documentation:
  - [ ] Update protocol.py docstrings
  - [ ] Update orchestrator.md if needed
  - [ ] Add usage examples to design doc
- [ ] Verify build passes: `nix build .#orchestrator`

# Dependencies

- **CRITICAL**: Requires `docs/help-system-design.md` to be complete
- Do not start implementation until design is reviewed and approved
- Requires: All three environments implemented (bash, python, editor)
- Requires: Orchestrator core

# Outcome

A fully functional help system where:

1. Agents can discover environment capabilities without guessing
2. Documentation appears on screen (strong attention) when needed
3. Conversation history accumulates natural usage examples
4. Progressive disclosure shows only relevant information
5. Works uniformly for built-in and custom environments
6. All four scenarios work end-to-end
7. All tests pass
