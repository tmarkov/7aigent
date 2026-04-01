# Implementation Checklist

Quick reference for common task types. For detailed design workflow, see [design-workflow.md](design-workflow.md).

## Task Definition

**When**: You need to define new work to be done.

1. Create file in `docs/tasks/` with descriptive name
2. Write problem description (2-3 sentences: what's wrong or missing)
3. Add context (affected components, constraints, related docs)
4. **Write 3-5 concrete scenarios** (WHAT must work, not HOW)
5. Optionally add initial thoughts (observations, not solutions)
6. Add entry to `docs/tasks/README.md` checklist
7. **Stop** - don't design yet

## Design Task

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
3. Create design document in `docs/` (separate from task file)

## Implementation Task

**CRITICAL: Nix builds use git-tracked files only. Untracked files are invisible to the build, causing false positive "build succeeds" on old code.**

**CRITICAL: Always use `nix build .#packagename` not cargo/pytest directly. The project uses Nix as the build system. Running cargo/pytest directly bypasses formatters, linters, and may test code that won't be in the Nix build.**

1. Read the design doc
2. Use TodoWrite to plan steps
3. **IMMEDIATELY after creating ANY new file: `git add filename`** - Nix won't see untracked files
4. **Run `nix build .#packagename` after EVERY change** - not cargo check/test
5. **Verify build will see new code (choose one approach):**

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
   - `git add` changes IMMEDIATELY after each file creation/modification
   - Run `nix build .#package` after EVERY change - never use cargo/pytest directly
   - Build frequently to catch issues early
   - Tests guide implementation

6. Follow [conventions/general.md](conventions/general.md) strictly

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

## Debug/Fix Task

1. Reproduce the issue
2. Understand root cause (don't just fix symptoms)
3. Check if it reveals a design flaw
4. Fix the root cause
5. Add tests to prevent regression
6. Update docs if needed

## Documentation Task

1. Read related docs for context
2. Use concrete examples
3. Explain why, not just what
4. Link to related docs
5. Keep different concerns in separate files
6. Update task checklists if tasks completed
