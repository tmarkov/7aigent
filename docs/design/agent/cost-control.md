# Cost Control

This document explains the rationale behind the agent's cost control and budget management strategy.

## The Problem

LLM API calls cost money per token. Without careful management:
- Long sessions can accumulate significant costs
- Budget overruns surprise users
- No visibility into spending during operation

## Cost Sources

### Input Tokens
- System prompt (instructions, tool definitions)
- Conversation history
- Tool results from orchestrator

### Output Tokens
- Assistant reasoning and planning
- Tool call specifications

### Multipliers
- Different models have different pricing
- Input vs output token costs differ
- Some operations require multiple API calls

## Design Goals

1. **Transparency**: User always knows current spend
2. **Control**: User can set limits and have them enforced
3. **Flexibility**: Different budgets for different use cases
4. **Safety**: Never exceed user's budget without explicit consent

## Budget Architecture

### Budget Types

**Session Budget**: Maximum spend for a single session
- Set via CLI flag or config
- Tracked cumulatively across all API calls
- When exceeded: pause and ask user to continue or stop

**Warning Threshold**: Proactive notification
- Default: 50%, 75%, 90% of budget
- User sees progress without interruption
- Helps avoid surprise budget exhaustion

**No Budget Mode**: Explicit opt-out
- User explicitly chooses to run without limits
- Still tracks and reports costs
- Useful for trusted, time-sensitive work

### Budget Enforcement

```
┌─────────────────────────────────────────┐
│           Budget State Machine          │
├─────────────────────────────────────────┤
│                                         │
│  ┌─────────┐    budget    ┌─────────┐  │
│  │ Running │ ───────────▶ │ Paused  │  │
│  └────┬────┘   exceeded   └────┬────┘  │
│       ▲                         │       │
│       │         resume          │       │
│       └─────────────────────────┘       │
│                                         │
│  Any state ─▶ Stopped (user choice)    │
│                                         │
└─────────────────────────────────────────┘
```

When budget exceeded:
1. Stop before next API call
2. Display current spend and budget
3. Ask user: continue (with new budget) or stop
4. Resume only with explicit user consent

## Token Tracking

### Per-Message Tracking

Every message is tracked:
- Input token count
- Output token count
- Model used
- Timestamp

This enables:
- Accurate cost calculation
- Historical analysis
- Debugging cost anomalies

### Cost Calculation

```rust
cost = (input_tokens * input_price) + (output_tokens * output_price)
```

Prices are model-specific and configurable:
- Supports different pricing tiers
- Handles price changes gracefully
- Defaults to conservative estimates

## Implementation Details

### Budget Configuration

Budgets can be set via:
- CLI flag: `--budget 5.00` (dollars)
- Config file: `budget: 5.00`
- Environment variable: `AGENT_BUDGET=5.00`

Priority: CLI > Config > Environment > Default (no limit)

### Cost Reporting

After each API call:
- Log token counts and cost
- Update running total
- Check against budget thresholds

At session end:
- Report total cost
- Report token breakdown (input/output)
- Report by model if multiple used

### Persistence

Budget state is persisted with session:
- Running total survives restart
- Budget limit preserved
- Can resume interrupted sessions

## Trade-offs

### Why Per-Session Budgets?

**Alternative**: Global budget across all sessions
- Pro: Matches actual billing
- Con: Hard to attribute costs to specific work
- Con: Shared state across invocations

**Chosen**: Per-session budgets
- Pro: Clear attribution to specific tasks
- Pro: No shared state between sessions
- Con: User must set budget per session (or use config)

### Why Pause Instead of Stop?

**Alternative**: Hard stop when budget exceeded
- Pro: Guarantees budget adherence
- Con: Loses work in progress
- Con: Frustrating for users

**Chosen**: Pause and ask
- Pro: User has control
- Pro: Can continue if budget was conservative
- Con: Requires user interaction

### Why Track Per-Message?

**Alternative**: Track only totals
- Pro: Simpler implementation
- Con: No visibility into cost drivers
- Con: Can't debug expensive operations

**Chosen**: Per-message tracking
- Pro: Full visibility
- Pro: Enables analysis and optimization
- Con: More data to store

## Related Components

- **budget.rs**: Token counting and cost calculation
- **config.rs**: Budget configuration loading
- **session.rs**: Budget persistence

## Related Documents

- [Architecture](architecture.md) - Overall system design
- [Context Management](context-management.md) - Token usage and context limits
