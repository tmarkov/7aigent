# agent

The agent runner — the ReACT loop between the LLM and the sandbox REPL.

**Language TBD.** This component will:

1. Spawn `7aigent-sandbox` and connect to its RemoteREPL socket
2. Send the user's goal to an LLM along with available Julia tools
3. Receive Julia expressions from the LLM, forward them to the sandbox, and feed results back
4. Repeat until the LLM emits a final answer

See [`../design/`](../design/) for the schema the sandbox exposes.
