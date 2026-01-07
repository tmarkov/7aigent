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

## Project Organization

Understanding where different types of work belong:

### Documentation (docs/)

`docs/` contains reference documentation, design decisions, and architecture:
- **Purpose**: Explains HOW things work and WHY decisions were made
- **Audience**: Anyone trying to understand the system
- **Lifecycle**: Long-term reference material
- **Examples**: `docs/orchestrator.md`, `docs/coding-style.md`, `docs/technology.md`

### Tasks (docs/tasks/)

`docs/tasks/` contains task definitions and work tracking:
- **Purpose**: Describes WHAT needs to be done
- **Audience**: Whoever is doing the work (human or LLM)
- **Lifecycle**: Active during work, kept as historical record when completed
- **Examples**: `docs/tasks/implement-bash-environment.md`, `docs/tasks/improve-tool-discoverability.md`
- **Format**: Each task has description, scenarios, plan checklist, and design notes

**Key distinction**: Documentation explains existing systems. Tasks describe work to be done.

---

## Task Lifecycle

Work proceeds in three distinct phases:

### 1. Task Definition

**Goal**: Clearly define the problem without jumping to solutions.

**Outputs**:
- New file in `docs/tasks/` (e.g., `docs/tasks/fix-memory-leak.md`)
- Entry in `docs/tasks/README.md` checklist
- Problem description and context
- 3-5 concrete scenarios (WHAT needs to work, not HOW)
- Initial thoughts on constraints (optional)

**Stop here** - don't design yet. Creating a task file is about articulating the problem clearly, not solving it.

**Example task file structure**:
```markdown
# Task: Fix Memory Leak in Python Environment

## Problem
Python environment consumes unbounded memory over long sessions...

## Context
- Component: orchestrator/environments/python.py
- Related: Issue #42, Performance requirements in docs/orchestrator.md

## Scenarios
1. Agent runs 1000 small Python commands - memory usage should stay bounded
2. Agent creates large DataFrame, then deletes it - memory should be freed
3. Agent imports heavy library - memory increase is one-time, not cumulative

## Initial Thoughts
- Likely in variable tracking or REPL output buffering
- Need to profile to confirm root cause
```

### 2. Design

**Goal**: Work through the 8-step scenario-driven design workflow to create a solution.

**When**: After task is defined and you're ready to start solving it.

**Outputs**:
- Design decisions and rationale
- Concrete examples of the solution
- Trade-offs and alternatives considered
- Updated task file with design section, OR separate design doc in `docs/`

**Process**: Follow the full "Scenario-Driven Design Workflow" below.

### 3. Implementation

**Goal**: Write the code, tests, and update documentation.

**When**: After design is complete and reviewed.

**Outputs**:
- Working code that passes all checks (`nix build` succeeds)
- Comprehensive tests
- Updated documentation if design changed during implementation
- Checked-off items in task file's plan checklist

**Process**: Follow the "Implementation Task" checklist in Quick Reference below.

---

## Scenario-Driven Design Workflow

When designing or implementing changes, follow this workflow to ensure designs are practical, simple, and actually solve real problems.

### 1. Identify Components

**Before anything else**: Understand what you're changing and what it affects.

- Which components are involved? (agent, orchestrator, environments, protocols, etc.)
- What are the boundaries and interfaces?
- What existing designs or decisions constrain this change?

**Action**: Read relevant documentation in `./docs/` before proceeding.

### 2. Define Scenarios

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

**Good scenarios describe WHAT needs to happen:**
- "Agent views function in C file, edits it, sees updated content"
- "Agent edits multi-chapter story, needs to see multiple files simultaneously"
- "External tool modifies file while agent has it open"
- "Agent wants to view function but doesn't know which line it's on"

**Bad scenarios describe HOW (the solution):**
- ❌ "Agent sends view command with line numbers"
- ❌ "System caches file contents and detects changes via mtime"
- ❌ "Environment returns JSON with file content"

**Critical**: Write these scenarios BEFORE designing. They reveal requirements that abstract thinking misses. Scenarios should describe situations as if the system is a black box - what goes in (user request), what must come out (successful outcome), not the internals.

### 3. Design for Scenarios

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

### 6. Review Against Scenarios

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
- **CRITICAL: Verify build sees new code first** (see Implementation Task below)
  - Create test file that imports new module
  - `git add` test file
  - Verify build FAILS with ImportError
  - If build succeeds, new test not in build - STOP and investigate
