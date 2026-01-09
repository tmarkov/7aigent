# Agent Refactor Plan

## Problem Statement

The agent implementation (Phases 1-4) has diverged from the design document. Analysis shows:
- **Type-level complexity is justified** (avoid primitive obsession, "if it compiles it works")
- **API-level complexity is not justified** (SessionManager, multiple save methods, complex constructors)

See:
- `docs/agent-implementation-vs-design.md` - detailed differences
- `docs/agent-complexity-analysis.md` - initial complexity review
- `docs/agent-complexity-addendum.md` - type safety justification

**Goal**: Sync design and implementation, keeping the good parts of both.

---

## Two-Phase Approach

### Phase A: Update Design Document
Update `docs/agent-design.md` to incorporate justified implementation improvements.

### Phase B: Refactor Implementation
Simplify implementation to match the updated design, removing unjustified complexity.

---

## Phase A: Update Design Document

**Goal**: Revise `docs/agent-design.md` to include the good ideas from implementation.

### Checklist

- [ ] **Add type system section**
  - [ ] Document all semantic types (LlmConfigSnapshot, TokenUsage, etc.)
  - [ ] Explain "avoid primitive obsession" principle for agent
  - [ ] Show examples of invalid states made unrepresentable
  - [ ] Document SessionId as proper newtype (not type alias)

- [ ] **Update config structure**
  - [ ] Document specialized config structs (LlmConfig, BudgetConfig, etc.)
  - [ ] Show how namespacing works (config.llm.endpoint vs config.budget.max_cost)
  - [ ] Add ValidatedLlmConfig pattern (validate() method)

- [ ] **Simplify session persistence**
  - [ ] Remove SessionManager as separate component
  - [ ] Session owns its persistence: `session.save_step(&message, &screen)?`
  - [ ] Document single atomic save operation
  - [ ] Show session creation: `Session::create(project_dir, task)?`
  - [ ] Make LlmConfigSnapshot optional, recorded on first LLM call

- [ ] **Update Agent API**
  - [ ] Simple constructor: `Agent::new(session, config, container, llm_client)?`
  - [ ] Constructor loads history/screens (justified optimization)
  - [ ] Document generic LlmClient trait (testability)
  - [ ] Remove SessionManager from Agent struct

- [ ] **Update interaction flow**
  - [ ] Show simplified initialization (no SessionManager)
  - [ ] Document LlmConfig → ValidatedLlmConfig conversion
  - [ ] Show single save_step() in main loop
  - [ ] Update container manager to show build + spawn steps

- [ ] **Review consistency**
  - [ ] Check all code examples compile with new API
  - [ ] Ensure types align throughout document
  - [ ] Verify main loop example is correct
  - [ ] Update architecture diagram if needed

### Success Criteria

- [ ] Design document shows rich type system
- [ ] Design document shows simple APIs
- [ ] All code examples are consistent
- [ ] Design explains *why* types are structured this way

---

## Phase B: Refactor Implementation

**Goal**: Simplify implementation to match updated design.

### Step 1: Strengthen Type Safety

- [ ] **Convert SessionId to proper newtype**
  - [ ] Change `pub type SessionId = Uuid` to `pub struct SessionId(Uuid)`
  - [ ] Add methods: `new()`, `as_uuid()`, `to_string()`
  - [ ] Update all usages
  - [ ] Verify tests pass

- [ ] **Rename OpenAiConfig → ValidatedLlmConfig**
  - [ ] Create ValidatedLlmConfig struct
  - [ ] Add `impl LlmConfig { fn validate(&self) -> Result<ValidatedLlmConfig> }`
  - [ ] Update OpenAiCompatibleClient to use ValidatedLlmConfig
  - [ ] Update all call sites
  - [ ] Verify tests pass

### Step 2: Move Persistence into Session

- [ ] **Add save methods to Session**
  - [ ] `impl Session { fn save_metadata(&self) -> Result<()> }`
  - [ ] `impl Session { fn save_step(&self, message: &Message, screen: &ScreenState) -> Result<()> }`
  - [ ] `impl Session { fn save_cost(&self, step_cost: Decimal) -> Result<()> }`
  - [ ] Implement file I/O logic (move from SessionManager)
  - [ ] Session knows its own directory: `.7aigent/sessions/{id}/`

- [ ] **Add load methods to Session**
  - [ ] `impl Session { fn load(project_dir: &Path, id: SessionId) -> Result<Self> }`
  - [ ] `impl Session { fn load_history(&self) -> Result<Vec<Message>> }`
  - [ ] `impl Session { fn load_screens(&self) -> Result<Vec<ScreenState>> }`
  - [ ] Move file parsing logic from SessionManager

- [ ] **Add creation method to Session**
  - [ ] `impl Session { fn create(project_dir: PathBuf, task: String) -> Result<Self> }`
  - [ ] Don't require LlmConfigSnapshot upfront
  - [ ] Make llm_config: Option<LlmConfigSnapshot>
  - [ ] Add `fn record_llm_config(&mut self, snapshot: LlmConfigSnapshot) -> Result<()>`

