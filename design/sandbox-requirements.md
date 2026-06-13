# Sandbox Requirements

## Overview

The default sandbox is a gvisor-isolated OCI container that runs a Julia/IJulia
Jupyter kernel. The agent communicates with it over the Jupyter messaging
protocol using ZeroMQ Unix domain sockets. In its default `runsc` mode the
sandbox has no TCP/UDP network access and cannot modify the workspace's git
history. The launcher treats the workspace state at startup as trusted, but the
sandbox must not be able to write new workspace metadata in one run that causes
later launches to trust and mount new host information.

For environments where gVisor cannot run (for example, when the launcher is
itself invoked inside another sandbox), the launcher also supports a
**compatibility mode** selected with `SANDBOX_RUNNER=bwrap`. This mode keeps
the same filesystem layout, read-only git metadata, and IPC transport, but it
does **not** provide gVisor's syscall mediation and may have weaker network
isolation if the caller's environment does not allow creating a new network
namespace.

---

## Roles and Boundaries

- **Sandbox**: the isolated execution environment and everything running
  inside it — the Julia process, the IJulia kernel, and any code the agent
  asks it to execute. The default implementation uses gVisor; the compatibility
  implementation uses bubblewrap.
- **Launcher**: the `7aigent-sandbox` script that runs on the host, creates
 the runtime directory, generates the connection file, and starts the
  sandbox via `runsc` or `bwrap`.
- **Agent**: the process outside the sandbox that connects to the kernel and
  drives the ReACT loop. The agent is out of scope for these requirements;
  these requirements only specify the interface it can rely on.

---

## Requirements

### Security

**S1** — By default, the sandbox runs under gvisor (`runsc`) using the KVM
platform (`--platform=kvm`). All system calls from inside the container are
intercepted by gvisor's user-space kernel. An attacker with unrestricted root
RCE inside the container cannot compromise the host kernel.

**S1a** — When `SANDBOX_RUNNER=bwrap` is set, the launcher starts the sandbox
under bubblewrap as a compatibility mode for nested or otherwise constrained
environments. This mode is intentionally weaker than S1: it preserves
filesystem isolation and namespace separation where available, but it does not
provide gVisor syscall mediation.

**S2** — In the default `runsc` mode, the container has no TCP/UDP network
access (`--network=none`). No outbound or inbound TCP/UDP connections are
possible from within the sandbox.

**S2a** — In `bwrap` compatibility mode, the launcher requests a dedicated
network namespace when the host environment permits it. If the environment does
not allow creating one, the launcher continues in compatibility mode and emits
an explicit warning on stderr that host-network isolation is unavailable.

**S3** — The root filesystem of the container is read-only. Writable surfaces
are limited to: `/tmp` (tmpfs, discarded on exit), `/home/julia` (tmpfs,
discarded on exit), and the workspace directory (bind mount, see S10–S12).

**S4** — Only the minimal Nix store closure required by the sandbox runtime is
mounted read-only inside the container under `/nix/store`. The Julia process
and any code it runs can read those store paths but cannot modify them. Host
store paths outside that mounted closure are not made available simply because
they exist on the host.

---

### Isolation Model

**S5** — In the default `runsc` mode, the container uses dedicated Linux
namespaces for PID, mount, IPC, UTS, and network. It shares no namespace with
the host other than the user namespace permitted by gvisor.

**S5a** — In `bwrap` compatibility mode, the launcher creates dedicated mount,
PID, IPC, and UTS namespaces. It also creates a dedicated network namespace
whenever available per S2a.

**S6** — The Julia process inside the container is started with two OS threads
(`julia -t 2`): one for the IJulia I/O loop (reading/writing ZMQ sockets) and
one for evaluating agent-submitted expressions. This ensures that the I/O
loop — including interrupt delivery — is never starved by a compute-heavy or
blocking evaluation.

---

### Communication

**S7** — The launcher creates a runtime directory on the host containing a
`sockets/` subdirectory. This directory is bind-mounted read-write at
`/sockets` inside the container. All ZeroMQ socket files are created in this
directory by the IJulia kernel.

**S7a** — In the default `runsc` mode, the launcher enables host Unix-domain
socket creation so the kernel can create its IPC socket files on `/sockets`.
Because `/workspace` is also a writable host-backed bind mount, sandboxed code
may create additional Unix-domain socket files under writable host-backed
paths. The launcher-provided Jupyter transport uses only `/sockets`.

**S8** — The kernel communicates using the Jupyter messaging protocol with
ZeroMQ IPC transport (`"transport": "ipc"`). No TCP sockets are used. The
five Jupyter channels (shell, iopub, stdin, control, heartbeat) are each a
Unix domain socket file under `/sockets/`.

**S9** — The launcher writes a `kernel.json` connection file to the sockets
directory before starting the container. The file follows the Jupyter kernel
connection file format with `"transport": "ipc"` and a randomly generated
HMAC-SHA256 key (a UUID4). The file is readable by the agent at the host path
`<runtime-dir>/sockets/kernel.json`. The agent uses this file to connect to
the kernel.

---

### Workspace Access

**S10** — The agent's workspace (the codebase being explored) is bind-mounted
read-write at `/workspace` inside the container. The Julia process may read
and write any file in the workspace, including creating and updating
`.7aigent/code_tree/` (the CodeTree cache).

**S10a** — The workspace must contain a `.7aigent/state/` directory before the
launcher starts the sandbox. The launcher validates that both `.7aigent/` and
`.7aigent/state/` are real directories inside the workspace (not symlinks) and
over-mounts `/workspace/.7aigent/state` read-only so sandboxed code cannot
change the launcher's trust state for later runs.

