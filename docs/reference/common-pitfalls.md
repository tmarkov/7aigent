# Common Pitfalls and How to Avoid Them

This document describes common design and implementation pitfalls, with guidance on how to avoid them.

## Pitfall: Designing Without Scenarios

**Symptom**: Design that looks good on paper but has obvious issues when you try to use it.

**Example**: Designing "line-based file views" without asking "how does agent know which lines to view?"

**How to avoid**: Always start with concrete scenarios before abstract design.

## Pitfall: Solution-Focused Scenarios

**Symptom**: Scenarios describe API calls, message flows, or implementation details instead of user needs.

**Example - Bad**:
- "Agent sends list_environments request to orchestrator"
- "Orchestrator returns JSON array of environment names"
- "Agent parses response and caches the list"

**Example - Good**:
- "Agent needs to fix type errors in a TypeScript project it's never seen"
- "Human added custom 'docker' environment, agent needs to use it to build containers"
- "Agent is asked to debug a segfault in unfamiliar C code"

**How to avoid**: Describe scenarios as if the system is a black box. Focus on what the user (human, agent, or component) is trying to accomplish, not how the system will accomplish it.

## Pitfall: Not Tracing Implementation

**Symptom**: Design has contradictions or impossible requirements.

**Example**: "Fast operation" that requires re-reading files, "automatic detection" with no mechanism specified.

**How to avoid**: For critical functions, mentally write the implementation before finalizing design.

## Pitfall: Unchecked Assumptions

**Symptom**: Design doesn't match what user actually wants.

**Example**: Assuming environments should use separate working directories, assuming timeouts are needed.

**How to avoid**: Extract assumptions explicitly and confirm them before proceeding.

## Pitfall: Over-Engineering

**Symptom**: Design is complex, has many configuration options, "intelligently" handles edge cases.

**Example**: "Intelligent priority-based screen truncation" instead of simple line limits.

**How to avoid**: For each feature, ask "does benefit outweigh complexity?" Default to simple.

## Pitfall: Ignoring Contradictions

**Symptom**: Design has internally inconsistent requirements.

**Example**: "Keep line ranges fixed" + "auto-update when files change" = views show wrong content after edits.

**How to avoid**: When you find contradictions, dig deeper. They often reveal fundamental design issues.

## Pitfall: Bypassing Existing Abstractions

**Symptom**: When adding new functionality, you hardcode special-case logic instead of using the general-purpose abstractions already in the codebase.

**Also known as**: "Not eating your own dog food"

**Example**: We had a general command processing pipeline (parse commands from text → execute each command → save events). When adding a simulated initial message, we hardcoded specific `send_command()` calls instead of using the existing `parse_commands()` function and execution loop.

**Why this is problematic**:
- **Duplication**: The same logic exists in multiple places
- **Inconsistency**: The parallel code paths can diverge over time
- **Maintenance burden**: Bug fixes and improvements need to be applied in multiple places
- **Missed benefits**: Improvements to the general abstraction don't benefit the special case
- **False complexity**: Suggests the special case genuinely needs different treatment when it doesn't

**How to avoid**:
1. **Before implementing**: Ask "Is there already an abstraction that handles this?"
2. **If yes**: Use it! The abstraction exists for a reason.
3. **If it doesn't quite fit**: First try to extend the abstraction to handle the new case
4. **Only bypass if**: The new case is genuinely a different problem domain

**Related principles**:
- **DRY (Don't Repeat Yourself)**: Avoid duplicating logic
- **Dog-fooding**: Use your own abstractions to validate they work
- **Single Responsibility**: Each piece of logic should live in one place
- **Principle of Least Surprise**: Similar things should work similarly
