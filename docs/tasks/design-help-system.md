# Description

Design a comprehensive help/documentation system for environment capability discovery that is fully self-documenting and context-aware. The system must present documentation on the screen (strong LLM attention) exactly when needed, while allowing conversation history to accumulate natural usage examples.

# Problem Statement

Agents currently have no way to discover what commands environments support. A naive "help command" approach fails because:

1. **Not self-documenting**: Requires agent to guess "help" exists
2. **Wrong context placement**: Documentation goes to conversation history (weak attention) instead of screen (strong attention)
3. **Static dumps**: Shows everything at once instead of progressive disclosure
4. **Missed opportunity**: Conversation history should accumulate examples, not documentation

# Context Structure

LLMs have stronger attention at beginning and end of context:

```
[Strong] System message - General instructions
[Strong] Task message - Specific task
[Weak]   Conversation history - Past interactions
[Strong] Screen - Current state
```

**Implication**: Documentation must appear on screen, not in conversation history.

# Design Constraints

1. **Fully self-documenting**: Zero guessing required. System makes help visible automatically.

2. **Context-aware placement**:
   - Documentation appears on **screen** (strong attention)
   - Conversation history accumulates **examples** (natural learning)

3. **Progressive disclosure**:
   - Show only what's needed for the NEXT step
   - Minimize irrelevant information
   - Adapt based on agent's current state

4. **Always accessible**:
   - No commands to guess
   - No external files to find
   - Built into the screen display

5. **Works for all environments**:
   - Built-in (bash, python, editor)
   - Custom/ad-hoc environments
   - Uniform experience

# Scenarios to Support

## Scenario 1: First-time agent creates file

**Situation**: Agent has never used orchestrator, needs to create CONTRIBUTING.md

**What agent sees:**
- Environments available: bash, python, editor
- NO prior knowledge of commands

**What agent needs:**
- Discover "create" command exists in editor
- Learn syntax for create command
- See example of usage

**Success criteria**: Agent creates file without guessing or external docs

## Scenario 2: Agent recovers from error

**Situation**: Agent tries `editor: edit file.py 45-45` and gets error "No view contains line 45"

**What agent needs:**
- Understand why edit failed
- Learn that view must exist first
- See how to create a view

**Success criteria**: Agent creates view, then successfully edits

## Scenario 3: Custom environment discovery

**Situation**: Human added `postgres` environment, agent needs to query database

**What agent needs:**
- Realize postgres environment exists
- Discover what commands postgres supports
- See syntax and examples

**Success criteria**: Agent executes SQL query successfully

## Scenario 4: Multi-step workflow

**Situation**: Agent needs bash → editor → python workflow for debugging

**What agent needs:**
- Discover capabilities of each environment
- Understand when to use which environment
- See examples of cross-environment workflows

**Success criteria**: Agent successfully uses all three environments

# Design Questions to Answer

In the design document (`docs/help-system-design.md`), address:

## 1. Where does documentation appear?

- What part of the screen shows documentation?
- Is it always visible or conditional?
- How does it avoid cluttering the screen?

## 2. What triggers documentation display?

- First time using orchestrator?
- After errors?
- When environment state changes?
- Always present in some form?

## 3. What information is shown?

- For each environment:
  - Available commands?
  - Command syntax?
  - Examples?
  - Current state requirements?
- How much detail at each stage?

## 4. How does it adapt/progress?

- What changes after first command?
- What appears after errors?
- How does it avoid repeating known information?
- How does conversation history capture examples?

## 5. How do custom environments participate?

- What must custom environment implement?
- How does it integrate with built-in help?
- Can it use same mechanism as bash/python/editor?

## 6. What are the implementation implications?

- Changes to screen format?
- Changes to environment protocol?
- Changes to orchestrator core?
- Backward compatibility?

# Success Criteria for Design

A complete design document (`docs/help-system-design.md`) that:

1. ✓ Addresses all five design constraints
2. ✓ Solves all four scenarios
3. ✓ Answers all six design questions
4. ✓ Provides concrete examples of screen content at each stage
5. ✓ Describes implementation approach at high level
6. ✓ Documents trade-offs and alternatives considered
7. ✓ Includes walk-through of Scenario 1 showing exact screen content

# Plan

- [x] Review existing screen format and protocol
- [x] Brainstorm approaches (screen section, inline hints, error messages, etc.)
- [x] Evaluate each approach against constraints
- [x] Design chosen approach in detail
- [x] Walk through all four scenarios with designed approach
- [x] Document trade-offs and alternatives
- [x] Write complete design document in `docs/help-system-design.md`

# Dependencies

- Requires: Understanding of current screen format
- Requires: Understanding of environment protocol
- Requires: Understanding of LLM context attention patterns

# Outcome

A comprehensive design document (`docs/help-system-design.md`) that specifies exactly how the help system will work, what the agent will see at each step, and how it will be implemented. This design can then be handed off for implementation.
