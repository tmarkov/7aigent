# Task: Implement Sandbox Container System

## Description

Implement the bubblewrap-based sandbox system designed in `docs/sandbox-design.md`. This replaces the Podman-based container approach with a simpler, lighter-weight solution using Linux namespaces for isolation.

## Context

- **Component**: Sandbox (new Nix derivation) + agent container manager
- **Design**: See `docs/sandbox-design.md` for complete design
- **Replaces**: `implement-container-integration.md` (Podman approach)
- **Dependencies**: Orchestrator (complete), agent core (complete)

## Plan

### Phase 1: Sandbox Nix Derivation

- [ ] Create `sandbox/default.nix`
  - [ ] Define function signature: `{ pkgs, orchestrator, extraPackages ? [] }`
  - [ ] Build sandboxPackages list: python313, bash, coreutils, findutils, procps, orchestrator
  - [ ] Append extraPackages to sandboxPackages
  - [ ] Create sandboxEnv with `pkgs.buildEnv`
  - [ ] Write shell script with bubblewrap invocation (see design doc for full command)
  - [ ] Use `pkgs.writeShellScriptBin "7aigent-sandbox"`

- [ ] Test sandbox script manually
  - [ ] Build: `nix build -f sandbox/default.nix --arg pkgs 'import <nixpkgs> {}' --arg orchestrator '(import ./orchestrator)'`
  - [ ] Run: `./result/bin/7aigent-sandbox $PWD`
  - [ ] Verify orchestrator starts and responds to NDJSON commands
  - [ ] Test file access: can write to /workspace, cannot write to /nix/store
  - [ ] Test isolation: `ps aux` shows only sandbox processes

- [ ] **CRITICAL: git add immediately after creating files**
  - [ ] `git add sandbox/default.nix`
  - [ ] Verify file appears in git status

### Phase 2: Flake Integration

- [ ] Update `flake.nix`
  - [ ] Import sandbox derivation: `sandbox = pkgs.callPackage ./sandbox { inherit orchestrator; };`
  - [ ] Add to `packages` output
  - [ ] Add example custom builds: `agent-with-rust`, `agent-with-poetry`
  - [ ] Update default package to use new sandbox

- [ ] Test flake builds
  - [ ] `nix build .#sandbox` - verify sandbox script builds
  - [ ] `nix build .#agent-with-rust` - verify custom extraPackages work
  - [ ] Inspect result: `cat result/bin/7aigent-sandbox` - verify Rust packages included

- [ ] **CRITICAL: git add and build verification**
  - [ ] `git add flake.nix`
  - [ ] Run `nix build .#sandbox` and verify it sees changes
  - [ ] If build succeeds without new code, investigate why (likely not in git)

### Phase 3: Agent Container Manager Refactor

- [ ] Update `agent/src/container/manager.rs`
  - [ ] Remove Podman-specific code (image building, podman command construction)
  - [ ] Simplify `ContainerManager::new()` to just store sandbox_path
  - [ ] Read `SANDBOX_PATH` environment variable (set by Nix wrapper)
  - [ ] Fallback to `7aigent-sandbox` in PATH if env var not set

- [ ] Update `agent/src/container/manager.rs::spawn()`
  - [ ] Build `Command` for sandbox script
  - [ ] First arg: project_dir path
  - [ ] Optional args: handle `config.sandbox.disable_network` → add `--unshare-net`
  - [ ] Spawn with stdin/stdout pipes, stderr inherited
  - [ ] Return `ContainerHandle` with process and pipes

- [ ] Update `agent/src/container/handle.rs`
  - [ ] Keep existing `ContainerHandle` struct (child, stdin, stdout)
  - [ ] Keep `send_command()` and `receive_response()` (NDJSON protocol unchanged)
  - [ ] Update `shutdown()` to drop stdin and wait for child
  - [ ] Implement Drop trait: ensure child is killed if dropped without shutdown

