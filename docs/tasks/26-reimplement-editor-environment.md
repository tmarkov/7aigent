# Task: Reimplement Editor Environment with Query-Based Pipeline System

## Description

Replace the current dual-pattern editor with a query-based pipeline system that uses procedural views instead of snapshots. All views are generated from queries that re-execute on screen refresh, ensuring screens always show current content even as files change. This eliminates stale view bugs and enables powerful workflows like hypothesis testing during debugging and multi-file refactoring.

## Context

- **Component**: `orchestrator/environments/editor/` (complete rewrite), `orchestrator/environments/editor.py` (refactor)
- **Related**: Current editor implementation (task 07), editor redesign proposal (docs/design/orchestrator/editor-environment-v2.md)
- **Motivation**: Current editor uses snapshot-based views that become stale when files change. Analysis of 8 real AI coding sessions revealed patterns that the current design doesn't support well. The redesign uses procedural views (queries) that auto-update, enabling natural workflows for architecture understanding, debugging, refactoring, and reference management.

## Scenarios

### Scenario 1: Architecture Understanding

**Situation**: Agent needs to understand secrets management architecture across multiple files

**Workflow**:
```xml
<!-- Agent reads docs first (Read tool) -->

<!-- Discover implementation patterns -->
<editor>
  peek /options\.sops|sops-nix/ in modules/secrets/default.nix | while-indent | limit 5
  peek /generate(Secret|Key|Password)/ in lib/generation.nix | while-indent | limit 8
  peek /credentials.*secret|systemd.*secret/ in modules/containers/default.nix | context 5 | limit 10
</editor>
<!-- Returns one unified summary covering architecture: option definitions → generation functions → integration -->
```

**Success criteria**:
- All three queries execute successfully within 300 line peek limit
- One comprehensive summary explaining the architecture
- Transient (no persistent screen clutter)
- Pattern matching works across Nix syntax

### Scenario 2: Deep Work on Complex File

**Situation**: Agent editing networking config file (320 lines) with 4 distinct sections

**Workflow**:
```xml
<!-- Discover structure -->
<editor>
  peek /^  [a-z_]+\s*=/ in modules/networking/default.nix
</editor>
<!-- Shows all top-level attributes -->

<!-- Create persistent views for all sections -->
<editor>
  view dns /# DNS configuration|services\.dnsmasq/ in modules/networking/default.nix | until-blank
  view firewall /# Firewall|networking\.firewall/ in modules/networking/default.nix | until-blank
  view vpn /# VPN|services\.openvpn/ in modules/networking/default.nix | until-blank
  view proxy /# Proxy|services\.squid/ in modules/networking/default.nix | until-blank
</editor>
<!-- All 4 sections visible on screen (~177 lines total) -->

<!-- Edit any section -->
<editor>
  edit modules/networking/default.nix 52-58
  # DNS changes
  ...
</editor>
<!-- Screen regenerates, all 4 views show updated content -->
```

**Success criteria**:
- Can view multiple sections of same file simultaneously
- Total lines (177) under 3000 limit
- After edit, all views show current content (no stale views)
- Pattern matching finds section headers and attributes
- `until-blank` expands correctly for Nix structure

### Scenario 3: Debugging with Hypothesis Testing

**Situation**: Test failure at line 155, agent forms hypotheses to find root cause

**Workflow**:
```xml
<!-- Inspect failure location -->
<editor>
  peek line 155 in modules/containers/default.nix | context 10
</editor>
<!-- Shows line 155 with context -->

<!-- Hypothesis 1: Secret binding issue -->
<editor>
  view h1_binding /LoadCredential|credentials/ in modules/containers/default.nix | context 8
  view h1_secrets /sops\.secrets\.\w+\.path/ in modules/secrets/default.nix | context 8
</editor>
<!-- Both files visible, agent compares... hypothesis disproven -->

<editor>
  close pattern "h1_*"
</editor>
<!-- Clean slate -->

<!-- Hypothesis 2: Permission issue -->
<editor>
  view h2_perms /DynamicUser|User=|user.*container/ in modules/containers/default.nix | context 10
  view h2_secret_mode /mode|owner|group/ in modules/secrets/default.nix | context 5
</editor>
<!-- Agent spots mismatch: DynamicUser=true but secrets owned by root! -->

<!-- Fix -->
<editor>
  edit modules/secrets/default.nix 78-82
  sops.secrets.container_api_key = {
    owner = config.systemd.services.container.serviceConfig.User;  # FIX
    ...
  };
</editor>
<!-- h2_secret_mode view updates to show fix -->
```

