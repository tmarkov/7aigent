# Agent Implementation vs Design - Key Differences

This document explains the differences between the agent design (docs/agent-design.md) and the actual implementation (agent/src/).

## Overview

The implementation follows the design's overall architecture but differs in several key API details and responsibilities. These differences make it challenging to wire up the main.rs entry point without refactoring.

---

## Major Differences

### 1. Agent Constructor and Lifecycle

**Design** (from docs/agent-design.md, lines 851-938):
```rust
// Design implies this flow:
fn main() {
    let config = load_config()?;
    let session = Session::create(task)?;
    let container = ContainerManager::spawn(...)?;
    let llm_client = create_llm_client(config)?;

    // Agent is created with all components ready
    let agent = Agent::new(session, config, container, llm_client)?;

    // Simple run call
    agent.run().await?;
}
```

**Implementation** (agent/src/agent.rs:39-61):
```rust
pub struct Agent<C: LlmClient> {
    session: Session,
    session_manager: SessionManager,  // Added: owns persistence
    config: Config,
    container: ContainerHandle,
    llm_client: C,
    history: Vec<Message>,             // Added: loaded in constructor
    screens: Vec<ScreenState>,         // Added: loaded in constructor
}

impl<C: LlmClient> Agent<C> {
    pub fn new(
        session: Session,
        session_manager: SessionManager,  // Required parameter
        config: Config,
        container: ContainerHandle,
        llm_client: C,
    ) -> Result<Self> {
        // Loads history and screens from session immediately
        let history = session_manager.load_history(session.id)?;
        let screens = session_manager.load_screens(session.id)?;
        // ...
    }
}
```