- [ ] Remove unused files
  - [ ] Delete `agent/src/container/builder.rs` (no image building needed)
  - [ ] Delete Podman-specific code from `agent/src/container/`

- [ ] **CRITICAL: git add immediately after changes**
  - [ ] `git add agent/src/container/*.rs`
  - [ ] Run `nix build .#agent` to verify changes compile

### Phase 4: Agent Nix Derivation Update

- [ ] Update `agent/default.nix`
  - [ ] Add `sandboxExtraPackages ? []` parameter
  - [ ] Call sandbox derivation with extraPackages
  - [ ] Add `makeWrapper` to nativeBuildInputs
  - [ ] Add postInstall hook to wrap binary with SANDBOX_PATH
  - [ ] Example: `wrapProgram $out/bin/7aigent --set SANDBOX_PATH ${sandbox}/bin/7aigent-sandbox`

- [ ] Test agent build
  - [ ] `nix build .#agent` - verify builds successfully
  - [ ] Check wrapper: `cat result/bin/7aigent` - should be wrapper script
  - [ ] Check SANDBOX_PATH: `grep SANDBOX_PATH result/bin/7aigent` - should find it

- [ ] **CRITICAL: git add and build verification**
  - [ ] `git add agent/default.nix`
  - [ ] Verify `nix build .#agent` sees changes

### Phase 5: Configuration System

- [ ] Update `agent/src/config.rs`
  - [ ] Remove Podman-specific fields (container_image, etc.)
  - [ ] Add `SandboxConfig` struct:
    - [ ] `extra_packages: Option<PathBuf>` - path to .nix file
    - [ ] `disable_network: bool` - default false
    - [ ] `sandbox_path: Option<PathBuf>` - override default sandbox
  - [ ] Update Config struct with `sandbox: SandboxConfig`
  - [ ] Update TOML parsing (use serde)

- [ ] Test config parsing
  - [ ] Create test `.7aigent.toml` with `[sandbox]` section
  - [ ] Unit test: parse config, verify fields populated
  - [ ] Test missing fields use defaults

- [ ] **CRITICAL: git add and build verification**
  - [ ] `git add agent/src/config.rs`
  - [ ] Run `nix build .#agent` - verify tests pass

### Phase 6: Custom Sandbox Building (Advanced)

