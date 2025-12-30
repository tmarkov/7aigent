# Instructions for LLM Agents

When working on this project, follow these guidelines:

## Project Philosophy

**This project is designed for LLM-driven development.** The entire codebase will be written by LLMs, with minimal human review. This shapes our core principles:

1. **Strong static analysis and type safety**: We rely on compilers and type checkers to catch errors, not human code review
2. **"If it compiles, it works"**: Use type systems to make invalid states unrepresentable
3. **Comprehensive tooling**: Formatters and linters enforce conventions automatically
4. **Explicit over implicit**: Code should be clear and obvious, not clever
5. **Test thoroughly**: Property-based testing ensures correctness across input space

See [docs/coding-style.md](docs/coding-style.md) for detailed conventions that support these principles.

## Build System

**This project uses Nix for reproducible builds and automated verification.**

All code verification (formatting, linting, testing) is integrated into the Nix build:

```bash
# Build the agent (Rust) with all checks
nix build .#agent
# Runs: rustfmt check, clippy, cargo test

# Build the orchestrator (Python) with all checks
nix build .#orchestrator
# Runs: black check, isort check, ruff check, pytest

# Development shell with all tools
nix develop
```

**Important**: Don't run formatters and linters directly during implementation. Instead:
- Make your changes
- Run `nix build .#<package>` to verify everything
- The build will fail if any check fails
- This ensures you never forget a step

This approach guarantees that if the build succeeds, all code meets quality standards.

---

## User-Story Driven Design Workflow

When designing or implementing changes, follow this workflow to ensure designs are practical, simple, and actually solve real problems.

### 1. Identify Components

**Before anything else**: Understand what you're changing and what it affects.

- Which components are involved? (agent, orchestrator, environments, protocols, etc.)
- What are the boundaries and interfaces?
- What existing designs or decisions constrain this change?

**Action**: Read relevant documentation in `./docs/` before proceeding.

### 2. Define User Stories

**Think from the user's perspective** before designing anything.

- **Who is the "user"?** Could be:
  - End user of the system
  - The agent (user of environments)
  - Another component (e.g., orchestrator using environment protocol)

- **What scenarios must this component support?** Create 3-5 diverse, concrete scenarios:
  - Include the happy path
  - Include edge cases
  - Include scenarios that might break the design
  - Make scenarios different in important ways

**Example**: For editor environment, scenarios include:
- Agent views function in C file, edits it, sees updated content
- Agent edits multi-chapter story, needs to see multiple files simultaneously
- External tool modifies file while agent has it open
- Agent wants to view function but doesn't know which line it's on

**Critical**: Write these scenarios BEFORE designing. They reveal requirements that abstract thinking misses.

### 3. Design for User Stories

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

### 4. Verify Implementation Practicality

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

### 5. Simplify and Prune

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

### 6. Review Against User Stories

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

### 7. Iterate and Refine

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

### 8. Implement

Only implement after design is solid.

**Implementation checklist**:
- Follow [docs/coding-style.md](docs/coding-style.md) strictly
- Use TodoWrite to track implementation steps
- Write tests as you go (property-based for public APIs)
- Update documentation with any implementation learnings
- Verify work with `nix build .#agent` or `nix build .#orchestrator`
  - Build runs all formatters, linters, and tests automatically
  - Don't run tools directly - Nix ensures everything is checked

---

## Quick Reference for Common Tasks

### Design Task

1. Read existing docs
2. **Write 3-5 concrete usage scenarios first**
3. Design for those scenarios
4. **Mentally implement critical functions**
5. Simplify and prune
6. Review against scenarios
7. Iterate until design is grade A or B
8. Document with rationale

### Implementation Task

1. Read the design doc
2. Use TodoWrite to plan steps
3. Follow coding-style.md
4. Test as you go
5. Update docs if implementation reveals issues
6. Verify with Nix build: `nix build .#agent` or `nix build .#orchestrator`
   - This automatically runs all formatters, linters, and tests
   - Build will fail if any check fails
   - Don't run formatters/linters directly - let Nix handle it

