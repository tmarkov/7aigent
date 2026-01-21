# Agent Sandboxing and Security

The agent uses bubblewrap to isolate the orchestrator and provide security boundaries.

See [Sandbox Design](../sandbox/) for complete details on the sandbox implementation.

## Security Model

The agent is responsible for:
- Spawning orchestrator in bubblewrap sandbox
- Configuring filesystem isolation (project directory only)
- Enforcing network isolation (no network by default)
- Setting resource limits (memory, CPU)
- Managing secret detection and handling

The orchestrator runs **inside the sandbox** with limited access.

## File Access Control

**Initial version**: Advisory only (told to LLM in system prompt).

**Configuration**:
```toml
[sandbox.files]
read_only = [
    "tests/**",           # Don't modify tests
    ".env",               # Don't modify secrets
    "package-lock.json",  # Let package manager handle this
]
read_write = [
    "src/**",
    "docs/**",
]
no_access = [
    ".git/**",            # Don't touch git internals
    "node_modules/**",
]
```

**System prompt injection**:
```
You have access to the project directory at /workspace.

IMPORTANT file access restrictions:
- DO NOT modify these files: tests/**, .env, package-lock.json
- You CAN modify: src/**, docs/**
- DO NOT access: .git/**, node_modules/**

Violating these restrictions may cause the session to fail.
```

**Future enhancement** (V2): Use OverlayFS for enforcement.

## Network Isolation

**Default**: No network access in sandbox.

**Configuration**:
```toml
[sandbox.network]
allowed_domains = [
    "api.example.com",   # For testing API integration
    "pypi.org",          # For pip install
]
```

**Note**: This is a planned feature. Current implementation has no network access.

## Secret Management

**Problem**: Agent needs to use secrets (.env, API keys) but shouldn't send them to LLM.

**Solution**:
1. Secrets stay in project directory (accessible to orchestrator)
2. Agent detects secret files and adds warning to system prompt
3. Agent filters responses to avoid echoing secrets

**Detection** (heuristic):
- Files named: `.env`, `*.key`, `*.pem`, `secrets.*`, `credentials.*`
- Files containing: `API_KEY=`, `SECRET=`, `PASSWORD=`

**System prompt addition**:
```
The project contains secret files (.env, api_keys.txt).
You can USE these secrets in commands, but:
- NEVER echo secret values in your responses
- NEVER read and display secret file contents
- NEVER include secrets in commit messages
```

**Response filtering**:
```rust
fn filter_secrets(text: &str, secret_patterns: &[Regex]) -> String {
    let mut filtered = text.to_string();
    for pattern in secret_patterns {
        filtered = pattern.replace_all(&filtered, "[REDACTED]").to_string();
    }
    filtered
}
```

## Resource Limits

**Configuration**:
```toml
[sandbox.resources]
max_memory = "4G"
max_cpus = "2.0"
max_disk = "10G"  # Not enforced by bubblewrap, advisory only
```

**Enforcement**: Via bubblewrap and cgroup settings.

## Threat Model

**Protects against**:
- Accidental modification of critical files
- Network exfiltration of data
- Resource exhaustion (runaway processes)
- Accessing host system files

**Does NOT protect against**:
- Malicious LLM responses (assumes LLM is trusted)
- Bugs in bubblewrap itself
- Kernel vulnerabilities

## Related Documents

- [Sandbox Design](../sandbox/) - Complete sandbox architecture
- [Sandbox Security](../sandbox/security.md) - Detailed security model
- [Sandbox Customization](../sandbox/customization.md) - Adding tools to sandbox
