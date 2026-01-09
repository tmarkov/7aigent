# Task: Implement Container Integration with Nix

## Description

Build the orchestrator container using Nix (not Dockerfile) and integrate container spawning into the agent with proper sandboxing and resource limits.

## Context

- **Component**: Container build system + agent container manager
- **Design**: See `docs/agent-design.md` for container specifications
- **Requirements**: Use Nix for container definition, Podman for runtime

## Plan

### Phase 1: Nix Container Definition

- [ ] Create Nix container definition (`container.nix`)
  - [ ] Use `pkgs.dockerTools.buildLayeredImage`
  - [ ] Base contents: python313, bash, coreutils, findutils, gcc
  - [ ] Include orchestrator derivation
  - [ ] Set working directory to `/workspace`
  - [ ] Set entrypoint to orchestrator binary
  - [ ] Set PYTHONPATH to orchestrator package

- [ ] Add container to flake outputs (`flake.nix`)
  - [ ] Add `orchestratorContainer` output
  - [ ] Reference container.nix
  - [ ] Ensure it depends on orchestrator package

- [ ] Test container build
  - [ ] Run `nix build .#orchestratorContainer`
  - [ ] Verify output is a tarball
  - [ ] Load into Podman: `podman load -i result`
  - [ ] Test manual run: `podman run -i 7aigent-orchestrator:latest`

### Phase 2: Container Manager Implementation

- [ ] Implement image building (`agent/src/container/builder.rs`)
  - [ ] `build_container_image()` - call `nix build .#orchestratorContainer`
  - [ ] Parse build output to get image path
  - [ ] Load image into Podman with `podman load`
  - [ ] Return image name/tag
  - [ ] Cache: check if image already loaded, skip rebuild
  - [ ] Error handling for Nix build failures

- [ ] Implement container spawning (`agent/src/container/manager.rs`)
  - [ ] `ContainerManager::new()` - initialize with config
  - [ ] `spawn()` - build podman command with all flags
  - [ ] Add `--network=none` flag (V1 has no network)
  - [ ] Add `--rm` flag (auto-remove on exit)
  - [ ] Add `-i` flag (interactive stdin)
  - [ ] Add `--memory` and `--cpus` if configured
  - [ ] Mount project directory: `--mount type=bind,source=<proj>,target=/workspace`
  - [ ] Set environment variable: `-e PROJECT_DIR=/workspace`
  - [ ] Execute image with stdin/stdout pipes

- [ ] Implement container lifecycle (`agent/src/container/handle.rs`)
  - [ ] `ContainerHandle` struct (child process, stdin, stdout)
  - [ ] `shutdown()` - send EOF to stdin, wait for process exit
  - [ ] `is_running()` - check if container process is alive
  - [ ] Implement Drop trait to ensure cleanup
  - [ ] Handle orphaned containers (if agent crashes)

### Phase 3: Advanced Sandboxing (based on config)

- [ ] Implement advisory file access (`agent/src/container/sandbox.rs`)
  - [ ] Generate system prompt additions from `sandbox.files` config
  - [ ] Format read_only patterns as warning in prompt
  - [ ] Format no_access patterns as restriction in prompt
  - [ ] Return formatted text for system prompt

- [ ] Implement resource limits (`agent/src/container/resources.rs`)
  - [ ] Apply memory limit if `sandbox.resources.max_memory` set
  - [ ] Apply CPU limit if `sandbox.resources.max_cpus` set
  - [ ] Validate resource values (e.g., "4G", "2.0")
  - [ ] Tests for resource limit application

### Phase 4: Container Communication Protocol

- [ ] Enhance communication layer (`agent/src/container/protocol.rs`)
  - [ ] Move from basic implementation to robust error handling
  - [ ] `send_command()` - serialize to NDJSON, write with error handling
  - [ ] `receive_response()` - read line, parse JSON, handle errors
  - [ ] Handle incomplete reads (timeout, EOF)
  - [ ] Handle malformed JSON from orchestrator
  - [ ] Detailed error messages for debugging

- [ ] Implement screen state parsing (`agent/src/container/screen.rs`)
  - [ ] Parse screen JSON into `ScreenState` struct
  - [ ] Extract sections for each environment (bash, python, editor, etc.)
  - [ ] Handle missing or malformed sections gracefully
  - [ ] Tests for screen parsing

### Phase 5: Integration and Testing

- [ ] Write unit tests
  - [ ] Test container image building (mock nix command)
  - [ ] Test podman command construction
  - [ ] Test resource limit formatting
  - [ ] Test file access prompt generation

- [ ] Write integration tests
  - [ ] Test full container spawn → communicate → shutdown cycle
  - [ ] Test with actual orchestrator in container
  - [ ] Test file access to project directory (should work)
  - [ ] Test file access outside project directory (should fail naturally)
  - [ ] Test container cleanup on normal exit
  - [ ] Test container cleanup on error

- [ ] Test network isolation
  - [ ] Verify container has no network access
  - [ ] Try ping, curl from inside container (should fail)
  - [ ] Document V1 limitation (no allowlist)

- [ ] Add to Nix build
  - [ ] Ensure container tests run as part of `nix build .#agent`
  - [ ] Integration test: spawn real container, send commands, verify responses
  - [ ] Performance test: measure container startup time

### Phase 6: Documentation and Examples

- [ ] Document container setup
  - [ ] How to build container image
  - [ ] How Nix definition works
  - [ ] What's included in the container
  - [ ] Resource limits and their effects

- [ ] Document security model
  - [ ] File access (V1: advisory, V2: enforced)
  - [ ] Network isolation (V1: complete, V2: allowlist)
  - [ ] Resource limits
  - [ ] Container lifecycle

- [ ] Create example configs
  - [ ] Example .7aigent.toml with sandbox settings
  - [ ] Example with file restrictions
  - [ ] Example with resource limits

## Dependencies

- Agent core implemented (at least types and config)
- Orchestrator implemented and working
- Podman installed on system

## Outcome

A complete container integration that:
- Builds OCI images from Nix definitions (reproducible)
- Spawns Podman containers with orchestrator
- Configures sandboxing (network isolation, resource limits, file access prompts)
- Manages container lifecycle (spawn, communicate, cleanup)
- Handles errors gracefully
- Has comprehensive tests
- Is documented with examples
