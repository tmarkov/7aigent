# Help System Overview

This document describes the design goals and principles for 7aigent's help and capability discovery system.

## The Problem

Agents need to discover environment capabilities without guessing. Traditional approaches fail:

- **"help" commands**: Agent must guess command exists
- **External documentation**: Not in LLM's attention during task execution
- **Static on-screen help**: Takes too much screen space after first use
- **No help at all**: Agent guesses and fails, wasting tokens

## Design Goals

The help system must satisfy these constraints:

1. **Fully self-documenting**: Zero guessing required. System makes help visible automatically.
2. **Context-aware placement**: Documentation on screen (strong attention), examples in conversation history
3. **Progressive disclosure**: Show only what's needed for the next step
4. **Always accessible**: No commands to guess, no external files
5. **Works for all environments**: Built-in and custom/ad-hoc environments

## Core Design Principle

Environments fall into two categories:

### 1. Freeform Environments

**Examples**: Bash, Python

Accept arbitrary input ("any bash command", "any Python code"). Help is simple and static - no progressive disclosure needed.

**Rationale**: These environments have no structured command set to document. Brief reminders are sufficient.

### 2. Structured Command Environments

**Examples**: Editor, custom command-based environments

Have a specific set of commands (view, edit, search, etc.). Use **per-command progressive disclosure**:
- **Command not used yet**: Show LONG help (detailed description + examples)
- **Command already used**: Show SHORT help (signature + one-line description)

This ensures the agent always has enough information to use new commands, while keeping the screen compact for familiar commands.

## Help Placement Strategy

### Screen Section (Persistent State)

Shows on every turn in the environment's screen output:
- Current environment state (working directory, variables, views, etc.)
- Available commands with appropriate level of detail
- Progressive disclosure based on usage

**Why screen**: Strong LLM attention, always visible when environment is active.

### Response Output (Contextual Help)

Shows only when relevant:
- Error recovery steps (e.g., "create a view first before editing")
- One-time guidance for specific failures
- Points to screen section for command details

**Why response**: One-time contextual information, doesn't clutter persistent state.

### Conversation History (Accumulated Examples)

Shows through actual usage:
- Agent's successful commands become examples
- LLM pattern-matches on previous successful usage
- No static documentation needed

**Why history**: Natural learning from experience, space-efficient.

## Success Criteria

This design succeeds if:

1. Agent can discover and use environments without guessing
2. Documentation appears on screen with strong LLM attention
3. Help is detailed for unused commands, compact for used commands
4. No help commands needed
5. Custom environments can participate with simple patterns
6. Error recovery is clear and actionable

## Related Documents

- [Declarative Environments](declarative-environments.md) - Base class for structured command environments
- [Progressive Disclosure](progressive-disclosure.md) - How per-command help tracking works
- [Orchestrator Architecture](../orchestrator/) - Overall environment system
