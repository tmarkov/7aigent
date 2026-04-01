# Sandboxing

This document explains the rationale behind the agent's security model and sandboxing strategy.

## The Problem

The agent executes commands and code on behalf of the user. Without proper isolation:
- Malicious or buggy code could damage the host system
- Accidental file deletions or modifications could occur
- Network access could be abused
- Resource consumption could impact the host

## Security Goals

1. **Isolation**: Agent operations cannot affect the host system
2. **Controlled Access**: Explicit allowlisting of what the agent can access
3. **Resource Limits**: Bounded CPU, memory, and disk usage
4. **Auditability**: Clear logging of what the agent does
5. **Usability**: Security doesn't prevent legitimate work

## Threat Model

### What We Protect Against

1. **Accidental Damage**: Agent deletes wrong files, runs dangerous commands
2. **Prompt Injection**: Malicious input causes agent to execute harmful actions
3. **Resource Exhaustion**: Agent consumes unbounded resources
4. **Data Exfiltration**: Agent sends data to unauthorized endpoints

### What We Don't Protect Against

1. **Malicious Host User**: If the user wants to damage their own system
2. **Physical Access**: Standard physical security is assumed
3. **Kernel Exploits**: We rely on OS-level isolation

## Architecture

### Bubblewrap Isolation

We use **bubblewrap** as the sandboxing mechanism:

```
┌─────────────────────────────────────────────────────────────┐
│  Host System                                                │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Agent (Rust binary)                                │   │
│  │  - Runs as user                                     │   │
│  │  - Manages sandbox lifecycle                        │   │
│  │  - Communicates via stdin/stdout                    │   │
│  └────────────────────┬────────────────────────────────┘   │
│                       │                                     │
│                       ▼                                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Bubblewrap Container                               │   │
│  │                                                     │   │
│  │  ┌─────────────────────────────────────────────┐   │   │
│  │  │  Orchestrator (Python)                      │   │   │
│  │  │  - Runs in isolated namespace               │   │   │
│  │  │  - Limited filesystem access                │   │   │
│  │  │  - No network (by default)                  │   │   │
│  │  │  - Bounded resources                        │   │   │
│  │  └─────────────────────────────────────────────┘   │   │
│  │                                                     │   │
│  │  Isolated:                                          │   │
│  │  - PID namespace (own process tree)                │   │
│  │  - Mount namespace (controlled filesystem)         │   │
│  │  - Network namespace (optional isolation)          │   │
│  │  - User namespace (UID mapping)                    │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Why Bubblewrap?

**Advantages:**
- Lightweight: No daemon, minimal overhead
- Unprivileged: Works without root
- Flexible: Fine-grained control over isolation
- Proven: Used by Flatpak for application sandboxing

**Alternatives Considered:**
- **Docker**: Heavier, requires daemon, privilege concerns
- **Firejail**: More complex, larger attack surface
- **gVisor**: Higher overhead, more complex setup
- **Namespace isolation directly**: More code to maintain

## Filesystem Access

### Default: Project Directory Only

By default, the sandbox only sees:
- Project directory (read-write)
- System libraries (read-only, via /nix/store)
- Temporary directory (isolated)

### Bind Mounts

Additional directories can be explicitly added:
```
--bind /host/path /sandbox/path
--ro-bind /readonly/path /sandbox/path
```

### Restrictions

- No access to home directory by default
- No access to /etc, /var, etc.
- No access to other users' files
- No access to system configuration

## Network Access

### Default: No Network

The sandbox starts with no network access:
- No outbound connections
- No DNS resolution
- No listening sockets

### When Network Is Needed

Some tasks require network access:
- Package managers (pip, npm, cargo)
- API calls
- Git operations

Network access is:
- Explicitly enabled per-session
- Logged for audit purposes
- Considered a privilege escalation

## Resource Limits

### CPU

- Default: 100% of one core
- Prevents runaway processes
- Configurable per-session

### Memory

- Default: 2GB
- Prevents memory exhaustion attacks
- OOM killer handles violations

### Disk

- Project directory: bounded by host filesystem
- Temp directory: limited size, auto-cleaned
- No access to other filesystems

### Process Count

- Default: 100 processes
- Prevents fork bombs
- Sufficient for typical work

## Implementation Details

### Container Lifecycle

1. **Spawn**: Agent invokes bubblewrap with configured options
2. **Setup**: Mount namespaces, set resource limits
3. **Execute**: Run orchestrator Python process
4. **Communicate**: JSON protocol over stdin/stdout
5. **Cleanup**: Kill processes, unmount, release resources

### Privilege Model

```
Host User → Agent (user privileges) → Bubblewrap → Orchestrator (mapped UID)
```

- Agent runs as the user (no special privileges)
- Bubblewrap creates isolated namespace
- Orchestrator runs as mapped UID (looks like root in container, actually user)
- No setuid binaries required

### Security Checklist

Each sandbox invocation:
- [ ] PID namespace isolated
- [ ] Mount namespace isolated
- [ ] Network disabled (unless explicitly enabled)
- [ ] Resource limits set
- [ ] Filesystem access restricted
- [ ] No privileged capabilities

## Trade-offs

### Why Not Full VM Isolation?

**Alternative**: Run in a VM
- Pro: Stronger isolation
- Con: Much higher overhead
- Con: Slower startup
- Con: More complex setup

**Chosen**: Container-based isolation
- Pro: Fast startup (< 1 second)
- Pro: Low overhead
- Pro: Simple configuration
- Con: Weaker isolation (kernel shared)

### Why Allow Any Host Access?

**Alternative**: Complete isolation with explicit file transfer
- Pro: Maximum security
- Con: Poor usability
- Con: Complex workflow

**Chosen**: Controlled host access
- Pro: Natural workflow
- Pro: Agent can work on real projects
- Con: Requires trust in agent behavior

### Why Not Default Network Access?

**Alternative**: Allow network by default
- Pro: Fewer configuration steps
- Con: Security risk
- Con: Unexpected data exfiltration

**Chosen**: No network by default
- Pro: Secure by default
- Pro: Forces explicit permission
- Con: Extra step when network needed

## Related Components

- **container.rs**: Bubblewrap invocation and lifecycle
- **config.rs**: Sandbox configuration options
- **agent.rs**: Sandbox spawning and communication

## Related Documents

- [Architecture](architecture.md) - Overall system design
- [Sandbox Design](../sandbox/) - Detailed sandbox implementation
