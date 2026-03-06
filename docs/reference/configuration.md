# Configuration Reference

This document provides a comprehensive reference for all configuration options available in 7aigent.

## Configuration Files

**Global configuration:**
- Location: `~/.config/7aigent/config.toml`
- Applied to all projects

**Project configuration:**
- Location: `.7aigent.toml` (in project root)
- Applied to specific project only
- Overrides global configuration

## Configuration Structure

```toml
[llm]
# LLM API configuration

[sandbox]
# Sandbox isolation and security

[sandbox.files]
# File access restrictions (advisory in V1)

[sandbox.network]
# Network configuration (V2 feature)

[sandbox.resources]
# Resource limits

[budget]
# Cost management
```

## LLM Configuration

### Basic Settings

```toml
[llm]
endpoint = "https://api.openai.com/v1"  # Required, no default
model = "gpt-4"                          # Required, no default
api_key_env = "OPENAI_API_KEY"          # Environment variable name
temperature = 0.7                        # Optional, default depends on model
max_tokens = 4096                        # Optional, default depends on model
timeout = 60                             # Request timeout in seconds
```

**Fields:**
- `endpoint`: Base URL for OpenAI-compatible API (string, required)
- `model`: Model identifier (string, required)
- `api_key_env`: Environment variable containing API key (string, default: `"OPENAI_API_KEY"`)
- `temperature`: Sampling temperature 0.0-2.0 (float, optional)
- `max_tokens`: Maximum completion tokens (integer, optional)
- `timeout`: HTTP request timeout in seconds (integer, default: 60)

### Token Pricing

Override default pricing for custom models or updated pricing:

```toml
[llm.pricing.gpt-4]
input_per_1k = 0.03   # Cost per 1000 input tokens (USD)
output_per_1k = 0.06  # Cost per 1000 output tokens (USD)

[llm.pricing.gpt-3.5-turbo]
input_per_1k = 0.001
output_per_1k = 0.002

[llm.pricing.custom-model]
input_per_1k = 0.05
output_per_1k = 0.10
```

**Default pricing included for:**
- GPT-4, GPT-3.5-turbo
- Claude 3 (Opus, Sonnet, Haiku)

### System Prompt Customization

```toml
[llm]
system_prompt_suffix = """
Additional instructions for the agent.

Examples:
- "Explain your reasoning in detail." (beginner mode)
- "Be extremely concise." (expert mode)
- "Always run tests after making changes."
"""
```

## Sandbox Configuration

### Shell Prefix (IMPLEMENTED V1)

Customize the environment by wrapping commands with a shell prefix:

```toml
[sandbox]
shell_prefix = "nix develop --command"
```

**Common use cases:**

**Nix development shell:**
```toml
[sandbox]
shell_prefix = "nix develop --command"
```

**Poetry:**
```toml
[sandbox]
shell_prefix = "poetry run"
```

**Conda:**
```toml
[sandbox]
shell_prefix = "conda run -n myenv"
```

**No customization (default):**
```toml
[sandbox]
# shell_prefix not set - use minimal default environment
```

### File Access Control (Advisory)

File access restrictions are advisory in V1 - communicated to the LLM via system prompt:

```toml
[sandbox.files]
read_only = [
    "tests/**",           # Don't modify tests
    ".env",               # Don't modify secrets
    "package-lock.json",  # Let package manager handle
]

read_write = [
    "src/**",
    "docs/**",
]

no_access = [
    ".git/**",           # Don't touch git internals
    "node_modules/**",   # Don't modify dependencies
]
```

**Pattern syntax:**
- Glob patterns: `**/*.py`, `src/**`, `*.json`
- Single files: `.env`, `Makefile`
- Directories: `.git/**`, `node_modules/**`

### Network Configuration

**V1 - Basic control:**

```toml
[sandbox.network]
disable_network = false  # Default: network enabled
```

**V2 - Domain allowlisting (future):**

```toml
[sandbox.network]
allowed_domains = [
    "api.example.com",   # For testing API integration
    "pypi.org",          # For pip install
    "crates.io",         # For cargo build
]
```

### Resource Limits

**V1 - Manual limits:**
Resource limits are not enforced by the agent. Use systemd-run wrapper:

<bash>
systemd-run --user --scope -p MemoryMax=4G 7aigent "task"
</bash>

**Configuration (documented for V2):**

```toml
[sandbox.resources]
max_memory = "4G"    # Maximum memory (e.g., "4G", "512M")
max_cpus = "2.0"     # CPU quota (e.g., "2.0" = 2 cores)
max_disk = "10G"     # Not enforced, advisory only
```

## Behavior Configuration

Control agent behavior:

```toml
[behavior]
explain_actions = true                    # Agent explains reasoning
ask_before_destructive = false            # Confirm destructive operations
initial_messages = ".7aigent-init.md"     # Path to initial messages file
```

**Fields:**
- `explain_actions`: Whether agent should explain its reasoning (bool, default: `true`)
- `ask_before_destructive`: Prompt before destructive operations like `rm -rf` (bool, default: `false`)
- `initial_messages`: Path to markdown file with initial simulated messages (string, optional)

### Initial Messages

Initial messages are pre-configured simulated assistant messages that populate the agent's context at startup. This allows you to:
- Demonstrate the expected interaction style
- Set a starting point for exploration
- Guide the agent toward relevant project files
- Avoid wasting tokens on generic exploration

**Default behavior:**
- If `initial_messages` not specified: checks for `.7aigent-init.md` in project root
- If file doesn't exist: agent starts with empty context (no initial messages)
- If file exists: parses and executes messages at startup