**Success criteria**:
- `peek line 155` works (only in peek, not view)
- Can create labeled views for hypotheses
- `close pattern "h1_*"` removes all h1_* views
- Can view multiple files simultaneously to spot inconsistencies
- Views auto-update after edits

### Scenario 4: Find All References with Auto-Shrinking

**Situation**: Agent renaming config option usage across 18 locations

**Workflow**:
```xml
<!-- Find all uses -->
<editor>
  view refs /sops\.secrets\.\w+\.path/ in **/*.nix | context 5
</editor>
<!-- Screen shows all 18 matches (~234 lines) -->

<!-- Edit first location -->
<editor>
  edit modules/containers/default.nix 87-87
  credentials."secret-api" = config.sops.secrets.api_key.file;  # CHANGED path→file
</editor>
<!-- Screen regenerates, refs view now shows only 17 matches (edited line no longer matches) -->

<!-- Continue editing... -->
<!-- After all 12 edits, refs view shows only 6 remaining matches -->
```

**Success criteria**:
- All 18 references visible initially
- After each edit, view automatically removes non-matching locations
- View shrinks to show remaining work (natural progress tracking)
- This behavior emerges from procedural views (query re-executes)

### Scenario 5: Reference While Editing

**Situation**: Agent implementing container feature, needs type definitions visible

**Workflow**:
```xml
<!-- Create reference views -->
<editor>
  view ref_types /struct (Sandbox|Resource)Config/ in src/config.rs | while-indent
  view ref_trait /trait Environment/ in src/traits.rs | while-indent
</editor>
<!-- Shows 2 structs + 1 trait (~101 lines), persistent on screen -->

<!-- Implement feature -->
<editor>
  edit src/container.rs 45-52
  impl Container {
      pub fn new(config: SandboxConfig) -> Result<Self> {  // Reference visible
          ...
      }
  }
</editor>

<!-- Someone else updates SandboxConfig (adds new field) -->
<!-- Next screen refresh: ref_types view shows UPDATED struct with new field -->

<!-- Agent sees change, incorporates it -->
<editor>
  edit src/container.rs 127-135
  let config = SandboxConfig {
      ...
      new_field: default_value,  // NEW FIELD from updated struct
  };
</editor>
```

**Success criteria**:
- Reference views stay visible during work
- When referenced file changes externally, view updates automatically
- Agent never works from stale API definitions
- `while-indent` expands to full struct/trait bodies

## Plan

### Design Verification
- [x] Complete design document (docs/design/orchestrator/editor-environment-v2.md)
- [x] Review against 9 user stories (all scenarios grade A/A+)
- [x] Review for consistency and correctness (B+ → production-ready)

### Implementation

- [x] Implement query parser (`orchestrator/environments/editor/parser.py`)
  - [x] Parse `view <label> <matcher> in <glob> | <operations>`
  - [x] Parse `peek <matcher> in <glob> | <operations>`
  - [x] Parse matchers: `<pattern> in <glob>`, `line N in <file>`, `line N-M in <file>`
  - [x] Parse expansion operations: `context`, `up`, `down`, `until`, `up-until`, `until-blank`, `while-indent`
  - [x] Parse filtering operations: `filter`, `exclude`, `limit`
  - [x] Parse close commands: `close label`, `close pattern`, `close file`, `close all`
  - [x] Generate AST for pipeline execution
  - [x] Error handling for invalid syntax

- [x] Implement query executor (`orchestrator/environments/editor/executor.py`)
  - [x] Ripgrep backend for pattern matching
  - [x] Line matcher implementation
  - [x] Expansion operations:
    - [x] `context <n>` - expand n lines up and down
    - [x] `up <n>`, `down <n>` - directional expansion
    - [x] `until <pattern>`, `up-until <pattern>` - expand until pattern
    - [x] `until-blank` - expand until blank line
    - [x] `while-indent` - expand while indented (with smart closing)
  - [x] Filtering operations:
    - [x] `filter <pattern>` - keep windows containing pattern
    - [x] `exclude <pattern>` - remove windows containing pattern
    - [x] `limit <n>` - keep first n windows
  - [x] Pipeline composition (left-to-right execution)
  - [x] Max expansion limits (200 lines per operation)

- [x] Implement window/view management (`orchestrator/environments/editor/windows.py`)
  - [x] Window data structure (file, start_line, end_line, content, label)
  - [x] View merging (overlapping windows in same file)
  - [x] Deduplication
  - [x] Screen generation from views