### Debug/Fix Task

1. Reproduce the issue
2. Understand root cause (don't just fix symptoms)
3. Check if it reveals a design flaw
4. Fix the root cause
5. Add tests to prevent regression
6. Update docs if needed

### Documentation Task

1. Read related docs for context
2. Use concrete examples
3. Explain why, not just what
4. Link to related docs
5. Keep different concerns in separate files
6. Update planning checklists if tasks completed

---

## Common Pitfalls and How to Avoid Them

### Pitfall: Designing Without User Stories

**Symptom**: Design that looks good on paper but has obvious issues when you try to use it.

**Example**: Designing "line-based file views" without asking "how does agent know which lines to view?"

**How to avoid**: Always start with concrete scenarios before abstract design.

### Pitfall: Not Tracing Implementation

**Symptom**: Design has contradictions or impossible requirements.

**Example**: "Fast operation" that requires re-reading files, "automatic detection" with no mechanism specified.

**How to avoid**: For critical functions, mentally write the implementation before finalizing design.

### Pitfall: Unchecked Assumptions

**Symptom**: Design doesn't match what user actually wants.

**Example**: Assuming environments should use separate working directories, assuming timeouts are needed.

**How to avoid**: Extract assumptions explicitly and confirm them before proceeding.

### Pitfall: Over-Engineering

**Symptom**: Design is complex, has many configuration options, "intelligently" handles edge cases.

**Example**: "Intelligent priority-based screen truncation" instead of simple line limits.

**How to avoid**: For each feature, ask "does benefit outweigh complexity?" Default to simple.

### Pitfall: Ignoring Contradictions

**Symptom**: Design has internally inconsistent requirements.

**Example**: "Keep line ranges fixed" + "auto-update when files change" = views show wrong content after edits.

**How to avoid**: When you find contradictions, dig deeper. They often reveal fundamental design issues.

---

## When You're Stuck

### If Unsure About Requirements

1. Review related documentation in ./docs/
2. Write example scenarios to clarify what's needed
3. Ask user with specific options and trade-offs
4. Don't guess - wrong assumptions waste more time than questions

### If Design Seems Too Complex

1. Go back to user stories - what do they actually need?
2. Question every feature - can it be removed or simplified?
3. Look for simpler approaches that solve 80% of cases
4. Consider deferring features to future version
5. Ask if trade-off (less features, more simplicity) is acceptable

### If Finding Implementation Issues

1. Don't paper over them - go back and redesign
2. The implementation issues are telling you something about the design
3. Simpler design → simpler implementation
4. If something feels impossible, it probably is

### If Design Review Reveals Problems

1. This is good - better to find now than during implementation
2. Grade the current design honestly
3. Identify specific improvements
4. Iterate - good design takes multiple passes
5. Ask for feedback on refined design

---

## Success Criteria

### For Design Work

You're doing well if:
- **Started with concrete scenarios** before designing
- **Mentally traced implementation** of critical paths
- **Identified and confirmed assumptions** early
- **Design is simple** - pruned unnecessary features
- **Scenarios work well** with your design
- **Contradictions resolved** or acknowledged as conscious trade-offs
- **Rationale documented** - why decisions were made
- **Grade is A or B** when reviewing against scenarios

### For Implementation Work

You're doing well if:
- Code compiles/type-checks on first try (or after minimal fixes)
- `nix build .#agent` or `nix build .#orchestrator` succeeds
  - This verifies formatters (rustfmt, black, isort) pass
  - This verifies linters (clippy, ruff) pass
  - This verifies all tests pass
- Tests are comprehensive and use property-based testing where applicable
- Documentation is clear and up-to-date
- You followed coding-style.md strictly
- You found no surprises (design was accurate)

### For Overall Collaboration

You're doing well if:
- You ask questions when assumptions are unclear
- You present options with trade-offs, not unilateral decisions
- You iterate based on feedback
- You're honest about design quality (not defensive)
- You learn from reviews and improve next time
- You follow the user-story driven workflow
