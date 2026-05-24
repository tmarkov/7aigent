# CodeTree and Sandbox Test Suites — 4 Requirements with Inadequate or Missing Tests

## Summary

A full requirement-driven audit of the CodeTree (R1–R35), Sandbox (S1–S23), and
REPL API (RA1–RA32) test suites identified **4 requirements** with inadequate
or missing test coverage:

- **2 UNTESTED** — no tests exercise the requirement at all
- **2 WEAK** — tests exist but passing does not prove the requirement satisfied

This is substantially healthier than the agent module (20 WEAK + 4 UNTESTED).
The CodeTree and Sandbox test suites pass the audit cleanly — all 79
requirements there have tests that genuinely prove the stated behaviour.

The 4 issues are all in the REPL API module (`sandbox/test/runtests.jl`).

---

## Findings

### UNTESTED Requirements

| ID | Requirement | Gap |
|----|-------------|-----|
| **RA20** | Keywords are evidence-selection hint only (not inserted into prompt) | No test passes `keywords` to `summarize!`. The keyword feature is completely unexercised. |
| **RA21** | Keyword matching is case-insensitive and deterministic | Same root cause as RA20 — no test uses keywords at all. |

### WEAK Requirements

| ID | Requirement | Anti-Pattern | Issue |
|----|-------------|--------------|-------|
| **RA18** | Child ranking (6 criteria: README > summary > structure > keywords > n_lines > sibling_order) | AP4: One Instance of Universal | Only criterion 1 (README promoted first) is validated. Criteria 2–6 are never tested — we cannot infer correct ranking from the existing tests. |
| **RA22** | Summary RPC over Jupyter `comm_open`/`comm_msg`/`comm_close` | AP6: Pure Proxy for Effectful | All tests inject a mock transport via `set_summary_transport!`. The actual Jupyter comm protocol is never exercised — neither in the Julia tests nor in `test_integration.py`. |

---

## Classification Framework

Every test was evaluated against:

- **PASS** — tests pass ⟹ we can reasonably infer the requirement is satisfied
- **WEAK** — tests are "assigned" to this requirement but do not actually prove it
- **UNTESTED** — no tests address this requirement

Anti-patterns referenced:

- **AP4** (One Instance of Universal) — testing one case of a multi-criteria
  requirement that uses quantifiers
- **AP6** (Pure Proxy for Effectful) — testing workflow logic via a mock when
  the requirement describes real protocol behaviour

---

## Contrast with Agent Module

| Component | Total Req | PASS | WEAK | UNTESTED |
|-----------|-----------|------|------|----------|
| CodeTree (R1–R35) | 49 | 49 | 0 | 0 |
| Sandbox (S1–S23) | 30 | 30 | 0 | 0 |
| REPL API (RA1–RA32) | 34 | 30 | 2 | 2 |
| **Agent (A1–A50)** | **57** | **33** | **20** | **4** |

The CodeTree tests are exemplary — they use real fixtures, universal invariant
checks, both-sides-of-threshold testing, and concrete outcome assertions. The
Sandbox tests combine config verification (dry-run) with genuine
integration testing against a running sandbox. The REPL API tests are mostly
strong, with the keyword feature being the main gap.

---

## Recommendations

1. **RA20 + RA21 (keywords):** Add at least one test that passes a `keywords`
   vector to `summarize!` and verifies that children matching those keywords are
   ranked higher in the evidence graph's `child_ids` order. Also verify keywords
   are NOT present in the transport request's prompt text (the "hint only"
   clause).

2. **RA18 (child ranking):** Add a fixture with enough children to exercise
   ranking criteria 2–6. For example, a parent with 8+ children where only 3
   are included — verify that a child with a summary outranks one without, that
   a `function` outranks a `chunk`, etc.

3. **RA22 (Jupyter comm transport):** Consider adding an integration test in
   `test_integration.py` that calls `summarize!` through the real kernel and
   verifies the comm protocol reaches the agent side. The mock transport is
   appropriate for testing the workflow logic, but the actual protocol layer
   should be exercised at least once.