**S11** — The launcher's trust decision for git metadata is based on the host
workspace state observed at startup, plus the read-only `.7aigent/state`
directory. If `.7aigent/state/nogit` exists and `.git` is now present, the
launcher fails closed before starting the sandbox. This prevents a prior
sandbox run from creating a new `.git` entry that would be auto-trusted on
restart.

**S11a** — If the workspace starts without `.git`, the launcher creates
`.7aigent/state/nogit` on the host before starting the sandbox. On clean exit,
the launcher removes the sentinel only if `.git` is still absent. If the
process crashes, the sentinel may persist; the next startup treats
`nogit + no .git` as safe to continue and `nogit + .git present` as a hard
failure.

**S11b** — If the workspace starts with git metadata, that trusted startup
state is presented read-only inside the sandbox, overlaying the read-write
`/workspace` mount:

- If the workspace uses a `.git` directory, that directory is bind-mounted
  read-only at `/workspace/.git`.
- If the workspace uses a `.git` symlink to a directory, the resolved target is
  bind-mounted read-only at `/workspace/.git`.
- If the workspace uses a gitfile (`.git` is a file containing `gitdir: ...`),
  the launcher overlays a generated read-only `.git` file at `/workspace/.git`
  and bind-mounts the referenced common git metadata read-only at a stable
  sandbox path so that legitimate pre-existing worktrees continue to function.

The git metadata referenced by a trusted startup gitfile or symlink may live
outside the workspace. That is acceptable because it was already part of the
trusted host workspace state before the sandbox started.

In all cases, the Julia process and any subprocess it spawns can read git
history, run `git status`, `git diff`, etc., but cannot write to the object
store, update refs, or create commits.

**S12** — No commit tooling is available inside the sandbox. Commits are made
by a separate tool running on the host with full write access to `.git`. This
is intentional: the sandbox can produce file changes, but the decision to
commit is always made outside the sandbox.

---

### Offline Operation

**S13** — The container image depends on no network access at runtime. All
Julia packages required by the sandbox — `IJulia`, `ZeroMQ`, `CodeTree`, the
dedicated REPL API module, and their transitive dependencies — are pre-installed
in the Nix store and available via bind mount. `Pkg.add` is never called at
runtime.

**S14** — The Julia depot inside the container is configured with a writable
scratch path (`/tmp/julia-depot`) prepended before the read-only Nix-managed
depot. Julia writes precompilation caches and other runtime artifacts to the
scratch path; these are discarded when the container exits. The read-only
depot is never modified.

---

### Kernel Lifecycle

**S15** — The launcher prints the absolute host path of `kernel.json` to
stdout before the container starts accepting connections. The agent may begin
connecting as soon as it reads this path.

**S16** — The launcher remains resident after starting the sandbox so it can
forward `SIGTERM`/`SIGINT` to the underlying runner and then perform cleanup.
In the default `runsc` mode, termination is issued via `runsc kill`. The
sandbox may also be terminated by closing all connections and sending a
`shutdown_request` on the control channel. Both paths must result in a clean
exit with no orphaned socket files.

**S17** — On exit (clean or via signal), the runtime directory — including
the sockets directory and connection file — is removed by the launcher.

---

### Interrupt Handling

**S18** — The sandbox launcher accepts `SIGUSR1` as an interrupt signal.
When the launcher receives `SIGUSR1`, it delivers `SIGINT` to the running
sandbox process (bwrap: direct signal to the child; runsc: container signal
mechanism). `SIGINT` raises `InterruptException` in Julia's evaluation
thread, interrupting any running Julia expression including blocking I/O
waits (`run(cmd)`, `sleep`, network calls).

**S19** — After an interrupt, the kernel returns to a ready state and accepts
new `execute_request` messages normally. The agent does not need to restart
the kernel after an interrupt.

**S20** — External subprocesses spawned by `run(cmd)` inside the sandbox are
in the same process group as the Julia process. `SIGINT` delivered to Julia
propagates to any running child process, terminating it. After the child is
terminated, Julia catches the resulting error and the kernel recovers per S19.

---

### Launcher Interface

**S21** — The launcher is invoked as:

```
7aigent-sandbox <workspace-path>
```

It accepts exactly one positional argument: the absolute path to the workspace
on the host. It prints the absolute path of `kernel.json` to stdout, then
blocks until the sandbox exits.

**S22** — If the workspace path does not exist or is not a directory, the
launcher exits with a non-zero status and an informative message on stderr
before starting the container.

**S23** — The launcher is a self-contained shell script. It has no runtime
dependencies beyond the selected runner (`runsc` by default, `bwrap` in
compatibility mode) and standard POSIX shell utilities.

**S24** — The sandbox package is supported and exposed only on
`x86_64-linux`. Julia precompilation uses the `x86-64-v3` CPU target, matching
the supported NixOS platform baseline for this package.

**S25** — Direct Julia packages available in the sandbox are declared in one
Nix list. That list drives the generated Julia environment, target-specific
precompilation, and build-time import validation; adding a package requires
editing only that list.

**S26** — Target-specific Julia caches are built in derivations separate from
the sandbox launcher. Third-party package caches depend only on the package
list and Julia environment. REPL API caches depend on the REPL API and
CodeTree, but not on launcher, startup, rootfs, or launcher-test sources.

**S27** — General-purpose programs available inside the sandbox are declared
in one Nix list. That list drives both the minimal runtime closure and the
sandbox `PATH`; adding or removing a program requires editing only that list.

**S28** — Sandbox Nix configuration is contained in exactly two files:
`sandbox/packages.nix` declares available packages and `sandbox/default.nix`
defines all sandbox-related derivations and checks.