- [x] Implement indentation analysis (`orchestrator/environments/editor/indentation.py`)
  - [x] Reference indentation calculation (first line of window)
  - [x] Empty/whitespace-only line handling (treated as indented)
  - [x] Smart closing rule (auto-include single closing brace/bracket)
  - [x] Language-agnostic implementation

- [x] Integrate AI summary system (uses auxiliary LLM query protocol from task 27)
  - [x] Collect all windows from <editor> tag
  - [x] Infer focus from query patterns
  - [x] Build summary prompt
  - [x] Call `orchestrator.request_auxiliary_llm_query(prompt, context)`
  - [x] Receive summary response
  - [x] Include in tool output
  - [x] One summary per <editor>...</editor> tag

- [x] Implement query lifecycle
  - [x] Phase 1: Pipeline execution
  - [x] Phase 2: Size checking (300 for peek, 3000 total for view)
  - [x] Phase 3: AI summary generation (on tag close)
  - [x] Phase 4: Store query and check for auto-removal
  - [x] Phase 5: Add to active query set
  - [x] Phase 6: Execute all queries and generate screen

- [x] Implement active query management
  - [x] Query storage (label → query mapping)
  - [x] Label override (same label replaces previous query)
  - [x] Auto-removal (query returns 0 windows)
  - [x] File exclusion (modifies existing queries)
  - [x] Pattern-based close (remove all queries matching label pattern)

- [x] Implement edit operations
  - [x] Find view containing target lines
  - [x] Verify lines are visible
  - [x] Verify content matches current view
  - [x] Perform edit
  - [x] Trigger screen regeneration (all queries re-execute)
  - [x] Mark query as "used" (update timestamp)

- [x] Refactor EditorEnvironment main class
  - [x] Integrate parser
  - [x] Integrate executor
  - [x] Integrate window/view management
  - [x] Integrate summarizer
  - [x] Implement command routing
  - [x] Implement screen generation
  - [x] Implement edit command

- [x] Write comprehensive tests
  - [x] Test query parser (all syntax variations)
  - [x] Test each expansion operation
  - [x] Test each filtering operation
  - [x] Test pipeline composition
  - [x] Test window merging and deduplication
  - [x] Test indentation analysis (Python, C, Nix examples)
  - [x] Test query lifecycle
  - [x] Test auto-removal on empty results
  - [x] Test label override
  - [x] Test file exclusion
  - [x] Test pattern-based close
  - [x] Test procedural view updates (edit causes re-execution)
  - [x] Test all 5 scenarios above
  - [x] Test limit enforcement (300 peek, 3000 total)
  - [x] Test error conditions (invalid syntax, no matches, etc.)

- [x] Verify with `nix build .#orchestrator`
  - [x] All formatters pass (black, isort)
  - [x] All linters pass (ruff)
  - [x] All tests pass

- [ ] Update documentation
  - [ ] Update environment protocol docs
  - [ ] Add editor redesign rationale
  - [ ] Add usage examples

## Dependencies

- Requires: Current editor environment (task 07) - provides baseline
- Requires: Editor redesign proposal (docs/design/orchestrator/editor-environment-v2.md) - complete spec
- Requires: Auxiliary LLM query protocol (task 27) - for AI summaries
- Blocks: None (replacement for existing functionality)

## Outcome

A production-ready editor environment that:

1. **Uses procedural views instead of snapshots**
   - All views regenerate from queries on screen refresh
   - Eliminates stale view bugs
   - Enables natural workflows (debugging, refactoring, references)

2. **Supports powerful pipeline queries**
   - Pattern matching with regex
   - Line-based access for debugging (peek only)
   - Composable expansion operations (context, while-indent, until, etc.)
   - Filtering and limiting
   - 300 line peek limit, 3000 line total view limit

3. **Provides intelligent summaries** (via auxiliary LLM queries)
   - One AI-generated summary per <editor> tag
   - Covers all windows opened in the tag
   - Separate tags for separate summaries
   - Routed through agent (orchestrator has no LLM access)
   - Cost and tokens tracked by agent

4. **Enables key workflows**
   - Architecture understanding via transient peeks
   - Multi-section editing with auto-updating views
   - Hypothesis testing during debugging
   - Find-all-references with auto-shrinking views
   - Persistent references that stay current

5. **Has clean command syntax**
   - `view <label> <pattern> in <glob> | <operations>` for persistent views
   - `peek <pattern> in <glob> | <operations>` for transient reads
   - `close label/pattern/file/all` for view management
   - Mandatory labels (explicit > implicit)
   - Label override pattern

6. **Maintains quality standards**
   - Comprehensive test coverage
   - Passes all formatters and linters
   - Production-ready error handling
   - Clear, documented implementation
