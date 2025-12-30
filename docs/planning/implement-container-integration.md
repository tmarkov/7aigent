# Description

Implement container integration using Podman to run the orchestrator in a sandboxed environment with access only to the project directory.

# Plan

- [ ] Create Containerfile/Dockerfile
  - [ ] Base image selection (Python 3.13)
  - [ ] Install Python dependencies (pexpect)
  - [ ] Install development tools (bash, gcc, etc.)
  - [ ] Copy orchestrator code
  - [ ] Set orchestrator as entrypoint

- [ ] Implement container management in agent
  - [ ] Spawn Podman container with orchestrator
  - [ ] Mount project directory as volume
  - [ ] Configure stdin/stdout pipes
  - [ ] Set environment variables (PROJECT_DIR)
  - [ ] Handle container startup errors

- [ ] Implement network isolation
  - [ ] Configure whitelisted internet resources (if needed)
  - [ ] Test network restrictions

- [ ] Test container integration
  - [ ] Test orchestrator starts in container
  - [ ] Test file access to project directory
  - [ ] Test file access outside project directory (should fail)
  - [ ] Test stdin/stdout communication through container
  - [ ] Test container shutdown

- [ ] Implement cleanup
  - [ ] Stop container on agent shutdown
  - [ ] Remove container after use
  - [ ] Handle orphaned containers

- [ ] Documentation
  - [ ] Document container setup
  - [ ] Document volume mounts
  - [ ] Document security model

# Dependencies

- Requires: Agent core implemented
- Requires: Orchestrator implemented

# Outcome

The agent can spawn the orchestrator in a Podman container with proper isolation and communication.