**File format:**

Create a markdown file with simulated assistant messages separated by horizontal rules (`---`, `***`, `___`, or `~~~`):

```markdown
Let's start by examining the project README:

<editor>
view README.md /^#/ /^#/
</editor>
---
Now check the main source code structure:

<editor>
search "fn main" src/**/*.rs
</editor>
---
Let's look at the configuration:

<bash>
cat config.toml
</bash>
```

Each section is treated as a separate simulated message. Commands are parsed and executed just like normal LLM responses, and their outputs populate the agent's screen state.

**Example `.7aigent-init.md`:**

```markdown
I need to understand this TypeScript project. Let's start with the README:

<editor>
view README.md /^#/ /^#/
</editor>
---
Now let's see the main entry point:

<editor>
view src/index.ts
</editor>
```

**Benefits:**
- **No LLM cost**: Initial messages don't consume LLM tokens
- **Consistent starting point**: Every session starts the same way
- **Project-specific**: Each project can have its own initialization
- **Demonstrative**: Shows the agent how to use commands effectively

**See:** `.7aigent-init.md.example` in the repository for a complete example.

## Budget Configuration

Control LLM API costs:

```toml
[budget]
max_cost_per_session = 10.00   # Abort session if exceeded (USD)
max_cost_per_call = 1.00        # Warn and confirm if exceeded (USD)
warn_threshold = 0.80           # Warn at 80% of session budget
```

**Fields:**
- `max_cost_per_session`: Maximum total cost for one session (float, optional)
  - Agent aborts if exceeded
- `max_cost_per_call`: Maximum cost for single LLM call (float, optional)
  - Agent prompts for confirmation if exceeded
- `warn_threshold`: Warning threshold as fraction of session budget (float, default: 0.80)
  - Agent warns when projected total exceeds this percentage

**Example behavior:**

```
max_cost_per_session = 5.00
warn_threshold = 0.80

At $4.00 total: WARNING (exceeded 80% threshold)
At $5.00 total: ABORT (exceeded session limit)
```

## Complete Example Configurations

### Minimal Configuration

```toml
[llm]
endpoint = "https://api.openai.com/v1"
model = "gpt-4"
# API key from environment variable OPENAI_API_KEY
```

### Development Project

```toml
[llm]
endpoint = "https://api.openai.com/v1"
model = "gpt-4"
temperature = 0.7

[sandbox]
shell_prefix = "nix develop --command"

[sandbox.files]
read_only = ["tests/**", ".env", "flake.lock"]
read_write = ["src/**", "docs/**"]
no_access = [".git/**", "node_modules/**"]

[behavior]
initial_messages = ".7aigent-init.md"  # Load project-specific startup

[budget]
max_cost_per_session = 5.00
max_cost_per_call = 0.50
warn_threshold = 0.80
```

### Content Creation Project

```toml
[llm]
endpoint = "https://api.openai.com/v1"
model = "gpt-4"
system_prompt_suffix = """
Focus on clarity and readability.
Use active voice and simple language.
"""

[sandbox.files]
read_write = ["chapters/**", "docs/**"]
no_access = [".git/**"]

[budget]
max_cost_per_session = 10.00
```

### Data Analysis Project

```toml
[llm]
endpoint = "https://api.openai.com/v1"
model = "gpt-4"

[sandbox]
shell_prefix = "nix develop --command"

[sandbox.files]
read_only = ["data/**"]           # Don't modify raw data
read_write = ["analysis/**", "notebooks/**"]
no_access = [".git/**"]

[budget]
max_cost_per_session = 8.00
```

### Custom LLM Endpoint

```toml
[llm]
endpoint = "http://localhost:11434/v1"  # Ollama
model = "codellama:34b"
api_key_env = "OLLAMA_API_KEY"          # Optional for local

[llm.pricing.codellama:34b]
input_per_1k = 0.0   # Local model, no cost
output_per_1k = 0.0

[budget]
# No budget limits for local model
```

### Secure Project

```toml
[llm]
endpoint = "https://api.openai.com/v1"
model = "gpt-4"

[sandbox]
disable_network = true  # No network access

[sandbox.files]
read_only = ["secrets/**", ".env", "*.key", "*.pem"]
read_write = ["src/**"]
no_access = [".git/**", "secrets/**"]

[budget]
max_cost_per_session = 3.00
max_cost_per_call = 0.30
warn_threshold = 0.75
```

## Configuration Loading

### Precedence

1. Built-in defaults
2. Global config (`~/.config/7aigent/config.toml`)
3. Project config (`.7aigent.toml`)

Later configurations override earlier ones.

### Validation

Agent validates configuration on startup:
- Required fields present (`llm.endpoint`, `llm.model`)
- API key available (from config or environment)
- Numeric values in valid ranges
- File patterns valid glob syntax

### Initialization Command

Create default project configuration:

<bash>
7aigent --init
</bash>

Creates `.7aigent.toml` with commented examples.

## Environment Variables

Configuration can reference environment variables:

**API Key:**
```toml
[llm]
api_key_env = "OPENAI_API_KEY"
```

Agent reads API key from `$OPENAI_API_KEY`.

**Custom environment variables:**
Not directly supported in TOML. Use shell:

<bash>
export CUSTOM_ENDPOINT="https://api.custom.com/v1"
# Then edit config manually to use this value
</bash>

## See Also

- [Agent-Orchestrator Protocol](agent-orchestrator-protocol.md) - Message formats
- [Environment Protocol](environment-protocol.md) - Custom environment implementation
