# Agent Complexity Analysis

This document analyzes whether the added complexity in the agent implementation is justified, following the project's "avoid over-engineering" philosophy.

## Project Philosophy Reminder

From CLAUDE.md:
> **Avoid over-engineering.** Only make changes that are directly requested or clearly necessary. Keep solutions simple and focused.
>
> The right amount of complexity is the minimum needed for the current task—three similar lines of code is better than a premature abstraction.

## Complexity Analysis

### 1. SessionManager as Separate Component

**Added Complexity:**
- Agent must be passed a `SessionManager` instance
- SessionManager owns persistence logic
- Extra level of indirection

**Design Alternative:**
```rust
// Simple: Session saves itself
session.save()?;
```

**Implementation:**
```rust
// Complex: Agent delegates to SessionManager
self.session_manager.save_metadata(&self.session)?;
self.session_manager.append_message(self.session.id, &message)?;
self.session_manager.append_screen(self.session.id, &screen)?;
self.session_manager.update_cost(...)?;
```

**Verdict: UNJUSTIFIED COMPLEXITY** ❌

Why:
- Violates single responsibility: Agent shouldn't need to know about SessionManager
- Could just have `session.save()` that handles its own persistence
- The separate manager doesn't provide clear value
- Makes Agent construction harder (need to pass SessionManager in)

**Better approach:**
```rust
impl Session {
    fn save(&self) -> Result<()> {
        // Saves to .7aigent/sessions/{id}/metadata.json
    }

    fn append_message(&mut self, msg: Message) -> Result<()> {
        // Appends to history.jsonl
    }
}
```

---

### 2. Loading History/Screens in Agent Constructor

**Added Complexity:**
```rust
pub fn new(...) -> Result<Self> {
    let history = session_manager.load_history(session.id)?;
    let screens = session_manager.load_screens(session.id)?;
    // Store in Agent
}
```

**Design Alternative:**
```rust
// Lazy loading when needed
fn build_context(&self) -> Vec<Message> {
    let history = load_history(&self.session)?;
    // ...
}
```

**Verdict: JUSTIFIED** ✅

Why:
- History/screens are used on every loop iteration
- Loading once is more efficient than repeated I/O
- Clear ownership: Agent owns the in-memory state during run
- Failure is immediate (constructor fails if files corrupt)

---

### 3. LlmConfigSnapshot in Session

**Added Complexity:**
```rust
pub struct Session {
    // ... other fields
    pub llm_config: LlmConfigSnapshot,  // endpoint + model
}

// Need to pass this when creating session
session_manager.create(task, llm_config)?;
```

**Design Alternative:**
```rust
// Just create session with task
Session::create(task)?;
```

**Verdict: UNJUSTIFIED COMPLEXITY** ❌

Why:
- This is for session resumption: "which model/endpoint was used?"
- But we don't actually use this for anything yet
- Could defer until resume is implemented
- Creates chicken-and-egg: need config to create session

**Better approach:**
- Don't require it upfront
- Store it when first LLM call is made
- Or make it optional: `Option<LlmConfigSnapshot>`

---

### 4. Separate Message/Screen Storage

**Added Complexity:**
- Three separate file operations per step:
  1. `save_metadata()` - session state
  2. `append_message()` - history.jsonl
  3. `append_screen()` - screens.jsonl

**Design Alternative:**
```rust
// Single save operation
session.save()?;  // Saves everything
```

**Verdict: PARTIALLY JUSTIFIED** ⚠️

