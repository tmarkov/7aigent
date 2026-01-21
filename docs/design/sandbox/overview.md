# Sandbox Overview

This document provides an overview of 7aigent's sandbox design and the rationale for choosing bubblewrap.

## Overview

The sandbox provides secure, isolated execution for the orchestrator while maintaining simplicity. Unlike traditional container systems (Docker/Podman), we don't need image management, networking, or orchestration - we just need one sandboxed process per agent session.

**Key design principles:**
1. **Simplicity**: No daemon, no image registry, just spawn a sandboxed process
2. **Security**: Strong isolation using Linux namespaces and bubblewrap
3. **Customization**: Users can add dependencies via Nix without complexity
4. **Transparency**: Stdin/stdout forwarded seamlessly for NDJSON protocol
5. **Minimal defaults**: Small base environment with only essentials

## Design Decision: Bubblewrap over gVisor

### Initial Consideration: gVisor

gVisor was initially proposed for strong isolation through its application kernel (Sentry). However, research revealed:

**Cons:**
- Still requires OCI container bundles (rootfs, config.json)
- Adds complexity: container bundle creation, OCI spec generation
- Requires additional tooling beyond just spawning a process
- Heavier weight than needed for our use case
- Less obvious integration with Nix's FHS user envs

**Pros:**
- Very strong isolation (userspace kernel)
- Good for untrusted code execution

### Chosen Solution: Bubblewrap

Bubblewrap provides exactly what we need:

**Pros:**
- **Designed for this use case**: Sandboxing single applications, not container management
- **Simple**: Just a command to wrap another command, no bundles or specs
- **Rootless**: Safely usable by unprivileged users
- **Lightweight**: Uses Linux namespaces directly, minimal overhead
- **Transparent I/O**: Stdin/stdout/stderr forwarding is trivial
- **Nix-friendly**: Works well with Nix store paths, we build our own secure invocation
- **Mature**: Used by Flatpak, tested at scale
- **Replaceable**: Easy to swap for more sophisticated sandbox in V2

**Cons:**
- Less isolation than gVisor (uses host kernel)
- Network is all-or-nothing (cannot selectively allow domains in V1)
- Requires careful namespace configuration

**Important clarifications:**
- While nixpkgs has `buildFHSUserEnv` (which uses bubblewrap internally), it's not designed as a secure sandbox
- We build our own bubblewrap invocation with explicit security settings
- The sandbox is designed to be replaceable - V2 can swap in a different implementation for network allowlisting or stronger isolation

**Decision**: Bubblewrap is the right tool for our security model (protect against accidental mistakes, not malicious code). For scenarios requiring stronger isolation (malware analysis), users can run 7aigent inside a full VM.

## Design for Replaceability

**Important**: The agent doesn't know or care what the sandbox implementation is. It just:
1. Executes the sandbox script: `<sandbox-path> <project-dir> [extra-args]`
2. Writes NDJSON commands to stdin
3. Reads NDJSON responses from stdout

This design allows easy replacement of the sandbox in V2:
- **For network allowlisting**: Replace bubblewrap with custom network namespace + nftables setup
- **For stronger isolation**: Replace with gVisor, Kata Containers, or full VM
- **For different platforms**: Replace with platform-specific sandboxing (macOS sandbox, Windows containers)

The sandbox is just a Nix derivation that produces an executable script. As long as it accepts the same arguments and speaks NDJSON on stdin/stdout, the agent works unchanged.

## Related Documents

- [Bubblewrap Implementation](bubblewrap.md) - Architecture and Nix build details
- [Customization](customization.md) - How users customize the sandbox environment
- [Security Model](security.md) - Threat model and security guarantees
- [Orchestrator Protocol](../orchestrator/) - NDJSON protocol between agent and orchestrator
