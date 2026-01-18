# Task: Design Sandbox Container and Runner

## Description

Design a lightweight, secure sandbox container system using gVisor's runsc runtime to replace the current Podman/Docker-based approach. The goal is to provide isolation and security without the complexity of a full container management system, since we only need one container instance per agent.

## Context

- **Component**: Sandbox runner (new component) + orchestrator packaging
- **Current approach**: Uses Podman to run OCI containers (see `docs/tasks/implement-container-integration.md`)
- **Problem**: Podman/Docker bring unnecessary complexity (daemon, image management, networking features) when we only need one isolated environment
- **Related**: Agent design (`docs/agent-design.md`), technology choices (`docs/technology.md`)

## Motivation

The current design uses Podman to manage containers, but we don't need most container management features:
- We only ever run ONE container instance per agent session
- We don't need image registries, layers, or versioning
- We don't need complex networking (we want simple isolation)
- We don't need orchestration or multi-container management

Instead, we want:
1. **Security**: Secure isolation using a proven runtime (gVisor's runsc)
2. **Simplicity**: Just spawn a sandboxed process, no daemon or management layer
3. **Customization**: Users can extend the sandbox with their toolchains (Rust, Poetry, etc.)
4. **Stdio transparency**: The sandbox forwards stdin/stdout to orchestrator seamlessly
5. **Minimal defaults**: Small base environment with Python and common utilities

## Scenarios

These scenarios describe what needs to work with the sandbox system:

### 1. Basic Agent Usage - Python Developer
A Python developer uses 7aigent to refactor a web application. The default sandbox should work immediately - it needs Python 3.13 and common shell tools (bash, coreutils) for the orchestrator's built-in environments to function. The developer shouldn't need to configure anything.

### 2. Rust Project Development
A developer working on a Rust project needs cargo, rustc, and clippy available in the sandbox for the agent to build and test code. They customize their project's `.7aigent.toml` to declare these dependencies. The sandbox is rebuilt with Rust toolchain included, and the agent can now run `cargo build`, `cargo test`, etc.

### 3. Python Poetry Project
A data science team uses Poetry for dependency management. They add Poetry to their sandbox configuration. When the agent runs `poetry install` or `poetry run`, it works because Poetry is available in the sandbox. The agent can install and use project dependencies.

### 4. Multi-Language Monorepo
A monorepo contains TypeScript frontend, Python backend, and Rust services. The `.7aigent.toml` declares Node.js, Python, and Rust as dependencies. The sandbox contains all three toolchains. The agent can build and test all components without switching environments.

### 5. Secure Research Assistant
A security researcher uses 7aigent to analyze malware samples. The sandbox isolates the orchestrator completely - even if the agent accidentally executes malicious code through bash, it cannot escape the sandbox or access the host filesystem beyond the project directory. Network access is blocked by default.

### 6. CI/CD Integration
A CI pipeline runs 7aigent to automate code reviews. The sandbox must start quickly and use minimal resources. The build produces a standalone binary/script that spawns the sandbox, forwards stdio, and exits cleanly. No daemon or persistent state is required.

### 7. Offline Development
A developer works on an airplane without internet. They've previously built the sandbox with all needed dependencies. When they run 7aigent, the sandbox starts immediately from locally cached artifacts - no downloads, no network required.

### 8. Debugging Communication Errors
The agent fails with a cryptic error. The developer wants to understand what's happening. They inspect the sandbox logs, see the raw stdin/stdout messages between agent and orchestrator, and identify that a malformed JSON message caused the failure. The sandbox provides transparent observability.

### 9. Resource-Constrained Environment
A developer on a laptop with limited RAM uses 7aigent. The sandbox configuration limits memory to 2GB and CPU to 1 core. The orchestrator and environments run within these constraints, preventing the agent from consuming excessive resources.

### 10. Custom Base Environment
A team has internal tools and libraries they always need. They fork the sandbox Nix derivation, add their custom packages, and reference it in their config. Every team member gets the same consistent environment when they run 7aigent.

## Plan

This task is for design work, following the scenario-driven design workflow:

- [ ] **Step 1: Identify Components**
  - [ ] Read current container integration design and code
  - [ ] Understand gVisor runsc capabilities and constraints
  - [ ] Map out Nix packaging architecture (orchestrator, sandbox, agent)

- [ ] **Step 2: Review Scenarios**
  - [ ] Scenarios are already defined above
  - [ ] Extract implicit requirements from each scenario

- [ ] **Step 3: Design for Scenarios**
  - [ ] Walk through each scenario with proposed architecture
  - [ ] Design Nix derivation structure (orchestrator, sandbox script, agent)
  - [ ] Design customization mechanism (how users add dependencies)
  - [ ] Design runsc invocation and configuration
  - [ ] Design stdio forwarding protocol
  - [ ] Design resource limits and security settings

- [ ] **Step 4: Verify Implementation Practicality**
  - [ ] Mentally trace through runsc execution
  - [ ] Verify Nix dependency graph is valid
  - [ ] Check that customization mechanism is implementable
  - [ ] Identify any circular dependencies or impossible requirements

- [ ] **Step 5: Simplify and Prune**
  - [ ] Question every configuration option - is it needed for scenarios?
  - [ ] Remove unnecessary features
  - [ ] Prefer simple fixed approaches over complex configurability

- [ ] **Step 6: Review Against Scenarios**
  - [ ] Walk through each scenario with the design
  - [ ] Identify friction points
  - [ ] Grade the design (A/B/C/D)

- [ ] **Step 7: Iterate and Refine**
  - [ ] Address issues found in review
  - [ ] Document design decisions and rationale
  - [ ] Document trade-offs and alternatives considered

- [ ] **Step 8: Create Design Document**
  - [ ] Write `docs/sandbox-design.md` with complete design
  - [ ] Include architecture diagrams
  - [ ] Include Nix derivation structure
  - [ ] Include runsc configuration
  - [ ] Include customization examples
  - [ ] Document security model
  - [ ] Document limitations and future enhancements

- [ ] **Step 9: Create Implementation Task**
  - [ ] Write `docs/tasks/implement-sandbox-container.md`
  - [ ] Follow task template from CLAUDE.md
  - [ ] Break down implementation into phases
  - [ ] Define dependencies and outcome
  - [ ] Add to master task list in `docs/tasks/README.md`

## Dependencies

- Orchestrator implemented and working
- Understanding of Nix derivations and flakes
- Understanding of gVisor runsc capabilities

## Outcome

1. **Design document** (`docs/sandbox-design.md`) that:
   - Explains the three-part Nix architecture (orchestrator, sandbox, agent)
   - Shows how runsc provides isolation
   - Describes customization mechanism for adding dependencies
   - Covers all 10 scenarios successfully
   - Documents security model and resource limits
   - Includes concrete examples and code snippets

2. **Implementation task** (`docs/tasks/implement-sandbox-container.md`) that:
   - References the design document
   - Breaks work into implementable phases
   - Includes verification steps
   - Is ready to execute immediately after design approval

3. **Updated task list** with new implementation task added

The design should prioritize simplicity and security over features. If a feature doesn't clearly support the scenarios, defer it to V2.