---

## Full Audit — Per-Requirement Detail

### CodeTree (R1–R35): All PASS

| Req | Summary | Notes |
|-----|---------|-------|
| R1 | Schema columns and invariants | Multiple tests: qname uniqueness, n_lines invariant, source only on leaves, ordinal IDs. All iterate real fixture output. |
| R2 | Symbols schema (node_id, symbol, kind) | R22 test checks schema and validates all kinds are call/var_ref. |
| R3 | All DataFrame read ops work | Implicitly validated — every test uses filter/query operations on db.code/db.symbols. |
| R4 | Direct mutation raises error | Test assigns to CodeSymbols and checks exception with update_source guidance. |
| R4a | Summary writes allowed and override-tracked | Tested via R33b test — sets summary, calls update_source, checks override survives. |
| R5 | File discovery (git + fallback) | Three tests: discovers all tracked/untracked files, excludes gitignored, fallback without git respects nested .gitignore. |
| R6 | Structural nodes (codebase, module, file) | Checks one root, modules per directory, file per discovered file. |
| R7 | Language detection from extension | Tests language_for_file helper and language column in loaded DB. |
| R8 | Unknown-language chunk splitting | Checks config.toml splits into 4 chunks with expected line ranges and non-blank content. |
| R9 | Config maps AST types to (class, kind) | Tests classify_node for C++, Julia, Markdown with positive and negative cases. |
| R9a | Call and definition patterns per language | Tests patterns are non-empty Vector{String}. Behavioral correctness validated by R21 tests. |
| R10 | Landmark nodes always appear | Checks known functions appear including member functions (field_identifier fix). |
| R11 | Detail nodes conditional on threshold | Tests BOTH sides: quick_sort<30 has no details, merge_sort>=30 has details. |
| R12 | Default detail_threshold is 30 | Loads without explicit threshold, verifies same R11 results. |
| R13 | Markdown structural parsing via config | Tests api.md has children and list-boundary.md does not crash. |
| R14 | Spanning invariant (children cover parent) | Universal test: iterates ALL non-leaf nodes and checks children cover full line range. |
| R14a | Shared boundary goes to second sibling | Tests wacky function: specific line numbers for adjacent conditionals. |
| R14b | Leading comment absorption | Positive (quick_sort, merge_sort absorbed) and negative (swap, blank line prevents). |
| R14c | No all-blank chunk nodes | Universal test: filters all chunks, asserts none consist entirely of blank lines. |
| R15 | Chunks fill gaps between compound children | Checks chunks exist and are leaves. Gap-filling validated by R14 spanning invariant. |
| R16 | Siblings ordered by line_start | Universal test: iterates all sibling groups and checks ascending line_start. |
| R17 | Docstring → summary | Tests sort_array and DataStats summaries from their docstrings. |
| R18 | Preceding comment → summary | Tests search_sorted and is_sorted summaries from comments. Plus strip-marker test. |
| R19 | Module/codebase summary | Tests DataProcessor module summary and codebase root summary from README first paragraph. |
| R20 | No summary when no docs (missing) | Tests swap (blank line prevents) and noop (no documentation). |
| R20a | Comment node summary from own source | Tests standalone comment node has source-derived summary. |
| R20b | No network/agent calls for summary | Validated by construction: all tests run without network, no external calls. |
| R21 | Symbol extraction for leaves | Tests call symbols, var_ref exclusion of locals, MAX_N as var_ref. |
| R21a | Markdown code span symbol extraction | Comprehensive: tagged fenced blocks (language-specific), untagged blocks (name intersection), inline spans. |
| R21b | Non-MD indexed before MD symbols | Implicitly validated: untagged block tests depend on cpp/julia names being in db.code first. |
| R21c | Markdown names excluded from intersection | Tests heading/paragraph text absent from symbols. |
| R22 | Symbol schema, no resolution | Checks nrow > 0, columns present, all kinds are call/var_ref. |
| R24 | Cache at .7aigent/code_tree/ | Checks directory exists with at least one .db file after load. |
| R25 | Files table with path, hash, commit_hash | Checks table exists, columns present, SHA-256 format. |
| R25a | Compat version invalidation | Modifies compat_version, injects sentinel, confirms NOT reused. |
| R26 | Unchanged files reuse cache | Second load identical; sentinel injection proves row reuse. |
| R27 | Changed file re-parsed | Modifies core.jl, re-loads, checks new function name appears. |
| R28 | Deleted file rows removed | Deletes utils.jl, re-loads, confirms rows gone. |
| R29 | In-memory buffer for all files | Checks all files in buffer; tampering disk after load does not affect buffer. |
| R29a | get_source for leaf and non-leaf | Leaf returns source column; non-leaf reconstructs from buffer. |
| R30 | update_source succeeds (leaf and non-leaf) | Tests basic leaf update and non-leaf file node update. |
| R30a | External change detection and refresh | Tampers file, calls update_source, checks exception and db refresh. |
| R31 | Splice semantics | Verifies lines before and after replaced span unchanged. |
| R32 | Re-index in memory before DataFrame modify | Implicitly validated by R33 (update visible) and R35 (rollback if fail). |
| R33 | Code and symbols updated together | Checks symbols updated, no duplicates, old node symbols removed. |
| R33a | Old symbol rows replaced | Tested within R33 test. |
| R33b | Summary overrides survive update_source | Sets override, calls update_source, checks override persists on stable id. |
| R34 | Disk written after DataFrames consistent | Checks disk content matches buffer after update. |
| R35 | Rollback on disk write failure | Makes file read-only, calls update_source, checks full rollback. |

