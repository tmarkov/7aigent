# Sandbox Requirements

## Overview

The sandbox is a gvisor-isolated OCI container that runs a Julia/IJulia
Jupyter kernel. The agent communicates with it over the Jupyter messaging
protocol using ZeroMQ Unix domain sockets. The sandbox has no network access
and cannot modify the workspace's git history.

---

## Roles and Boundaries

- **Sandbox**: the gvisor container and everything running inside it — the
  Julia process, the IJulia kernel, and any code the agent asks it to execute.
- **Launcher**: the `7aigent-sandbox` script that runs on the host, creates
  the runtime directory, generates the connection file, and starts the
  container via `runsc`.
- **Agent**: the process outside the sandbox that connects to the kernel and
  drives the ReACT loop. The agent is out of scope for these requirements;
  these requirements only specify the interface it can rely on.

---

## Requirements

### Security

**S1** — The sandbox runs under gvisor (`runsc`) using the KVM platform
(`--platform=kvm`). All system calls from inside the container are intercepted
by gvisor's user-space kernel. An attacker with unrestricted root RCE inside
the container cannot compromise the host kernel.

**S2** — The container has no network access (`--network=none`). No outbound
or inbound TCP/UDP connections are possible from within the sandbox. The only
communication channel between the sandbox and the outside world is the set of
Unix domain sockets in the shared sockets directory (S7).

**S3** — The root filesystem of the container is read-only. Writable surfaces
are limited to: `/tmp` (tmpfs, discarded on exit), `/home/julia` (tmpfs,
discarded on exit), and the workspace directory (bind mount, see S10–S12).

**S4** — The Nix store is mounted read-only inside the container at
`/nix/store`. The Julia process and any code it runs can read store paths but
cannot modify them.

---

### Isolation Model

**S5** — The container uses dedicated Linux namespaces for PID, mount, IPC,
and UTS. It shares no namespace with the host other than the user namespace
permitted by gvisor.

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

**S11** — The workspace's `.git` directory is bind-mounted read-only at
`/workspace/.git`, overlaying the read-write `/workspace` mount. The Julia
process and any subprocess it spawns can read git history, run `git status`,
`git diff`, etc., but cannot write to the object store, update refs, or create
commits.

**S12** — No commit tooling is available inside the sandbox. Commits are made
by a separate tool running on the host with full write access to `.git`. This
is intentional: the sandbox can produce file changes, but the decision to
commit is always made outside the sandbox.

---

### Offline Operation

**S13** — The container image depends on no network access at runtime. All
Julia packages required by the sandbox — `IJulia`, `ZeroMQ`, `CodeTree`, and
their transitive dependencies — are pre-installed in the Nix store and
available via bind mount. `Pkg.add` is never called at runtime.

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

**S16** — The kernel is terminated by sending `SIGTERM` to the container
(via `runsc kill`). The container may also be terminated by closing all
connections and sending a `shutdown_request` on the control channel. Both
paths must result in a clean exit with no orphaned socket files.

**S17** — On exit (clean or via signal), the runtime directory — including
the sockets directory and connection file — is removed by the launcher.

---

### Interrupt Handling

**S18** — When the agent sends an `interrupt_request` on the Jupyter control
channel, IJulia delivers a `SIGINT` to the Julia process, which raises
`InterruptException` in the evaluation thread. This interrupts any running
Julia expression, including blocking I/O waits (`run(cmd)`, `sleep`, network
calls made before network isolation was established).

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
blocks until the container exits.

**S22** — If the workspace path does not exist or is not a directory, the
launcher exits with a non-zero status and an informative message on stderr
before starting the container.

**S23** — The launcher is a self-contained shell script. It has no runtime
dependencies beyond `runsc` (gvisor) and standard POSIX shell utilities
(`mktemp`, `cat`, `sed`, `chmod`).