**Key Differences**:
- Implementation requires `SessionManager` to be passed in (design doesn't show this)
- Implementation loads history/screens in constructor (design implies lazy loading)
- Implementation stores history/screens in Agent struct (design treats them as external)

---

### 2. Session Creation

**Design** (implied from interaction flow):
```rust
// Design suggests simple session creation
let session = Session::create(task_description)?;
```

**Implementation** (agent/src/session.rs:66):
```rust
pub fn create(&self, task: String, llm_config: LlmConfigSnapshot) -> Result<Session>
```

**Key Differences**:
- Implementation requires `LlmConfigSnapshot` (endpoint + model) to be passed
- This creates a chicken-and-egg problem: you need the config to create the session, but the session stores a snapshot of the config
- Design doesn't specify this configuration snapshot requirement

---

### 3. Container Manager API

**Design** (from interaction flow, line 862):
```rust
// Design suggests:
let container = ContainerManager::spawn(image, project_dir, config)?;
```

**Implementation** (agent/src/container.rs:38-94):
```rust
pub struct ContainerManager;

impl ContainerManager {
    pub fn new() -> Self { Self }

    pub fn build_container_image(&self) -> Result<String> {
        // Builds image using Nix
    }

    pub fn spawn_container(
        &self,
        image: &str,
        project_dir: &Path,
        config: &SandboxConfig,
    ) -> Result<ContainerHandle> {
        // Spawns container, returns handle
    }
}
```

**Key Differences**:
- Implementation separates building the image from spawning the container
- Design implies a single-step spawn operation
- Implementation returns `ContainerHandle` (which the Agent needs)
- You must call `build_container_image()` before `spawn_container()`

---

### 4. LLM Client Instantiation

**Design** (implied):
```rust
let llm_client = create_llm_client(&config.llm)?;
```

**Implementation** (agent/src/llm/openai.rs:55-80):
```rust
pub struct OpenAiConfig {
    pub endpoint: String,
    pub api_key: String,
    pub model: String,
    pub pricing: TokenPricing,
    pub timeout_seconds: u64,
}

impl OpenAiCompatibleClient {
    pub fn new(config: OpenAiConfig) -> Result<Self, LlmError> {
        // Creates HTTP client with headers, timeout, etc.
    }
}
```

**Key Differences**:
- Implementation uses `OpenAiConfig`, not the agent's main `Config` struct
- Need to map from `Config.llm` to `OpenAiConfig`
- Implementation requires `TokenPricing` to be provided (for cost estimation)
- Design doesn't show this mapping step

---

### 5. Agent Run Method Signature

**Design** (from line 895-929):
```rust
loop {
    let messages = build_llm_messages(&session, &config);
    // ... rest of loop

    if commands.is_empty() {
        println!("✓ Task completed!");
        break;
    }
}
```

**Implementation** (agent/src/agent.rs:64):
```rust
pub async fn run(&mut self) -> Result<()>
```

**Key Differences**:
- Implementation's `run()` takes no parameters (task is in session)
- Design shows task as a parameter or from session (ambiguous)
- Implementation mutates self (`&mut self`) and updates internal state
- No separate `resume()` method exists yet (would need to be added)

---

### 6. Session Fields

**Design** (implied minimal session):
```rust
struct Session {
    id: Uuid,
    project_dir: PathBuf,
    total_cost: Decimal,
    messages: Vec<Message>,
    screen_history: Vec<ScreenState>,
}
```

**Implementation** (agent/src/types.rs:29-59):
```rust
pub struct Session {
    pub id: SessionId,
    pub project_dir: PathBuf,
    pub task: String,                      // Added
    pub created_at: DateTime<Utc>,         // Added
    pub updated_at: DateTime<Utc>,         // Added
    pub status: SessionStatus,             // Added
    pub total_cost: Decimal,
    pub token_usage: TokenUsage,           // Added
    pub step_count: usize,                 // Added
    pub llm_config: LlmConfigSnapshot,     // Added
}
```

**Key Differences**:
- Implementation has much richer metadata
- History and screens are NOT stored in the Session struct
- They're stored separately in files and loaded by SessionManager
- Design shows them as part of session (conceptually)

---

### 7. Type System Differences

**Design** uses simpler type names:
- `session.messages` (Vec in struct)
- `session.screen_history` (Vec in struct)

**Implementation** uses more granular types:
- `SessionId` (newtype for Uuid)
- `LlmConfigSnapshot` (separate struct)
- `TokenUsage` (separate struct with breakdown)
- `ScreenState.sections` is `HashMap<String, ScreenSection>`, not `Vec<ScreenSection>`

---

## What This Means for main.rs

To properly implement main.rs, we need to:

### Option A: Match the Implementation
Rewrite main.rs to use the actual implemented APIs:

```rust
async fn execute_task(task: &str, project_dir: &PathBuf, config: Config) -> Result<()> {
    // 1. Create session manager
    let session_manager = SessionManager::new(project_dir.clone())?;

    // 2. Create LLM config snapshot
    let llm_config = LlmConfigSnapshot {
        endpoint: config.llm.endpoint.clone(),
        model: config.llm.model.clone(),
    };

    // 3. Create session
    let session = session_manager.create(task.to_string(), llm_config)?;

    // 4. Build container image
    let container_manager = ContainerManager::new();
    let image = container_manager.build_container_image()?;

    // 5. Spawn container
    let container = container_manager.spawn_container(
        &image,
        project_dir,
        &config.sandbox,
    )?;

    // 6. Create LLM client
    let openai_config = OpenAiConfig {
        endpoint: config.llm.endpoint.clone(),
        api_key: config.llm.api_key.clone()?,
        model: config.llm.model.clone(),
        pricing: config.llm.pricing.clone(),
        timeout_seconds: config.llm.timeout.unwrap_or(60),
    };
    let llm_client = OpenAiCompatibleClient::new(openai_config)?;

    // 7. Create agent
    let mut agent = Agent::new(
        session,
        session_manager,
        config,
        container,
        llm_client,
    )?;

    // 8. Run
    agent.run().await?;

    Ok(())
}
```

### Option B: Update the Design
Update the design document to match the implementation, then implement main.rs against that updated design.

### Option C: Refactor the Implementation
Change the implementation to match the design (significant work, not recommended at this stage).

---

## Recommendation

**Use Option A** - match the implementation. The implementation is working and well-tested. The design document was a planning artifact, and implementation details always differ from plans.

The main challenges are:

1. **Type conversions**: Config → OpenAiConfig, Config.llm → LlmConfigSnapshot
2. **Initialization order**: Must build image before spawning container
3. **Generic handling**: Agent<C: LlmClient> means main.rs needs to know concrete type
4. **Error handling**: Need to handle API key missing from config

These are all solvable, just need careful implementation.

---

## Summary

The implementation is more sophisticated than the design:
- Better separation of concerns (SessionManager owns persistence)
- Richer session metadata
- More explicit type system
- Better error handling

But this makes the integration more complex than the design suggested. The design showed a simplified happy-path, while the implementation handles all the edge cases and real-world requirements.
