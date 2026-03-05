# Context and State Management

This document describes how the agent manages conversation history, screen state, and context truncation.

## Conversation History

**Storage**: JSONL file, one message per line.

**Message format**:
```json
{"role": "system", "content": "You are an agent...", "timestamp": "2026-01-08T10:30:00Z"}
{"role": "user", "content": "Add authentication", "timestamp": "2026-01-08T10:30:05Z"}
{"role": "assistant", "content": "I'll add authentication...", "timestamp": "2026-01-08T10:30:10Z"}
{"role": "user", "content": "bash output: ...", "timestamp": "2026-01-08T10:30:15Z"}
```

**Roles**:
- `system`: System prompt (instructions, file restrictions, task)
- `user`: Task description, tool outputs, screen updates
- `assistant`: LLM responses (thoughts + commands)

## Screen History

**Purpose**: For debugging - inspect LLM context at specific step.

**Storage**: JSONL file, one screen state per step.

**Screen format**:
```json
{
  "step": 5,
  "timestamp": "2026-01-08T10:30:15Z",
  "sections": {
    "bash": {"content": "Working directory: /workspace\n...", "max_lines": 50},
    "python": {"content": "Variables:\n  df: DataFrame\n...", "max_lines": 50},
    "editor": {"content": "Views:\n  [main] src/main.py\n    45  def main():\n...", "max_lines": 50}
  }
}
```

**Inspection command**:
<bash>
# Show screen at step 5
7aigent --inspect <session-id> --step 5

# Show full LLM context at step 5 (system + history + screen)
7aigent --inspect <session-id> --step 5 --full-context
</bash>

## Context Truncation Strategy

**Problem**: LLM context windows are limited (e.g., 128k tokens). Long sessions exceed this.

**Initial strategy**: Simple truncation - keep system prompt, task, recent history, and current screen.

**Algorithm**:
```rust
fn build_llm_messages(
    history: &[Message],
    current_screen: &Screen,
    config: &BehaviorConfig,
) -> Vec<Message> {
    let mut messages = Vec::new();

    // 1. System prompt (always included)
    messages.push(build_system_prompt(config));

    // 2. Task description (always included)
    messages.push(Message::user(history.first().unwrap().content.clone()));

    // 3. Recent history (last N messages that fit)
    let max_history_tokens = 100_000;  // Reserve tokens for system + screen
    let recent_history = truncate_history(history, max_history_tokens);
    messages.extend(recent_history);

    // 4. Current screen (always included)
    messages.push(Message::user(format_screen(current_screen)));

    messages
}
```

**Future enhancement**: Smarter truncation
- Summarize old history with LLM
- Keep only key decision points
- Semantic compression

## Parallel Sessions

**Problem**: User wants multiple agents working in parallel.

**Solution**: Each session is independent.

**Implementation**:
- Different session IDs → different directories
- Each spawns its own container
- No shared state between sessions
- User responsibility to avoid conflicts (e.g., both modifying same file)

**Example**:
<bash>
# Terminal 1: Feature work
7aigent "Add dark mode toggle"

# Terminal 2: Hotfix (different session)
7aigent "Fix crash on invalid input"
</bash>

## Session Persistence

See [Architecture](architecture.md) for details on session directory structure.

**Location**: `~/.7aigent/sessions/<session-id>/`

**Files**:
- `metadata.json` - Session metadata, cost tracking
- `conversation.jsonl` - Full message history
- `screens.jsonl` - Screen state snapshots

This enables:
- Resume interrupted sessions
- Inspect session history for debugging
- Track costs across sessions

## Related Documents

- [Architecture](architecture.md) - Component structure
- [Cost Control](cost-control.md) - Token tracking and budgets
- [Overview](overview.md) - High-level responsibilities
