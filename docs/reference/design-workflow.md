# Scenario-Driven Design Workflow

When designing or implementing changes, follow this workflow to ensure designs are practical, simple, and actually solve real problems.

## 1. Identify Components

**Before anything else**: Understand what you're changing and what it affects.

- Which components are involved? (agent, orchestrator, environments, protocols, etc.)
- What are the boundaries and interfaces?
- What existing designs or decisions constrain this change?

**Action**: Read relevant documentation in `./docs/` before proceeding.

## 2. Define Scenarios

**Describe concrete situations that must work**, without prescribing solutions.

- **Who is the "user"?** Could be:
  - End user of the system
  - The agent (user of environments)
  - Another component (e.g., orchestrator using environment protocol)

- **What scenarios must this component support?** Create 3-5 diverse, concrete scenarios:
  - Include the happy path
  - Include edge cases
  - Include scenarios that might break the design
  - Make scenarios different in important ways

### Properties of good scenarios

1. **Goal-oriented, not process-oriented**: Describe what the user wants to accomplish, not what they need to learn or discover along the way
   - Good: "Agent needs to fix type errors in TypeScript project"
   - Bad: "Agent needs to discover TypeScript environment capabilities"

2. **External/black-box perspective**: Describe the situation from outside the system - what goes in (the task/request) and what should come out (successful completion)
   - Good: "Agent is asked to debug a segfault in unfamiliar C code"
   - Bad: "Agent sends debug command to GDB environment and parses output"

3. **Concrete and specific**: Real situations with enough detail to understand context and success criteria
   - Good: "Agent needs to refactor authentication code spread across 5 files"
   - Bad: "Agent needs to work with multiple files"

4. **No built-in solution assumptions**: Don't presume HOW the system solves it, only WHAT needs to work
   - Good: "Agent receives error from unknown command, needs to fix it"
   - Bad: "Agent uses help command to see command syntax"

5. **Testable/Verifiable**: Clear enough that you can determine if it succeeded or failed

6. **Independent**: Each scenario stands alone, not dependent on others or on a specific sequence

7. **Include failure/edge cases**: Not just happy paths - scenarios where things go wrong reveal requirements

### Example good scenarios

- "Agent views function in C file, edits it, sees updated content"
- "Agent edits multi-chapter story, needs to see multiple files simultaneously"
- "External tool modifies file while agent has it open"
- "Agent wants to view function but doesn't know which line it's on"

### Example bad scenarios (and why)

- ❌ "Agent sends view command with line numbers" - describes HOW (solution), not WHAT (goal)
- ❌ "System caches file contents and detects changes via mtime" - describes internal mechanism
- ❌ "Environment returns JSON with file content" - describes implementation detail
- ❌ "Agent discovers available commands" - process-oriented, not goal-oriented
- ❌ "Agent learns command syntax" - learning is never a goal in itself

**Critical**: Write these scenarios BEFORE designing. They reveal requirements that abstract thinking misses. Scenarios should describe situations as if the system is a black box - what goes in (user request), what must come out (successful outcome), not the internals.

## 3. Design for Scenarios

**Walk through each scenario** to understand what's needed.

For each scenario, trace the interaction:
- What commands/APIs are needed?
- What state must be maintained?
- What information must be displayed?
- What can go wrong?

**Extract requirements** from scenarios:
- Common patterns → core features
- Rare cases → defer or simplify
- Contradictions → deeper design issues to resolve

**Make design decisions**:
- Prefer simple over complex
- Prefer explicit over implicit
- Design APIs that use types to prevent misuse
- Document trade-offs (performance vs correctness, simplicity vs features)

**Important**:
- Provide concrete examples, not just abstract descriptions
- Show what the interaction actually looks like
- Include both successful and failure cases

## 4. Verify Implementation Practicality

**Before finalizing the design**: Trace through the implementation.

**Mentally implement critical functions**:
- For each key operation, sketch the implementation logic
- Identify where state is stored and how it's updated
- Trace data flow through the system

**Ask implementation questions**:
- Can this actually be implemented as described?
- Are there contradictions? (e.g., "fast operation" that does file I/O)
- What are the performance characteristics?
- What happens in edge cases?

**Common issues to check**:
- Does it require information that won't be available?
- Does it create circular dependencies?
- Are there race conditions or ordering issues?
- Can error cases be handled cleanly?

**Red flags**:
- "This will be handled automatically" (by what? how?)
- "The system will detect..." (using what mechanism?)
- Contradictions between requirements (fast + always up-to-date + no caching)

**If you find issues**: Don't paper over them. Go back to step 3 and redesign.

## 5. Simplify and Prune

**Question every feature**: Does its benefit outweigh its complexity?

**Simplification strategies**:
- Can this be done with existing features?
- Can we defer this to a future version?
- Can we use a simpler approach that solves 80% of cases?
- Can we eliminate edge case handling by changing constraints?

**Red flags for over-complexity**:
- "The system will intelligently..." (just use a fixed strategy)
- "Configurable per-..." (just pick one good default)
- "Supports both X and Y..." (just pick the better one)
- Multiple layers of indirection
- Complex state machines

**Lean toward simplicity**:
- Fixed limits better than dynamic allocation
- Explicit better than automatic
- Fail fast better than complex recovery
- One obvious way better than multiple options

## 6. Review Against Scenarios

**Go back to your scenarios**: Does the design actually work?

**For each scenario**:
1. Walk through the interaction with your design
2. Identify friction points (agent must do X manually, confusing state, etc.)
3. Identify missing functionality
4. Identify unnecessary complexity

**Ask**:
- What works well?
- What goes wrong?
- Which features are helpful?
- Which features are unnecessary or harmful?
- What assumptions did I make that turned out wrong?

**Grade the design**:
- A: Handles all scenarios elegantly, implementation clear, minimal complexity
- B: Works for scenarios, some friction points, implementable
- C: Works but has significant limitations or complexity
- D: Doesn't actually solve the scenarios or has fundamental flaws

**If not an A**: Identify specific improvements, then iterate.

## 7. Iterate and Refine

**Based on the review**, refine the design:

- Fix issues found in step 6
- Simplify based on what scenarios actually need
- Clarify ambiguities in specification
- Add missing edge case handling
- Remove features that don't pull their weight

**Extract assumptions and confirm them**:
- List any decisions you made based on assumptions
- Ask clarifying questions about trade-offs
- Don't proceed until key assumptions are confirmed

**Document the design**:
- Why decisions were made (rationale)
- What alternatives were considered
- What trade-offs were accepted
- What features were deferred and why

## 8. Implement

Only implement after design is solid.

**Implementation checklist**:
- Follow [docs/reference/conventions/general.md](conventions/general.md) strictly
- Use TodoWrite to track implementation steps
- **CRITICAL: Verify build sees new code first** (see [implementation-checklist.md](implementation-checklist.md))
- Write tests as you go (property-based for public APIs)
- `git add` files immediately after creation
- Build frequently to catch issues early
- Update documentation with any implementation learnings
- Verify work with `nix build .#agent` or `nix build .#orchestrator`
  - Build runs all formatters, linters, and tests automatically
  - Don't run tools directly - Nix ensures everything is checked
  - Verify new files appear in build output (grep for filenames)
