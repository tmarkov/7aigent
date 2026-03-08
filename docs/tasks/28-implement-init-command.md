# Task: Implement Init Command

## Description

Replace the outdated `7aigent init` command with an interactive setup that creates proper `.7aigent/` directory structure, prompts for minimal required configuration (endpoint, model, API key env var), and uses the agent to automatically configure project-specific settings (environment detection, customized initial messages, file access patterns).

## Context

- **Component**: `agent/src/main.rs` (handle_init function), `agent/templates/` (template files)
- **Related**: Configuration system (agent/src/config.rs), initial messages (agent/src/initial_messages.rs), directory structure change (commit 93bdd7f), initial messages feature (commit d73a4f6)
- **Motivation**: Current init creates `.7aigent.toml` (old location) with outdated template, doesn't create `init.md`, and doesn't leverage the agent to detect project environment and customize configuration. Users must manually configure everything, leading to suboptimal default setups.

## Scenarios

### Scenario 1: First-time user with new project

**Situation**: Developer installs 7aigent, runs `7aigent init` in their project directory

**Initial state**: No `.7aigent/` directory exists

**Flow**:
1. User runs `7aigent init`
2. Prompted for endpoint (no default)
3. Prompted for model (no default)
4. Prompted for API key env var (default: OPENAI_API_KEY)
5. Files created: `.7aigent/config.toml`, `.7aigent/init.md`, example files
6. Validation passes (API key already set)
7. Agent runs, detects `flake.nix`, updates `shell_prefix = "nix develop --command"`
8. Agent customizes `init.md` with project-specific file exploration
9. Final validation passes

**Success criteria**: Working configuration customized for their project. Ready to run `7aigent "task"`.

### Scenario 2: Re-running init with existing valid config

**Situation**: Developer wants to change model from gpt-4o-mini to gpt-4o

**Workflow**:
```bash
$ 7aigent init
API endpoint: 127.0.0.1:8765/api/v1
Model: llama-3.1
API key environment variable [OPENAI_API_KEY]:

✓ Updated .7aigent/config.toml (preserved shell_prefix, budget, other settings)
✓ init.md unchanged (already valid)
...
```

**Success criteria**: Only `llm.endpoint`, `llm.model`, `llm.api_key_env` updated. All other config preserved (shell_prefix, budget, file patterns, etc.). Existing `init.md` left completely untouched.

### Scenario 3: User with broken config

**Situation**: Developer's `.7aigent/config.toml` has TOML syntax error

**Workflow**:
```bash
$ 7aigent init
API endpoint: https://api.openai.com/v1
Model: gpt-5
API key environment variable [OPENAI_API_KEY]:

✗ Warning: Existing config.toml has syntax errors (invalid TOML)
✓ Created fresh .7aigent/config.toml with provided values
...
```

**Success criteria**: Invalid config replaced with fresh template. User not blocked by broken config.

### Scenario 4: Team member cloning existing project

**Situation**: Developer clones repo with `.7aigent/config.toml.example` and custom `init.md`

**Workflow**:
```bash
# Clone team's repo (has .7aigent/init.md but no .7aigent/config.toml)
$ git clone team/project
$ cd project
$ 7aigent init

API endpoint: https://api.openrouter.ai/v1
Model: anthropic/claude-3.5-sonnet
API key environment variable [OPENAI_API_KEY]: OPENROUTER_API_KEY

✓ Created .7aigent/config.toml
✓ init.md unchanged (valid, preserved team's customization)
...
```

**Success criteria**: Team's custom `init.md` preserved. Personal config created with their settings. Agent still runs but respects existing `init.md`.

### Scenario 5: Missing API key

**Situation**: User hasn't exported API key environment variable

**Workflow**:
```bash
$ 7aigent init

API endpoint: https://api.openai.com/v1
Model: gpt-5
API key environment variable [OPENAI_API_KEY]:

✓ Created .7aigent/config.toml
✓ Created .7aigent/init.md
✓ Created example files
✗ Validating configuration...

Error: Environment variable OPENAI_API_KEY not set

Please export your API key and run init again:
  export OPENAI_API_KEY=your-key-here
  7aigent init
```

**Success criteria**: Clear error message. User knows exactly what to do. Files are created (can be used once key is set).

### Scenario 6: Agent configures project-specific settings

**Situation**: After basic setup, agent runs autonomously to customize configuration

**What agent does**:
1. Checks screen state (sees directory tree, git status)
2. Finds `flake.nix` → updates `[sandbox] shell_prefix = "nix develop --command"` in config.toml
3. Reads README.md, finds architecture in CLAUDE.md → customizes init.md with relevant file views
4. Sees `.env` pattern in tree → adds `[sandbox.files] no_access = ["**/.env"]` in config.toml
5. Explains what was configured and why

**Success criteria**: Project-specific configuration applied without user intervention. Agent uses existing abstractions (reads config.toml.example for syntax, init.md.example for patterns).

## Plan

### Phase 1: Template Preparation

- [ ] Update `agent/templates/config.toml` to match current `.7aigent/config.toml.example`
  - Add `[sandbox]` section with `shell_prefix` option
  - Add `[behavior]` section with `initial_messages` option
  - Add all current options with documentation

