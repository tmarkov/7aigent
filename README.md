# 7aigent

An AI agent for interactive codebase exploration. The agent indexes a codebase
into a relational schema (`code` + `symbols`, see [`design/`](design/)), then
drives a ReACT loop: an LLM reasons over the index by issuing Julia queries to a
sandboxed IJulia kernel, reads the results, and iterates until it can answer the
user's question.

## Architecture

```
┌─────────┐   prompt/result   ┌───────┐   Julia expr / output   ┌──────────────────┐
│   LLM   │ ◄────────────────► │ agent │ ◄──────────────────────► │ sandbox (IJulia) │
└─────────┘                   └───────┘                          │   CodeTree.jl    │
                                                                  │   SQLite DB      │
                                                                  └──────────────────┘
```

| Component | Location | Role |
|-----------|----------|------|
| **CodeTree.jl** | [`CodeTree.jl/`](CodeTree.jl/) | Julia package — `code`/`symbols` schema, indexing, query helpers |
| **sandbox** | [`sandbox/`](sandbox/) | Sandboxed Julia process exposing an IJulia kernel with CodeTree pre-loaded |
| **agent** | [`agent/`](agent/) | PureScript/Node.js runner — LLM ↔ sandbox bridge, git tools, session logging/resume |

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

## Design

See [`design/`](design/) for the schema specification and loading-process documentation.