Why it's good:
- JSONL format allows incremental appends (don't rewrite whole file)
- Can inspect history/screens without parsing session
- Scales better for long sessions

Why it's bad:
- Three I/O operations per step (performance)
- More failure points (what if one fails?)
- Agent has to remember to call all three

**Better approach:**
```rust
// Agent just calls one method
self.session.save_step(&message, &screen)?;

// Session handles the three-file coordination internally
```

---

### 5. Agent Stores SessionManager

**Added Complexity:**
```rust
pub struct Agent<C: LlmClient> {
    session: Session,
    session_manager: SessionManager,  // Why keep this?
    // ...
}
```

**Design Alternative:**
```rust
// Don't store manager, just use it at start/end
pub fn new(session: Session, ...) -> Result<Self> {
    // No session_manager stored
}

pub async fn run(&mut self) -> Result<()> {
    loop {
        // ...
    }

    // Save at end
    self.session.save()?;
}
```

**Verdict: UNJUSTIFIED COMPLEXITY** ❌

Why:
- SessionManager is stateless (just holds project_dir)
- Agent doesn't need it during the loop
- Could reconstruct when needed: `SessionManager::new(self.session.project_dir)`
- Or better: Session knows how to save itself

---

### 6. Generic LlmClient Trait

**Added Complexity:**
```rust
pub struct Agent<C: LlmClient> {
    llm_client: C,
    // ...
}
```

**Design Alternative:**
```rust
pub struct Agent {
    llm_client: OpenAiCompatibleClient,  // Concrete type
    // ...
}
```

**Verdict: JUSTIFIED** ✅

Why:
- Testability: Can mock LLM for tests
- Future flexibility: Could add Anthropic client, Ollama client, etc.
- Not premature: We already have use case (testing)
- Generic is idiomatic Rust for this pattern
- No runtime cost (monomorphization)

---

### 7. Separate update_cost() Method

**Added Complexity:**
```rust
// After updating session fields
self.session_manager.update_cost(
    self.session.id,
    self.session.total_cost,
    self.session.token_usage,
    Some((self.session.step_count, response.cost)),
)?;
```

**Design Alternative:**
```rust
// Just part of save_metadata()
self.session.save_metadata()?;  // Includes cost
```

**Verdict: UNJUSTIFIED COMPLEXITY** ❌

Why:
- Cost is already in `self.session.total_cost`
- Why separate method?
- Appears to update `cost.json` separate from `metadata.json`
- This duplication serves no clear purpose

**Looking at the method signature**, it even takes `total_cost` as parameter when it's already in the session! This is redundant.

---

## Summary

| Feature | Justified? | Reason |
|---------|-----------|---------|
| SessionManager separation | ❌ | Adds indirection without value |
| Loading history/screens in constructor | ✅ | Performance, clear ownership |
| LlmConfigSnapshot required upfront | ❌ | Not used yet, creates coupling |
| Three-file storage | ⚠️ | Good idea, wrong API |
| Agent stores SessionManager | ❌ | Stateless object, not needed |
| Generic LlmClient | ✅ | Testability, flexibility |
| Separate update_cost() | ❌ | Redundant with save_metadata() |

**Overall Assessment: 2/7 justified, 4/7 unjustified, 1/7 partially justified**

---

## Recommendations

### 1. Simplify Session Persistence (High Priority)

**Current:**
```rust
self.session_manager.save_metadata(&self.session)?;
self.session_manager.append_message(self.session.id, &message)?;
self.session_manager.append_screen(self.session.id, &screen)?;
self.session_manager.update_cost(...)?;
```

**Better:**
```rust
self.session.save_step(&message, &screen)?;
```

Session should know how to persist itself. Agent shouldn't care about files.

### 2. Remove SessionManager from Agent (High Priority)

**Current:**
```rust
pub struct Agent<C: LlmClient> {
    session: Session,
    session_manager: SessionManager,  // Remove this
    // ...
}
```

**Better:**
Session handles its own persistence. No manager needed.

### 3. Make LlmConfigSnapshot Optional (Medium Priority)

**Current:**
```rust
session_manager.create(task, llm_config)?;  // Must provide
```

**Better:**
```rust
session = Session::create(project_dir, task)?;
// Later, when first LLM call:
session.record_llm_config(endpoint, model);
```

### 4. Single save() Method (Medium Priority)

Eliminate separate `save_metadata()`, `update_cost()`, `append_message()`, `append_screen()`.

Just have `session.save_step()` that does it all atomically.

---

## Root Cause

The implementation followed a pattern common in object-oriented design:
- Separate manager objects
- Dependency injection
- Multiple small methods

But Rust prefers:
- Data owns its behavior
- Simple, obvious APIs
- Fewer indirections

**The design document was simpler because it followed Rust idioms.** The implementation added OOP-style complexity that doesn't fit the language.

---

## Action Items

1. **Refactor Session to own its persistence**
   - Move SessionManager methods into impl Session
   - Eliminate SessionManager as a separate type
   - Session::create(), session.save_step(), session.load()

2. **Simplify Agent constructor**
   - Don't require SessionManager
   - Don't require LlmConfigSnapshot upfront
   - Make it: `Agent::new(session, config, container, llm_client)`

3. **Update main.rs to use simplified API**
   - Will be much easier once refactored

4. **Update task doc**
   - Note that Phase 1-4 need simplification
   - Before implementing Phase 5 fully

This aligns with the project philosophy: **Keep solutions simple and focused.**
