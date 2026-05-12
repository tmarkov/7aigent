# agent

The agent runner — the ReACT loop between the LLM and the sandbox REPL.

**Written in PureScript (compiled to Node.js).** This component:

1. Spawns `7aigent-sandbox` and connects to its IJulia Jupyter kernel
2. Sends the user's goal to an LLM (OpenAI-compatible API) along with available tools
3. Executes tool calls (`julia_repl`, `git_diff`, `git_commit`), feeds results back to the LLM
4. Repeats until the LLM emits a final answer with no tool call

On first run it bootstraps `.7aigent/`, creates `.7aigent/state/`, and if it
finds a stale `state/nogit` alongside `.git`, it asks whether to halt or to
re-trust the current git metadata and proceed.

See [`../design/agent-requirements.md`](../design/agent-requirements.md) for the full specification.