- [ ] Create `agent/templates/config.toml.example` (full reference with all options documented)
  - Copy from `.7aigent/config.toml.example`
  - Ensure all comments and examples are complete

- [ ] Create `agent/templates/init.md` (basic starter template)
  - Simple example showing README view and basic exploration
  - Comments explaining purpose

- [ ] Create `agent/templates/init.md.example` (reference example)
  - Copy from `.7aigent/init.md.example`
  - Shows good patterns for project exploration

- [ ] Create `agent/templates/gitignore` (for `.7aigent/` directory)
  - Ignore `sessions/` directory
  - Ignore `next_session_id` file
  - Keep `config.toml` tracked
  - Keep `init.md` tracked

### Phase 2: Interactive Prompts

- [ ] Implement interactive prompt for endpoint
  - Default: `https://api.openai.com/v1`
  - Read input, trim whitespace

- [ ] Implement interactive prompt for model
  - Default: `gpt-4o-mini`
  - Read input, trim whitespace

- [ ] Implement interactive prompt for api_key_env
  - Default: `OPENAI_API_KEY`
  - Read input, trim whitespace

- [ ] If existing `.7aigent/config.toml` is valid, show current values as defaults
  - Parse TOML, extract endpoint/model/api_key_env
  - Display in prompt: `API endpoint [current_value]:`

### Phase 3: File Creation/Update Logic

- [ ] Create `.7aigent/` directory if doesn't exist

- [ ] Handle `config.toml`:
  - If exists and parses as valid TOML:
    - Parse it
    - Update only `llm.endpoint`, `llm.model`, `llm.api_key_env` with user values
    - Preserve all other fields (shell_prefix, budget, file patterns, etc.)
    - Write back with updated values
  - If doesn't exist or parse fails:
    - Create from `agent/templates/config.toml`
    - Fill in user-provided endpoint, model, api_key_env
    - Leave other fields commented/defaults

- [ ] Handle `init.md`:
  - Check if exists and is valid (can be parsed by `load_initial_messages()`)
  - If valid: leave completely untouched
  - If doesn't exist or invalid: write from `agent/templates/init.md`

- [ ] Always write `.7aigent/config.toml.example` from embedded template

- [ ] Always write `.7aigent/init.md.example` from embedded template

- [ ] Ensure `.7aigent/.gitignore` exists
  - If doesn't exist: write from template
  - If exists: leave untouched (user may have customized)

### Phase 4: Validation

- [ ] Implement config validation after file creation
  - Load config using `ConfigLoader::load()`
  - Check `config.validate()` passes
  - Check API key environment variable is set: `std::env::var(api_key_env)`
  - If validation fails, show specific error and exit

### Phase 5: Agent Configuration Task

- [ ] Define agent task instruction (system prompt style explanation)
  - Explain screen state already shows directory/git
  - Reference `.7aigent/config.toml.example` for documentation
  - Reference `.7aigent/init.md.example` for patterns
  - List specific configuration tasks:
    1. Detect environment manager (Nix/Poetry/Conda), set shell_prefix
    2. Customize init.md with project-specific exploration
    3. Optionally set file access patterns

- [ ] Run agent with configuration task
  - Create new session with task string
  - Use existing `handle_new_task` flow
  - Let agent run to completion autonomously

### Phase 6: Final Validation and Output

- [ ] Validate configuration after agent completes
  - Load config again
  - Run validation
  - Show results

- [ ] For v1: Don't auto-retry on validation failure
  - Just report status and exit
  - User can manually fix and re-run

- [ ] Show success message with next steps
  - Confirm project is ready
  - Show example command to try

## Agent Task Instruction

The task string passed to the agent should be:

```
You are running in a freshly initialized 7aigent project with minimal configuration.

Your task is to review this project and update the configuration files to better match the project's needs.

IMPORTANT: The screen state already shows you:
- Directory structure (tree view)
- Git status
- Project directory path

You do NOT need to run ls, git status, or tree commands - this information is already available.

Configuration reference: .7aigent/config.toml.example contains all available options with documentation and examples.

Your job is to:

1. Detect environment manager: Check for flake.nix (Nix), pyproject.toml+poetry.lock (Poetry), environment.yml (Conda), etc.
   - If found, update [sandbox] shell_prefix in .7aigent/config.toml
   - See config.toml.example for syntax and examples

2. Customize initial messages: Review and improve .7aigent/init.md with project-specific exploration
   - Use editor commands to view key files (README, main code, architecture docs)
   - Avoid bash commands that duplicate screen state (ls, git status, tree)
   - Focus on reading actual content that provides context
   - See init.md.example for format and good patterns

3. Review project structure and optionally set [sandbox.files] patterns in config.toml
   - See config.toml.example for read_only, read_write, no_access patterns
   - Only set these if there are clear patterns worth enforcing
   - Example: read_only for .env files, no_access for .git/**

Current configuration: .7aigent/config.toml
Initial messages: .7aigent/init.md

When done, explain what you configured and why.
```

## Notes

- Use `include_str!` to embed templates in binary (consistent with current approach)
- For TOML parsing/updating that preserves comments: consider `toml_edit` crate vs simple `toml` crate (doesn't preserve comments but simpler)
- Validation happens twice: after file creation, and after agent configures
- Agent gets full context from screen state (directory listing, git status) automatically - task instruction should remind it to use screen rather than running ls/git commands