- Write tests as you go (property-based for public APIs)
- `git add` files immediately after creation
- Build frequently to catch issues early
- Update documentation with any implementation learnings
- Verify work with `nix build .#agent` or `nix build .#orchestrator`
  - Build runs all formatters, linters, and tests automatically
  - Don't run tools directly - Nix ensures everything is checked
  - Verify new files appear in build output (grep for filenames)

---

## Quick Reference for Common Tasks

### Task Definition

**When**: You need to define new work to be done.

1. Create file in `docs/tasks/` with descriptive name
2. Write problem description (2-3 sentences: what's wrong or missing)
3. Add context (affected components, constraints, related docs)
4. **Write 3-5 concrete scenarios** (WHAT must work, not HOW)
5. Optionally add initial thoughts (observations, not solutions)
6. Add entry to `docs/tasks/README.md` checklist
7. **Stop** - don't design yet

### Design Task

**When**: You're ready to solve a defined task.

1. Read task file and related docs
2. Follow the 8-step Scenario-Driven Design Workflow:
   - Identify components
   - Review scenarios (already in task file)
   - Design for those scenarios
   - **Mentally implement critical functions**
   - Simplify and prune
   - Review against scenarios
   - Iterate until design is grade A or B
   - Document with rationale
3. Add design section to task file or create separate design doc

### Implementation Task

**CRITICAL: Nix builds use git-tracked files only. Untracked files are invisible to the build, causing false positive "build succeeds" on old code.**

1. Read the design doc
2. Use TodoWrite to plan steps
3. **Verify build will see new code (choose one approach):**

   **Option A - Import Test (recommended for new modules):**
   ```bash
   # Create test file that imports new module
   cat > tests/test_new_module.py << 'EOF'
   from package.new_module import NewClass  # Will fail - doesn't exist yet

   def test_placeholder():
       assert True
   EOF

   # Add to git and verify build FAILS
   git add tests/test_new_module.py
   nix build .#package 2>&1 | tee /dev/tty | grep -q "ModuleNotFoundError.*new_module"

   # If build succeeds, STOP - test file not in build!
   # If build fails with ImportError - GOOD, proceed to step 4
   ```

   **Option B - Test Count Verification:**
   ```bash
   # Note current test count
   BEFORE=$(nix build .#package 2>&1 | grep -oP '\d+(?= passed)' | tail -1)

   # Create test file with simple test
   # (write test file here)

   # Add to git and verify count increases
   git add tests/test_new_module.py
   AFTER=$(nix build .#package 2>&1 | grep -oP '\d+(?= passed|failed)' | head -1)

   # If AFTER <= BEFORE, STOP - test not in build!
   ```

   **Option C - Grep Test Output:**
   ```bash
   # Create test file
   # (write test file here)

   # Add to git and verify it appears in output
   git add tests/test_new_module.py
   nix build .#package 2>&1 | grep -q "test_new_module.py"

   # If not found, STOP - test not in build!
   ```

4. **Create minimal module to fix import:**
   ```bash
   # Create skeleton module
   cat > package/new_module.py << 'EOF'
   """New module."""

   class NewClass:
       pass
   EOF

   # Add to git immediately
   git add package/new_module.py

   # Build should now pass (or fail on different issue)
   nix build .#package
   ```

5. **Implement incrementally:**
   - Write code
   - `git add` changes after each significant addition
   - Build frequently to catch issues early
   - Tests guide implementation

6. Follow coding-style.md strictly

7. Write tests as you go (property-based for public APIs)

8. Update docs if implementation reveals issues

9. **Final verification:**
   ```bash
   # Clean build
   nix build .#package

   # Verify new files in build output
   nix build .#package 2>&1 | grep "adding.*new_module"

   # All checks must pass:
   # - black, isort, ruff (formatters/linters)
   # - pytest (all tests including new ones)
   ```

**Why this process:**
- Catches ALL "new code not in build" issues (git, config, import paths)
- Fails fast - know immediately if setup is wrong
- Low overhead - one extra build cycle
- Prevents wasted work on code that won't be tested

**Key principle:** Build must fail first, then succeed. If build succeeds immediately with new test imports, something is wrong.

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
6. Update task checklists if tasks completed

---

## Common Pitfalls and How to Avoid Them

### Pitfall: Designing Without Scenarios

**Symptom**: Design that looks good on paper but has obvious issues when you try to use it.

**Example**: Designing "line-based file views" without asking "how does agent know which lines to view?"

**How to avoid**: Always start with concrete scenarios before abstract design.

### Pitfall: Solution-Focused Scenarios

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

1. Go back to scenarios - what do they actually need?
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
- You follow the scenario-driven workflow
