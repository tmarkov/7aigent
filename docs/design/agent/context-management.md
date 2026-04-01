# Context Management

This document explains the rationale behind the agent's context management strategy.

## The Problem

LLMs have finite context windows. The agent maintains a conversation history that grows with each turn. Without careful management:
- Context overflows, causing API errors or truncated conversations
- Important context gets lost when truncation happens
- Costs increase linearly with conversation length

## Context Window Constraints

Different LLMs have different context limits:
- Claude: 200K tokens
- GPT-4: 128K tokens
- Smaller models: 4K-32K tokens

The agent must work within these limits while preserving:
1. System prompt (instructions, tool definitions)
2. User messages (tasks, clarifications)
3. Assistant messages (plans, reasoning)
4. Tool results (command outputs, file contents)

## Strategy: Layered Context

The agent uses a layered approach to context management:

### Layer 1: System Prompt (Never Truncated)
- Core instructions
- Tool definitions
- Output format specifications

This is always included and counts against the budget, but never gets truncated.

### Layer 2: Essential History (Preserved)
- Initial task description
- Key decisions made
- Current state summary

Preserved as long as possible, only truncated when absolutely necessary.

### Layer 3: Recent Turns (Preserved)
- Last N turns of conversation
- Most relevant to current work

Preserved until context pressure forces truncation.

### Layer 4: Old Turns (Truncated First)
- Historical conversation
- Completed subtasks
- Old tool results

First to be truncated when context pressure builds.

## Implementation Approach

### Token Counting

The agent tracks token counts for:
- Each message in history
- Each tool result
- Running total of context usage

This enables proactive truncation before hitting limits.

### Truncation Strategy

When context approaches limits:

1. **Summarize old turns**: Replace detailed history with summaries
2. **Remove old tool results**: Large outputs from completed work
3. **Compress conversations**: Keep conclusions, remove reasoning process

The goal is to preserve information density while reducing token count.

### Screen State Persistence

The screen provides context that doesn't need to be in conversation history:
- Current file views
- Environment state
- Working directory

This state persists across truncation events, giving the agent continuity.

## Trade-offs

### Why Not Always Keep Full History?

- **Cost**: Every token costs money
- **Latency**: Larger contexts mean slower responses
- **Quality**: Too much context can confuse the model

### Why Not Always Summarize?

- **Information loss**: Summaries miss details
- **Context breaks**: Agent may lose thread of work
- **Complexity**: Summarization is itself error-prone

### Chosen Balance

- Keep recent turns verbatim
- Summarize old turns when needed
- Preserve screen state separately
- Track costs explicitly

## Related Components

- **budget.rs**: Token counting and cost tracking
- **context.rs**: Context window management
- **session.rs**: Persistence of conversation history

## Related Documents

- [Architecture](architecture.md) - Overall system design
- [Cost Control](cost-control.md) - Token costs and budgets