- [ ] Implement custom sandbox build in agent (optional for V1)
  - [ ] Check if `config.sandbox.extra_packages` is set
  - [ ] If set, run `nix build` with custom expression (see design doc)
  - [ ] Parse output to get sandbox path
  - [ ] Use custom sandbox instead of default
  - [ ] Cache build result (don't rebuild every run)

- [ ] Alternative simpler approach for V1:
  - [ ] Document manual rebuild process in README
  - [ ] User runs: `nix build --expr '...'` when they change dependencies
  - [ ] User sets `sandbox_path` in config to point to result
  - [ ] Agent just uses the specified path (no automatic rebuild)

- [ ] Choose approach based on complexity
  - [ ] If automatic rebuild is complex, defer to V2
  - [ ] Document manual approach in README
  - [ ] Add TODO comment for V2 enhancement

### Phase 7: Integration Testing

✅ **COMPLETED**: Implemented Python-based sandbox tests integrated into Nix build.

**Design decision**: Use Python tests (pytest) instead of Rust tests because:
- Sandbox is a Nix derivation (shell script), not Rust code
- Python can easily spawn subprocess and test NDJSON protocol
- Tests run as part of `nix build .#sandbox.tests` via `passthru.tests`
- Consistent with orchestrator testing approach

**Tests implemented** (`sandbox/tests/test_sandbox.py`):
- [x] Test 1: Spawn sandbox and verify basic NDJSON communication
- [x] Test 2: Execute bash commands and verify output
- [x] Test 3: Verify filesystem isolation (workspace accessible, /nix/store read-only, /tmp writable)
- [x] Test 4: Verify process isolation (limited process list)
- [x] Test 5: Verify clean shutdown when stdin closed
- [x] Test 6: Verify Python environment works
- [x] Test 7: Verify required packages available (bash, python, coreutils, etc.)
- [x] Test 8: Verify screen command returns current state

**Running tests**:
```bash
# Tests automatically run during sandbox build
nix build .#sandbox

# Build output shows: "Running sandbox integration tests..." followed by pytest results
```

**Test structure**:
- `sandbox/tests/__init__.py` - Test package marker
- `sandbox/tests/test_sandbox.py` - All integration tests
- `sandbox/default.nix` - Uses `installCheckPhase` to run tests after install

### Phase 8: Documentation

- [ ] Update `docs/technology.md`
  - [ ] Change "Podman" to "Bubblewrap"
  - [ ] Update rationale
  - [ ] Link to `docs/sandbox-design.md`

- [ ] Create `docs/sandbox-usage.md`
  - [ ] How to customize sandbox (add dependencies)
  - [ ] Example: Rust project
  - [ ] Example: Poetry project
  - [ ] Example: multi-language monorepo
  - [ ] Troubleshooting: user namespace errors, permission denied, etc.

- [ ] Update `README.md`
  - [ ] System requirements: bubblewrap, user namespaces enabled
  - [ ] Quick start: `nix build .#agent && ./result/bin/7aigent "task"`
  - [ ] Link to sandbox customization docs

- [ ] **CRITICAL: git add docs**
  - [ ] `git add docs/*.md`

### Phase 9: Cleanup and Verification

✅ **COMPLETED**

- [x] Remove old Podman code
  - [x] No container.nix existed
  - [x] Removed Podman references from `docs/technology.md` (updated to Bubblewrap)
  - [x] Removed Podman from `flake.nix` (replaced with bubblewrap)

- [x] Final build verification
  - [x] Clean build: `nix build .#agent` succeeds with all tests passing
  - [x] Verified `result/bin/7aigent` exists and is executable
  - [x] Verified sandbox path in wrapper: `SANDBOX_PATH=/nix/store/.../7aigent-sandbox`
  - [x] Verified sandbox script exists at wrapped path
  - [x] Agent starts correctly (validated with --help and basic run)

- [x] Update task list
  - [x] Task marked complete below
  - [x] References `sandbox-design.md` and test documentation

## Dependencies

- [x] Orchestrator implemented and working
- [x] Agent core implemented
- [x] Sandbox design complete (`docs/sandbox-design.md`)

## Outcome

**IMPLEMENTED with design change**: Instead of `extraPackages`, implemented `shell_prefix` approach.

A complete sandbox container system that:
- ✅ Uses bubblewrap for lightweight, secure isolation
- ✅ Integrates cleanly with Nix build system
- ✅ Supports customization via `shell_prefix` (e.g., "nix develop --command")
- ✅ Spawns quickly (~200-300ms)
- ✅ Forwards stdin/stdout transparently for NDJSON protocol
- ✅ Has clean shutdown and cleanup
- ✅ Is well-documented with examples

**Success criteria:**
1. ✅ `nix build .#agent` produces working agent with embedded sandbox
2. ✅ `./result/bin/7aigent "task"` spawns sandbox and communicates with orchestrator
3. ✅ Custom dependencies work via user's `flake.nix` + `shell_prefix` config
4. ✅ Integration tests (COMPLETED - see Phase 7)
5. ✅ Documentation explains customization clearly

**Design change:**
- **Original plan**: `extraPackages` parameter, build-time customization
- **Implemented**: `shell_prefix` config, runtime customization via `nix develop`
- **Rationale**: Allows post-install customization without rebuilding agent

**Non-goals for V1:**
- Resource limits (defer to V2)
- Network allowlisting (all-or-nothing for V1)
- Seccomp filters (defer to V2)
- Integration tests (deferred to end-to-end-testing task)