### Step 3: Remove SessionManager

- [ ] **Update Agent to not use SessionManager**
  - [ ] Remove `session_manager` field from Agent struct
  - [ ] Update constructor: `Agent::new(session, config, container, llm_client)`
  - [ ] Change `session_manager.load_history()` to `session.load_history()`
  - [ ] Change all save calls to use session methods
  - [ ] Update tests

- [ ] **Delete SessionManager**
  - [ ] Remove `agent/src/session.rs`
  - [ ] Remove from `agent/src/lib.rs` exports
  - [ ] Remove SessionError (move errors to Session impl if needed)
  - [ ] Verify build passes

### Step 4: Simplify Save Operations

- [ ] **Consolidate save operations in Agent loop**
  - [ ] Replace 3-4 save calls with single `session.save_step(&message, &screen)?`
  - [ ] Ensure atomic operation (all files updated or none)
  - [ ] Update error handling
  - [ ] Verify tests pass

- [ ] **Remove redundant update_cost**
  - [ ] Cost is already in session.total_cost
  - [ ] save_step() should update cost.json
  - [ ] Remove separate update_cost() calls

### Step 5: Update Tests

- [ ] **Fix unit tests**
  - [ ] Update session tests (no SessionManager)
  - [ ] Test Session::create(), Session::load()
  - [ ] Test Session::save_step()
  - [ ] Test LlmConfig::validate() → ValidatedLlmConfig

- [ ] **Fix integration tests**
  - [ ] Update agent tests for new constructor
  - [ ] Test session persistence end-to-end
  - [ ] Verify no SessionManager in test code

### Step 6: Update Documentation

- [ ] **Update inline documentation**
  - [ ] Fix doc comments in session.rs
  - [ ] Update examples in module docs
  - [ ] Update agent.rs module documentation

- [ ] **Update task file**
  - [ ] Mark Phase A complete
  - [ ] Mark Phase B complete
  - [ ] Update Phase 5 notes (easier integration now)

### Step 7: Verify Build

- [ ] **Run full build**
  - [ ] `nix build .#agent` passes
  - [ ] All tests pass
  - [ ] rustfmt passes
  - [ ] clippy passes
  - [ ] No warnings

---

## Testing Strategy

### For Each Refactor Step

1. **Make minimal change**
2. **git add** changed files immediately
3. **Run `nix build .#agent`** to verify
4. **Commit** when build passes
5. **Repeat**

### Don't Skip Steps

- Each step should be a separate commit
- Build must pass after each step
- Don't move forward if build fails
- This ensures we can bisect if issues arise

---

## Rollback Plan

If refactor causes unforeseen issues:

1. **Identify problematic commit** with `git bisect`
2. **Revert specific commit** with `git revert`
3. **Create issue** documenting the problem
4. **Defer that refactor** to future work

---

## Success Criteria

### Phase A Complete When:
- [ ] Design document has type system section
- [ ] Design shows simple APIs (no SessionManager)
- [ ] All code examples are consistent
- [ ] Design explains rationale for types

### Phase B Complete When:
- [ ] No SessionManager in codebase
- [ ] Session owns all persistence
- [ ] SessionId is proper newtype
- [ ] ValidatedLlmConfig pattern used
- [ ] Single save_step() operation
- [ ] `nix build .#agent` passes all checks
- [ ] No TODO comments left from refactor

### Overall Success:
- [ ] Design and implementation match
- [ ] Rich type system preserved
- [ ] Simple APIs achieved
- [ ] Tests all pass
- [ ] Ready to complete Phase 5 (CLI integration)

---

## Timeline Estimate

This is **not** a schedule, just a complexity estimate:

- **Phase A** (Design update): ~2-3 hours of focused work
- **Phase B** (Implementation refactor): ~4-6 hours of focused work
  - Step 1: 30min
  - Step 2: 2 hours (most complex - moving persistence)
  - Step 3: 1 hour
  - Step 4: 30min
  - Step 5: 1 hour
  - Step 6: 30min
  - Step 7: 30min

**Total**: ~6-9 hours, but can be done incrementally.

---

## Dependencies

- None! Can start immediately.
- Orchestrator is already complete and won't be affected.
- This is purely agent-internal refactoring.

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Break existing tests | High | Small commits, run tests after each step |
| Lose functionality | High | Comprehensive testing before/after |
| Take too long | Medium | Can pause and resume, each step is atomic |
| New bugs introduced | Medium | Build must pass after each commit |

---

## Next Steps

1. Review this plan with stakeholders
2. Get approval to proceed
3. Create branch: `refactor/simplify-agent-api`
4. Start with Phase A (design update)
5. Commit changes frequently
6. Move to Phase B when design approved
