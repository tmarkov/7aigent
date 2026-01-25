# Sandbox Security Model

This document describes the security guarantees, threat model, and limitations of the bubblewrap-based sandbox.

## Isolation Boundaries

### What's Isolated

- ✅ **Filesystem**: Only /workspace and /nix/store visible
- ✅ **PID namespace**: Process list isolated
- ✅ **IPC namespace**: No shared memory with host
- ✅ **UTS namespace**: Separate hostname
- ✅ **User namespace**: (optional) Can map UID/GID for extra isolation

### What's NOT Isolated (by default)

- ❌ **Network**: Shared with host (--share-net)
  - Rationale: Scenarios (pip install, cargo build, npm install) need network
  - V1 limitation: Bubblewrap can `--unshare-net` but cannot provide selective network access
  - Users can disable network entirely with `sandbox.disable_network = true` (uses `--unshare-net`)
  - V2 enhancement: Implement network allowlisting via custom network namespace + iptables/nftables
- ❌ **/nix/store**: Read-only access to all Nix packages
  - Rationale: Required for running any programs
  - Not a security issue (read-only, immutable)

## Resource Limits

Bubblewrap doesn't directly support resource limits, but we can layer cgroups.

**V1 approach**: No resource limits (rely on OS, user ulimits)

**V2 approach**: Use systemd-run to spawn with cgroups:

<bash>
systemd-run --user --scope \
  -p MemoryMax=4G \
  -p CPUQuota=200% \
  7aigent-sandbox /workspace [args...]
</bash>

This would wrap the bubblewrap invocation in a cgroup.

## Threat Model

### Protects Against

1. **Accidental file access**: Agent can't modify /etc, /usr, other projects
2. **Filesystem corruption**: Only /workspace is writable
3. **Process interference**: Can't see or signal host processes
4. **Resource exhaustion**: (V2) cgroup limits prevent memory/CPU abuse

### Does NOT Protect Against

1. **Malicious code execution**: If agent runs malicious code in bash, it runs in sandbox with full workspace access
2. **Network attacks**: Network is shared (unless disabled)
3. **Kernel exploits**: Uses host kernel (unlike gVisor)

### Recommended For

- Development assistance (refactoring, bug fixes)
- Content creation (documentation, configuration)
- Data analysis (notebooks, scripts)

### NOT Recommended For

- Running untrusted binaries (malware analysis)
  - Alternative: Run entire 7aigent inside a VM

## Implementation Details

### Stdio Handling

**Transparent forwarding** is critical for NDJSON protocol:

```rust
// In agent's ContainerManager::spawn

let mut child = Command::new(&sandbox_path)
    .arg(project_dir)
    .stdin(Stdio::piped())
    .stdout(Stdio::piped())
    .stderr(Stdio::inherit())  // Agent's stderr
    .spawn()?;

ContainerHandle {
    stdin: BufWriter::new(child.stdin.take().unwrap()),
    stdout: BufReader::new(child.stdout.take().unwrap()),
    child,
}
```

Stdin/stdout are byte-for-byte forwarded (no processing in sandbox script).

### Cleanup and Termination

**Graceful shutdown:**

```rust
impl ContainerHandle {
    pub fn shutdown(mut self) -> Result<()> {
        // Send EOF to stdin
        drop(self.stdin);

        // Wait for process
        let status = self.child.wait()?;

        if !status.success() {
            return Err(OrchestratorError::ExitedWithError(status.code()));
        }

        Ok(())
    }
}
```

**Crash cleanup:**

Bubblewrap's `--die-with-parent` ensures sandbox exits if agent crashes. No orphaned processes.

### Error Handling

**Sandbox spawn failures:**

```rust
match Command::new(&sandbox_path).arg(project_dir).spawn() {
    Err(e) if e.kind() == ErrorKind::NotFound => {
        return Err(SandboxError::SandboxNotFound {
            path: sandbox_path.clone(),
            hint: "Run `nix build .#agent` to build sandbox",
        });
    }
    Err(e) if e.kind() == ErrorKind::PermissionDenied => {
        return Err(SandboxError::PermissionDenied {
            path: sandbox_path.clone(),
            hint: "Ensure bubblewrap is installed and executable",
        });
    }
    Err(e) => return Err(e.into()),
    Ok(child) => child,
}
```

**User namespace failures:**

Some systems disable unprivileged user namespaces. Bubblewrap detects this and falls back gracefully (or fails with clear error).

## Limitations and Future Work

### V1 Limitations

1. **No resource limits**: Requires manual systemd-run wrapper
2. **Network all-or-nothing**: Either --share-net (full access) or --unshare-net (no access)
3. **Custom sandbox rebuild**: Requires Nix rebuild when dependencies change
4. **Not suitable for untrusted code**: Requires VM for malware analysis

### V2 Enhancements

1. **Resource limits**: Automatic systemd-run wrapper with cgroups
2. **Network allowlisting**: Replace bubblewrap sandbox with custom solution
   - Option A: Use nftables/iptables with custom network namespace
   - Option B: Replace entire sandbox with more sophisticated runtime (gVisor, Kata Containers)
   - Design allows drop-in replacement: agent just calls sandbox script, doesn't care about implementation
3. **Faster customization**: Layer extra packages without full rebuild (OverlayFS?)
4. **Seccomp filters**: Restrict syscalls for additional hardening
5. **Audit logging**: Record all filesystem access for compliance

### Comparison to Original Podman Approach

| Feature | Podman (Original) | Bubblewrap (Current) |
|---------|-------------------|----------------------|
| Complexity | High (daemon, images, OCI specs) | Low (single command wrap) |
| Startup time | 1-2s | 0.2-0.3s |
| Nix integration | Build OCI image | Direct derivation |
| Customization | Rebuild image | Add packages to derivation |
| Security isolation | Strong (runc/crun) | Good (namespaces) |
| Rootless | Yes | Yes (by design) |
| Network control | Granular (CNI plugins) | Basic (all or nothing) |
| Resource limits | Built-in (cgroups) | External (systemd-run) |

**Verdict**: Bubblewrap wins on simplicity, Nix integration, and startup time. Podman wins on advanced features (which we don't need for V1).

## Related Documents

- [Sandbox Overview](overview.md) - Design rationale and decision process
- [Bubblewrap Implementation](bubblewrap.md) - Technical implementation details
- [Customization](customization.md) - How users extend the sandbox