### Sandbox (S1–S23): All PASS

| Req | Summary | Notes |
|-----|---------|-------|
| S1 | gvisor/runsc with KVM platform | Integration tests run real sandbox and verify isolation. |
| S1a | bwrap compatibility mode | bwrap hardening flags verified; bwrap mode exercised in signal tests. |
| S2 | No TCP/UDP network access (runsc) | Dry-run: network namespace in OCI config. Integration: ping returns false. |
| S2a | bwrap network namespace best-effort | Checks --unshare-net and warning text in launcher script. |
| S3 | Root filesystem read-only | Checks config.json root.readonly is True. |
| S4 | Minimal Nix store closure mounted | No wholesale /nix/store; individual paths; sandbox output included; host git excluded. |
| S5 | Dedicated Linux namespaces | Network namespace verified. Others implicit in runsc defaults. |
| S5a | bwrap namespace separation | --unshare-pid/ipc/uts/net flags verified. |
| S6 | Two OS threads for interrupt delivery | Infinite tight loop interrupted and kernel recovers — only possible with 2 threads. |
| S7 | /sockets rw bind mount | /sockets mount present and rw. |
| S7a | Host UDS creation enabled | --host-uds=create verified in launcher text. |
| S8 | ZMQ IPC transport, 5 channels | transport=ipc, all 5 ports. Integration connects via IPC. |
| S9 | kernel.json format with UUID4 HMAC key | Signature scheme, UUID4 format, freshness per invocation. |
| S10 | /workspace rw bind mount | Correct source path, rw. |
| S10a | .7aigent/state read-only overlay | Dry-run: mount present, ro, after workspace. Integration: write fails. |
| S11 | nogit blocks new .git on restart | Sentinel created, blocks .git appearance. Integration: .git write fails. |
| S11a | nogit lifecycle (create/cleanup) | Stale sentinel harmless; clean bwrap exit removes it. |
| S11b | Git metadata read-only (dir/symlink/gitfile) | All three types tested. All readonly with correct mount order. |
| S12 | No commit tooling inside sandbox | Implicitly: S4 closure minimality excludes git; S3 readonly root prevents install. |
| S13 | Offline operation | Integration: CodeTree and SevenAigentREPL load with network blocked. |
| S14 | Julia depot scratch path config | Implicitly: kernel starts and runs Julia code. |
| S15 | kernel.json path printed to stdout | Checks stdout is path ending in kernel.json. |
| S16 | Launcher stays resident for signals | bwrap test sends SIGINT, launcher exits cleanly. |
| S17 | Runtime dir removed on exit | Both bwrap and integration assert runtime_dir gone. |
| S18 | interrupt_request raises InterruptException | Infinite loop interrupted, kernel recovers. |
| S19 | Kernel ready after interrupt | After interrupt, 1+1 returns 2. |
| S20 | Child process killed on interrupt | sleep 300 interrupted, kernel recovers. |
| S21 | Launcher CLI | Prints path, no-arg fails, extra-arg fails. |
| S22 | Invalid workspace fails loudly | Multiple invalid configurations all fail with informative stderr. |
| S23 | Self-contained script with hardening | Hardening tokens verified in launcher text. |

