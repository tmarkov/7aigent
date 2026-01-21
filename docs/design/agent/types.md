# Agent Type System

**Design Principle**: This project uses **strong typing to make invalid states unrepresentable**. Following the "if it compiles, it works" philosophy, we define semantic types instead of using primitive strings, integers, and tuples.

This is especially important for LLM-generated code, where compile-time checks catch bugs that might otherwise require human review.

## Core Semantic Types

### SessionId - Strong Newtype

**Don't use**: `Uuid` directly (can mix up different ID types)

**Do use**: Proper newtype wrapper
```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct SessionId(Uuid);

impl SessionId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }

    pub fn as_uuid(&self) -> &Uuid {
        &self.0
    }
}
```

**Why**: Prevents passing container IDs where session IDs are expected. Won't compile if you mix them up.

### LlmConfigSnapshot - Session Resume Data

**Purpose**: Records which LLM endpoint/model was used for a session, enabling accurate resume.

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmConfigSnapshot {
    pub endpoint: String,
    pub model: String,
}
```

**Why**:
- Prevents passing `(model, endpoint)` in wrong order (type-safe tuple)
- Documents intent: "This is the LLM config for THIS specific session"
- Makes session resumption type-safe

**Usage**: Recorded on first LLM call, optional in Session struct.

### TokenUsage - Usage Statistics

**Don't use**: `(usize, usize, usize)` tuple or separate variables

**Do use**: Self-documenting struct
```rust
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct TokenUsage {
    pub prompt_tokens: usize,
    pub completion_tokens: usize,
    pub total_tokens: usize,
}

impl TokenUsage {
    pub fn cost(&self, pricing: &TokenPricing) -> Decimal {
        // Calculate cost from usage and pricing
    }
}
```

**Why**:
- Can't accidentally swap prompt and completion tokens
- Self-documenting
- Can add methods for calculations
- Clear which field is which in struct literals

### Command vs CommandResponse - Protocol Direction

```rust
// Agent → Orchestrator
#[derive(Debug, Clone)]
pub struct Command {
    pub env: String,      // e.g., "bash", "python"
    pub command: String,  // Command text
}

// Orchestrator → Agent
#[derive(Debug, Clone)]
pub struct CommandResponse {
    pub output: String,
    pub exit_code: Option<i32>,
}
```

**Why**:
- Makes data flow direction explicit
- Can't accidentally use response where command expected
- Documents the protocol
- Could strengthen further with `EnvironmentName(String)` and `CommandText(String)` newtypes

## Configuration Types

### Specialized Config Structs

**Don't use**: Flat config with all fields mixed together

**Do use**: Namespaced config structs
```rust
pub struct Config {
    pub llm: LlmConfig,
    pub sandbox: SandboxConfig,
    pub budget: BudgetConfig,
    pub behavior: BehaviorConfig,
}

pub struct LlmConfig {
    pub endpoint: String,
    pub model: String,
    pub api_key: Option<String>,
    pub pricing: TokenPricing,
    // ...
}

pub struct BudgetConfig {
    pub max_cost_per_call: Option<Decimal>,
    pub max_session_cost: Option<Decimal>,
    // ...
}
```

**Why**:
- **Clear namespacing**: `config.llm.endpoint` vs `config.budget.max_cost`
- **Type safety**: Can pass just the relevant part: `fn check_budget(budget: &BudgetConfig)`
- **Prevention**: Type system prevents passing budget config to LLM client

### ValidatedLlmConfig - Validated Configuration

**Purpose**: Separates user-facing config (from TOML) from validated internal config.

```rust
// User-facing (from TOML, allows missing api_key)
pub struct LlmConfig {
    pub api_key: Option<String>,  // Optional - might come from env var
    // ...
}

// Internal (validated, api_key required)
pub struct ValidatedLlmConfig {
    pub api_key: String,  // Required!
    // ...
}

impl LlmConfig {
    pub fn validate(&self) -> Result<ValidatedLlmConfig> {
        // Check env vars, apply defaults, ensure required fields present
    }
}
```

**Why**:
- **Parse, don't validate**: Transform into type that can't be invalid
- **Clear boundary**: User config vs internal config
- **Type safety**: Client can't be constructed with missing api_key
- **Single validation point**: All checks in one place

## Generic LLM Client Trait

```rust
#[async_trait]
pub trait LlmClient: Send + Sync {
    async fn complete(&self, request: CompletionRequest)
        -> Result<CompletionResponse, LlmError>;

    fn estimate_cost(&self, request: &CompletionRequest)
        -> Result<Decimal, LlmError>;

    fn count_tokens(&self, message: &str) -> usize;
}

pub struct Agent<C: LlmClient> {
    llm_client: C,
    // ...
}
```

**Why**:
- **Testability**: Can mock LLM for tests without heavy mocking framework
- **Flexibility**: Easy to add Anthropic, Ollama, or other clients later
- **Zero cost**: Monomorphization means no runtime overhead
- **Idiomatic Rust**: Standard pattern for dependency injection

## Benefits Summary

| Type | Prevents | Enables |
|------|----------|---------|
| `SessionId` newtype | Mixing different UUID types | Compile-time ID checking |
| `LlmConfigSnapshot` | Parameter order bugs | Type-safe resume |
| `TokenUsage` struct | Swapping prompt/completion | Self-documenting code |
| `Command`/`Response` | Using response as command | Clear protocol direction |
| Specialized `Config` structs | Passing wrong config to wrong function | Type-guided development |
| `ValidatedLlmConfig` | Constructing client with invalid config | Parse-don't-validate pattern |
| Generic `LlmClient` | Tight coupling to one API | Easy testing and extensibility |

**Core Insight**: The type system does the work, so humans (and LLMs) don't have to remember rules. If it compiles, the types are used correctly.

## Related Documents

- [Overview](overview.md) - High-level purpose and responsibilities
- [Architecture](architecture.md) - Component structure
- [Coding Style](../../reference/coding-style.md) - General coding conventions
