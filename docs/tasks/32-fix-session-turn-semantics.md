# Description

Fix two related issues with session and turn management:

1. **Remove meaningless session completion status**: Currently sessions are stored as "active" or "completed" in `.sessions` directory. This distinction is meaningless - what matters is whether a "turn" is completed. A turn is completed if the last message was from the LLM and contained no commands.

2. **Resume properly when last message was LLM**: Currently, after resume we always call the LLM. But if the last message in the session was an LLM message, the orchestrator should take its turn instead of calling the LLM again.

# Scenarios

1. Agent runs a turn, LLM responds with commands - turn is not complete, session resumes with orchestrator processing commands
2. Agent runs a turn, LLM responds without commands - turn is complete, session can be resumed later with LLM turn
3. User resumes session where LLM last responded with commands - orchestrator should process those commands, not call LLM
4. User resumes session where LLM last responded without commands - should call LLM for next turn
5. Session storage no longer distinguishes "active" vs "completed" sessions

# Plan

- [ ] Review current session storage structure in `.sessions` directory
- [ ] Remove "active"/"completed" distinction from session metadata
- [ ] Implement turn completion detection logic (LLM message with no commands)
- [ ] Fix resume logic to check last message type:
  - [ ] If last message was LLM with commands → orchestrator turn
  - [ ] If last message was LLM without commands → LLM turn
  - [ ] If last message was user/orchestrator → LLM turn
- [ ] Update any tests that depend on old session completion semantics
- [ ] Run `nix build .#agent` and `nix build .#orchestrator` to verify

# Dependencies

None - these are bug fixes to existing session management code.

# Outcome

Sessions are no longer marked as "completed" or "active". Turn completion is determined dynamically based on the last message in the session. Resume correctly routes to either orchestrator or LLM based on what the last message was.
