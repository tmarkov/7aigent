# 7aigent

An AI agent for interactive codebase exploration. The agent indexes a codebase
into a relational schema (`code` + `symbols`, see [`design/`](design/)), then
drives a ReACT loop: an LLM reasons over the index by issuing Julia queries to a
sandboxed IJulia kernel, reads the results, and iterates until it can answer the
user's question.

## Architecture

```
┌─────────┐   prompt/result   ┌───────┐   Julia expr / output   ┌──────────────────┐
│   LLM   │ ◄───────────────► │ agent │ ◄─────────────────────► │ sandbox (IJulia) │
└─────────┘                   └───────┘                         │   CodeTree.jl    │
                                                                │   SQLite DB      │
                                                                └──────────────────┘
```

| Component | Location | Role |
|-----------|----------|------|
| **CodeTree.jl** | [`CodeTree.jl/`](CodeTree.jl/) | Julia package — `code`/`symbols` schema, indexing, query helpers |
| **sandbox** | [`sandbox/`](sandbox/) | Sandboxed Julia process exposing an IJulia kernel with CodeTree and the REPL API (`SevenAigentREPL`) pre-loaded |
| **agent** | [`agent/`](agent/) | PureScript/Node.js runner — spawns the sandbox, bridges LLM ↔ kernel, git tools, session logging/resume, MCP server mode |

## Development

Enter the dev shell:

```sh
nix develop
```

### CodeTree.jl

```sh
# Interactive development
julia --project=CodeTree.jl

# Run tests
julia --project=CodeTree.jl -e 'using Pkg; Pkg.test()'

# Build and test via Nix
nix build .#codeTree
```

### Sandbox

Build the sandbox derivation:

```sh
nix build .#sandbox
```

Julia packages and general programs exposed inside the sandbox are declared in
[`sandbox/packages.nix`](sandbox/packages.nix). Julia packages go in the
`julia` list. Programs on the sandbox `PATH` go in the `programs` list.

Ensure the workspace contains a host-managed state directory before launch:

```sh
mkdir -p /path/to/workspace/.7aigent/state
```

Start the sandbox against a workspace:

```sh
./result/bin/7aigent-sandbox /path/to/workspace
# prints: /tmp/7aigent-XXXXX/sockets/kernel.json
```

Use the default launcher mode for the hardened gVisor sandbox. For nested or
otherwise constrained environments where gVisor cannot run, a weaker
compatibility mode is available:

```sh
SANDBOX_RUNNER=bwrap ./result/bin/7aigent-sandbox /path/to/workspace
```

Connect from Python using `jupyter_client`:

```python
import jupyter_client, json
from pathlib import Path

conn_file = "/tmp/7aigent-XXXXX/sockets/kernel.json"
km = jupyter_client.BlockingKernelClient(connection_file=conn_file)
km.load_connection_file()
km.execute("1 + 1")
```

Run the sandbox tests (requires a prior `nix build .#sandbox`):

```sh
pytest sandbox/test/
```

### Agent

```sh
nix build .#agent

# Show CLI help
nix run .#agent -- --help

# Start an interactive session in a workspace
nix run .#agent -- /path/to/workspace

# Run a one-shot prompt-mode session
nix run .#agent -- /path/to/workspace -p "Inspect failing tests"

# Resume a session and give it an immediate task
nix run .#agent -- /path/to/workspace resume 3 --prompt "Continue from the saved state"
```

### All checks

```sh
nix flake check         # runs all checks including the VM-level sandbox test
```

## Design

See [`design/`](design/) for the full specification. Key documents:

| Document | Contents |
|----------|----------|
| [`codetree-requirements.md`](design/codetree-requirements.md) | CodeTree indexing requirements (R1, R2, …) |
| [`code-tree-schema.md`](design/code-tree-schema.md) | `code`/`symbols` schema rationale and example queries |
| [`loading-process.md`](design/loading-process.md) | Loading and incremental re-indexing algorithm |
| [`sandbox-requirements.md`](design/sandbox-requirements.md) | Sandbox security and isolation requirements (S1, S2, …) |
| [`repl-api-requirements.md`](design/repl-api-requirements.md) | REPL API (`SevenAigentREPL`) requirements (RA1, RA2, …) |
| [`agent-requirements.md`](design/agent-requirements.md) | Agent runner requirements (A1, A2, …) |