### REPL API (RA1–RA32): 30 PASS, 2 WEAK, 2 UNTESTED

| Req | Summary | Verdict | Notes |
|-----|---------|---------|-------|
| RA1 | Dedicated Julia module | PASS | Validated by all tests importing SevenAigentREPL. |
| RA2 | Available on load path | PASS | Integration test confirms. |
| RA3 | Session summary + display helpers | PASS | llm_show_dataframe renders compact markdown. |
| RA3.1 | Bootstrap via startup.jl | PASS | Show delegation for CodeTree tables works. |
| RA3.2 | LLM-focused compact markdown | PASS | Markdown table format, omission messages, no box-drawing. |
| RA4 | Summaries reflected in db.code | PASS | After summarize!, db.code shows generated text. |
| RA5 | Session-scoped, not persisted | PASS | Reloaded db lacks summary; survives update_source. |
| RA6 | summarize! accepts ids or DataFrame | PASS | Both forms tested. |
| RA7 | DataFrame delegates to id method | PASS | Frame's summary column updated. |
| RA7a | Return DataFrame (id, name, summary) | PASS | Result structure verified. |
| RA8 | Only explicit targets | PASS | Captured request matches requested ids. |
| RA9 | Batching by tree locality | PASS | Correct split with batch_size=2 and 3 targets. |
| RA10 | Recursive tree partitioning | PASS | One test validates locality grouping. |
| RA11 | Batch fit criteria | PASS | max_targets_per_batch=2 produces expected batches. |
| RA12 | Deduplicated evidence graph | PASS | Unique node ids and witness ids. |
| RA13 | Target evidence components | PASS | Self card, children, README, witnesses present. |
| RA14 | Primary witness (leftmost leaf) | PASS | Non-leaf uses leftmost descendant. |
| RA15 | README promoted documentation | PASS | promoted_readme_id is first child. |
| RA16 | All children when ≤ max | PASS | Small fixtures include all without overflow. |
| RA17 | Overflow metadata when > max | PASS | n_children_omitted > 0 with max=2. |
| RA18 | Child ranking (6 criteria) | **WEAK** | Only README promotion tested. Criteria 2–6 unvalidated. |
| RA20 | Keywords hint only | **UNTESTED** | No test uses keywords. |
| RA21 | Keyword matching | **UNTESTED** | No test uses keywords. |
| RA22 | Jupyter comm RPC | **WEAK** | Mock transport only. Real comm protocol untested. |
| RA23 | Request format | PASS | Captured request has target_ids and evidence. |
| RA24 | Blocking await | PASS | Synchronous completion implied. |
| RA25 | Config from .7aigent/config.toml | PASS | Writes config, verifies values. |
| RA26 | Supported settings (5 fields) | PASS | All 5 tested. |
| RA27 | Defaults and partial override | PASS | Partial config overrides only specified fields. |
| RA28 | Module source in included files | PASS | By construction. |
| RA29 | TodoStatus enum | PASS | Defined, exported, distinct values. |
| RA30 | bind! initializes Main.todo | PASS | Correct schema, overwrites existing. |
| RA31 | todo helpers | PASS | Auto-increment, transitions, error throws. |
| RA32 | status() | PASS | Prints, handles edge cases, never throws. |
