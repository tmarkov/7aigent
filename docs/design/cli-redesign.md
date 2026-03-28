# Problems
1. Too much text is printed, difficult to parse and reason about
2. Inspection is not ergonomic

# Design

1. `7aigent` and `7aigent "command"` - this runs the agent in interactive mode, or with a pre-set command. When running, the agent should print:
- LLM messages (without thoughts)
- First 3 lines of orchestrator response. This should be enough to show if there was some error, and some of the information, but we generally don't want to see the full orchestrator response, we're more interested in what the agent is doing
- At the end of conversation, it prints a summary. It should also include session id

2. `7aigent resume [n]` - should resume session with id `n`. If `n` is not provided, should resume the last

3. `7aigent inspect [n]` - lists the output of the n-th session (same as when it was running: LLM messages, + top 3 lines of orchestrator responses). If `n` is not provided, shows the last session
4. `7aigent inspect [n] --calls` - lists the calls (currently `7aigent inspect n`)
5. `7aigent inspect n --call m` - this time it should show the complete LLM context for call m: system message, task message, conversation history, screen. Then it should also show the LLM response
6. `7aigent inspect n --call m --response` - list the m-th LLM message, then the orchestrator response and the screen (what's currently `--after m`)
7. `7aigent inspect n --screen m` - print just the screen after LLM message m

The rest of the functionality should stay the same.
