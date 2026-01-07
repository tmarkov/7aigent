# Description

Design and implement a mechanism for LLM agents to discover environment capabilities without external documentation. Currently, agents can see which environments are available but have no way to learn what commands each environment supports or how to use them.

# Scenarios

1. **Create new file in unfamiliar project**: Agent is asked to "add a CONTRIBUTING.md file to the project with guidelines for new contributors." Agent has never used this orchestrator before and sees environments [bash, python, editor] are available. Needs to create the file successfully.

2. **Recover from command error**: Agent attempts to edit a file but receives an error: "Error: No view contains line 45." Agent needs to understand what went wrong and successfully complete the edit.

3. **Use custom environment**: Human has configured a `postgres` environment for database operations. Agent is asked to "check if the users table has any orphaned records." Agent has never encountered this environment before and needs to complete the database query.

4. **Find information across large codebase**: Agent is asked to "find all TODO comments in the codebase and create a summary file." The codebase has 50+ files. Agent needs to search effectively across files and compile results.

5. **Multi-environment workflow**: Agent needs to run tests (bash), identify which test failed and why (bash output), view the failing test code (editor), and analyze the test data (python). Agent must successfully navigate using all three environments to diagnose the issue.

# Plan

- [ ] Define concrete scenarios where agents need capability discovery
- [ ] Review existing environment implementations to understand what needs to be exposed
- [ ] Design the capability discovery mechanism
  - [ ] Decide on approach (help command, schema introspection, etc.)
  - [ ] Define what information to expose (commands, parameters, examples)
  - [ ] Design the response format
  - [ ] Consider custom environments (must work for both built-in and ad-hoc)
- [ ] Update environment contract if needed
- [ ] Implement capability discovery for each environment
  - [ ] Bash environment
  - [ ] Python environment
  - [ ] Editor environment
- [ ] Write tests for capability discovery
- [ ] Update documentation
- [ ] Verify with end-to-end scenarios

# Dependencies

- Requires: All three environments implemented (bash, python, editor)
- Requires: Orchestrator core

# Outcome

LLM agents can discover and understand environment capabilities autonomously, enabling them to work effectively without external documentation or prior knowledge of available commands.
