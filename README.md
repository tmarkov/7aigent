# 7aigent

An AI agent for interactive codebase exploration. The agent indexes a codebase
into a relational schema (`code` + `refs` tables, see [`design/`](design/)), then
drives a ReACT loop: an LLM reasons over the index by issuing Julia queries to a
sandboxed REPL, reads the results, and iterates until it can answer the user's question.

## Architecture

```
┌─────────┐   prompt/result   ┌───────┐   Julia expr / output   ┌──────────────────┐
│   LLM   │ ◄────────────────► │ agent │ ◄──────────────────────► │ sandbox (RemoteREPL) │
└─────────┘                   └───────┘                          │   CodeTree.jl    │
                                                                  │   SQLite DB      │
                                                                  └──────────────────┘
```

| Component | Location | Role |
|-----------|----------|------|
| **CodeTree.jl** | [`CodeTree.jl/`](CodeTree.jl/) | Julia package — `code`/`refs` schema, indexing, query helpers |
| **sandbox** | [`sandbox/`](sandbox/) | Sandboxed Julia process with RemoteREPL + CodeTree pre-loaded |
| **agent** | [`agent/`](agent/) | ReACT loop — LLM ↔ sandbox bridge (language TBD) |

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

Initialise the sandbox Julia environment (one-time, after cloning):

```sh
julia --project=sandbox -e 'using Pkg; Pkg.instantiate()'
```

Build the sandbox derivation:

```sh
nix build .#sandbox
```

Start the sandbox:

```sh
./result/bin/7aigent-sandbox
```

Connect from another Julia session:

```julia
using RemoteREPL
connect_repl()   # connects to localhost:27754
```

## Design

See [`design/`](design/) for the schema specification and loading-process documentation.
