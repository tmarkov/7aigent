# Agent Tests Audit

This document classifies all tests in the agent codebase by quality based on the new testing principles established in `docs/development/testing.md`.

## Classification Legend

- **GOOD**: Requirement-driven, verifies actual requirements, would keep as-is or with minor name/doc updates
- **NEEDS-IMPROVEMENT**: Tests a real requirement but uses brittle assertions or redundant checks
- **REMOVE**: Trivial, redundant with implementation logic, or doesn't test a meaningful requirement

---

## agent/src/agent.rs

### Test: `test_generate_simulated_message_markdown` (Lines 683-713)
**Classification**: **NEEDS-IMPROVEMENT** → Example test from task doc

**Current problems**:
1. Checks for hardcoded strings like "markdown file" (line 710) - duplicates implementation
2. Checks that template contains "README.md" - redundant with implementation
3. String matching for command patterns instead of structural verification

**What it should do** (from task doc):
1. Verify parseability by actually parsing with `parse_commands`
2. Verify command structure (2 commands, both editor, first search, second view)
3. Actually execute commands via orchestrator to verify they work
4. Verify expected effects (view appears in screen)

**Rewrite needed**: Yes - This is the main example from the task document

---

### Test: `test_generate_simulated_message_text` (Lines 715-739)
**Classification**: **NEEDS-IMPROVEMENT**

**Current problems**:
1. Same issues as markdown test - checks for hardcoded strings like "paragraphs"
2. String matching instead of structural verification
3. Doesn't verify parseability or executability

**Rewrite needed**: Yes - Apply same pattern as markdown test

---

### Test: `test_generate_simulated_message_no_file` (Lines 741-758)
**Classification**: **NEEDS-IMPROVEMENT**

**Current problems**:
1. Checks for hardcoded strings like "no obvious overview"
2. String matching instead of structural verification
3. Doesn't verify bash command actually works

**Rewrite needed**: Yes - Apply same pattern as other simulated message tests

---

### Test: `test_build_directory_tree_basic` (Lines 760-771)
**Classification**: **GOOD**

**Current behavior**: Creates temp project structure, builds tree, verifies expected files appear

**Why good**:
- Tests actual requirement (tree contains files that exist)
- Uses positive assertions on actual effects
- Structure-aware (checks for specific files and directory indicators)

**Action**: Keep with minor improvements:
- Update name: `test_build_directory_tree_includes_files_and_directories`
- Add docstring: "Requirement: Directory tree must include all non-ignored files and mark directories with trailing slash"

---

### Test: `test_build_tree_at_depth_1` (Lines 773-785)
**Classification**: **GOOD**

**Current behavior**: Verifies depth 1 shows top-level but not nested files

**Why good**:
- Tests actual requirement (depth limiting)
- Uses both positive (should see) and negative (should not see) assertions appropriately
- Negative assertions here are fail-safe (if it includes too much, we'll notice)

**Action**: Keep with minor improvements:
- Update name: `test_build_tree_at_depth_limits_nesting`
- Add docstring: "Requirement: Depth parameter must limit tree traversal (depth 1 shows top-level only)"

---

### Test: `test_build_tree_at_depth_2` (Lines 787-794)
**Classification**: **GOOD**

**Current behavior**: Verifies depth 2 includes files inside first-level directories

**Why good**: Tests depth requirement at different level

**Action**: Keep with minor improvements:
- Update name: `test_build_tree_at_depth_2_includes_nested_files`
- Add docstring: "Requirement: Depth 2 must include files inside first-level directories"

---

## agent/src/parser.rs

### Test: `test_parse_single_command` (Lines 83-96)
**Classification**: **GOOD**

**Current behavior**: Parses response with one command tag, verifies extraction

**Why good**:
- Tests core requirement (parser extracts command from tags)
- Structure-aware (checks env and command fields)
- Not redundant (parser logic is non-trivial)

**Action**: Keep with minor improvements:
- Update name: `test_parse_commands_extracts_single_command`
- Add docstring: "Requirement: Parser must extract environment and command from single tag"

---

### Test: `test_parse_multiple_commands` (Lines 98-132)
**Classification**: **GOOD**

**Current behavior**: Parses response with three different environment tags

**Why good**: Tests multi-command extraction requirement

**Action**: Keep with improvements:
- Update name: `test_parse_commands_extracts_multiple_commands`
- Add docstring: "Requirement: Parser must extract all commands in order from multiple tags"

---

### Test: `test_parse_multiline_command` (Lines 134-152)
**Classification**: **GOOD**

**Current behavior**: Verifies Python function with indentation is preserved

**Why good**:
- Tests critical requirement (whitespace preservation for Python)
- Verifies actual structure, not just presence of strings

**Action**: Keep with improvements:
- Update name: `test_parse_commands_preserves_multiline_content`
- Add docstring: "Requirement: Parser must preserve newlines and whitespace in command content"

---

### Test: `test_parse_no_commands` (Lines 154-160)
**Classification**: **GOOD**

**Current behavior**: Verifies empty list when no tags present

**Why good**: Tests boundary condition (no commands = agent done)

**Action**: Keep with improvements:
- Update name: `test_parse_commands_returns_empty_for_no_tags`
- Add docstring: "Requirement: Parser must return empty list when response contains no environment tags"

---

### Test: `test_parse_command_with_empty_body` (Lines 162-173)
**Classification**: **GOOD**

**Current behavior**: Verifies empty command content is handled

**Why good**: Tests edge case that could break execution

**Action**: Keep with improvements:
- Update name: `test_parse_commands_handles_empty_command_content`
- Add docstring: "Requirement: Parser must handle tags with empty body (return empty string, not error)"

---

### Test: `test_parse_mixed_content` (Lines 175-198)
**Classification**: **GOOD**

**Current behavior**: Verifies parser extracts only environment tags, ignores markdown code blocks

**Why good**:
- Tests important requirement (don't extract markdown code blocks)
- Verifies selective extraction

**Action**: Keep with improvements:
- Update name: `test_parse_commands_ignores_markdown_code_blocks`
- Add docstring: "Requirement: Parser must extract only environment tags, ignoring markdown code blocks"

---

### Test: `test_parse_command_with_special_chars` (Lines 200-214)
**Classification**: **GOOD**

**Current behavior**: Verifies brackets and special characters in command content work

**Why good**: Tests that raw content is preserved without XML escaping issues

**Action**: Keep with improvements:
- Update name: `test_parse_commands_preserves_special_characters`
- Add docstring: "Requirement: Parser must preserve special characters (<, >, &) in command content"

---

### Test: `test_parse_command_preserves_whitespace` (Lines 216-232)
**Classification**: **GOOD** (highlighted in task doc)

**Current behavior**: Verifies indentation in Python code is preserved

**Why good**: Tests actual requirement with structure verification

**Action**: Keep as-is (already good), just add docstring:
- Add docstring: "Requirement: Parser must preserve exact indentation for code blocks"

---

### Test: `test_parse_various_env_names` (Lines 234-260)
**Classification**: **GOOD**

**Current behavior**: Verifies different environment names are parsed

**Why good**: Tests that env name matching is general

**Action**: Keep with improvements:
- Update name: `test_parse_commands_extracts_various_environment_names`
- Add docstring: "Requirement: Parser must handle any word-character environment name (bash, python3, sh, editor, etc.)"

---

### Test: `test_parse_python_with_less_than` (Lines 262-276)
**Classification**: **GOOD**

**Current behavior**: Verifies `<` in Python code doesn't break parsing

**Why good**: Tests edge case that could break regex

**Action**: Keep with improvements:
- Update name: `test_parse_commands_handles_less_than_in_content`
- Add docstring: "Requirement: Parser must handle < character in command content without breaking tag matching"

---

## agent/src/format.rs

### Test: `test_format_system_prompt` (Lines 237-248)
**Classification**: **NEEDS-IMPROVEMENT**

**Current problems**:
1. Checks for hardcoded header string "=== SYSTEM ===" (line 245)
2. Checks that content appears in output (line 246) - trivial
3. Negative assertion checking timestamp NOT in output (line 247)

**What it should do**:
- Verify format structure is parseable/consistent
- Verify required information is present
- If format has a spec, verify compliance

**Rewrite needed**: Yes - See task doc appendix for format_event tests

---

### Test: `test_format_llm_call_runtime` (Lines 250-279)
**Classification**: **NEEDS-IMPROVEMENT**

**Current problems**:
1. Checks for exact header format "[LLM Call 0 (Initialization)]" (line 275)
2. Checks for exact cost format string (line 276)
3. Checks for header strings

**What it should do** (from task doc appendix):
- For Runtime mode: Verify it's human-readable (maybe regex patterns)
- Verify required data is present (call ID, cost, response)
- Don't check exact format strings

**Rewrite needed**: Yes - Apply pattern from task doc

---

### Test: `test_format_llm_call_inspect` (Lines 281-309)
**Classification**: **NEEDS-IMPROVEMENT**

**Current problems**:
1. String matching for exact format
2. Doesn't verify structure or completeness

**What it should do** (from task doc):
- For Inspect mode: Verify it's machine-parseable and contains all data
- Verify timestamp format is consistent
- Verify costs are formatted to 4 decimal places
- Use regex for format verification

**Rewrite needed**: Yes

---

### Test: `test_format_raw` (Lines 311-321)
**Classification**: **GOOD**

**Current behavior**: Verifies Raw mode outputs JSON with expected fields

**Why good**:
- Tests requirement (Raw mode = valid JSON)
- Structure-aware (checks for JSON fields)
- Would catch if JSON serialization broke

**Action**: Keep with improvements:
- Update name: `test_format_event_raw_mode_outputs_valid_json`
- Add docstring: "Requirement: Raw display mode must output valid JSON with type and content fields"

---

### Test: `test_format_session_summary` (Lines 323-349)
**Classification**: **NEEDS-IMPROVEMENT**

**Current problems**:
1. Checks for exact strings that duplicate implementation logic
2. String matching instead of structure verification

**What it should do**:
- Parse output and verify all required fields present
- Verify numeric formats are correct
- Use regex for structure validation

**Rewrite needed**: Consider - this is less critical than event formatting

---

## agent/src/types.rs

### Test: `test_session_id_display` (Lines 477-481)
**Classification**: **GOOD**

**Current behavior**: Verifies SessionId displays as number

**Why good**: Tests Display trait implementation requirement

**Action**: Keep with improvements:
- Update name: `test_session_id_displays_as_number`
- Add docstring: "Requirement: SessionId Display trait must format as decimal number"

---

### Test: `test_session_id_parse` (Lines 483-487)
**Classification**: **GOOD**

**Current behavior**: Verifies parsing string to SessionId

**Why good**: Tests FromStr trait requirement

**Action**: Keep with improvements:
- Update name: `test_session_id_parses_from_decimal_string`
- Add docstring: "Requirement: SessionId must parse from decimal number string"

---

### Test: `test_token_usage_add_assign` (Lines 489-508)
**Classification**: **GOOD**

**Current behavior**: Verifies AddAssign implementation for TokenUsage

**Why good**: Tests operator overload correctness

**Action**: Keep with improvements:
- Update name: `test_token_usage_add_assign_sums_all_fields`
- Add docstring: "Requirement: TokenUsage += must correctly sum all three token count fields"

---

### Test: `test_event_timestamp` (Lines 510-519)
**Classification**: **GOOD**

**Current behavior**: Verifies event.timestamp() returns correct timestamp

**Why good**: Tests accessor method requirement

**Action**: Keep with improvements:
- Update name: `test_event_timestamp_accessor_returns_event_timestamp`
- Add docstring: "Requirement: Event::timestamp() must return the timestamp field from the event"

---

## agent/src/budget.rs

All 8 budget tests (lines 97-233) follow the same pattern:

### Tests: `test_budget_*` (Lines 97-233)
**Classification**: **GOOD**

**Why all good**:
- Each tests a specific budget check requirement
- Uses concrete values and checks exact outcomes
- Tests boundary conditions (exact threshold, priority of checks)
- Not redundant with implementation (budget logic is non-trivial)

**Action**: Keep all with minor naming/docstring improvements:
1. `test_budget_ok_no_limits` → `test_check_budget_returns_ok_when_no_limits_set`
   - Doc: "Requirement: check_budget must return Ok when no limits configured"
2. `test_budget_ok_under_limits` → `test_check_budget_returns_ok_when_under_all_limits`
   - Doc: "Requirement: check_budget must return Ok when under both per-call and session limits"
3. `test_budget_exceeds_per_call_limit` → `test_check_budget_detects_per_call_limit_exceeded`
   - Doc: "Requirement: check_budget must return ExceedsPerCall when estimated cost > per-call limit"
4. `test_budget_exceeds_session_limit` → `test_check_budget_detects_session_limit_exceeded`
   - Doc: "Requirement: check_budget must return ExceedsSession when current + estimated > session limit"
5. `test_budget_warning_threshold` → `test_check_budget_warns_when_crossing_threshold`
   - Doc: "Requirement: check_budget must warn when projected total crosses warn threshold"
6. `test_budget_warning_only_when_crossing_threshold` → `test_check_budget_skips_warning_when_already_past_threshold`
   - Doc: "Requirement: check_budget must NOT warn again if already past threshold (warn once)"
7. `test_budget_warning_exact_threshold` → `test_check_budget_skips_warning_at_exact_threshold`
   - Doc: "Requirement: check_budget must NOT warn at exact threshold (only when exceeding)"
8. `test_budget_per_call_takes_priority` → `test_check_budget_checks_per_call_limit_before_session`
   - Doc: "Requirement: check_budget must check per-call limit first when both would be exceeded"

---

## agent/src/context.rs

### Test: `test_build_system_prompt_basic` (Lines 161-179)
**Classification**: **NEEDS-IMPROVEMENT**

**Current problems**:
1. Checks for hardcoded strings like "7aigent", "bash", "python", "editor"
2. Checks implementation details (what the prompt contains) instead of requirements

**What it should do**:
- Verify prompt structure (role is System)
- Verify it contains environment descriptions (without checking exact wording)
- Better: verify prompt can guide LLM to use environments (integration test with mock LLM?)

**Rewrite needed**: Consider - may be okay to just improve assertions

---

### Test: `test_build_system_prompt_with_restrictions` (Lines 181-204)
**Classification**: **NEEDS-IMPROVEMENT**

**Current problems**:
1. Checks for hardcoded strings that duplicate implementation
2. Checks that config values appear in prompt verbatim

**What it should do**:
- Verify that restrictions actually affect prompt content
- Use pattern matching instead of exact strings

**Rewrite needed**: Consider - may be okay with better assertions

---

### Test: `test_format_screen` (Lines 206-236)
**Classification**: **NEEDS-IMPROVEMENT**

**Current problems**:
1. Checks for hardcoded header formats "--- bash ---", "--- python ---"
2. Checks that content appears in output (trivial)

**What it should do**:
- Verify screen format is parseable and contains all sections
- Verify section boundaries are clear
- Use structure validation

**Rewrite needed**: Consider

---

### Test: `test_truncate_history` (Lines 238-261)
**Classification**: **GOOD**

**Current behavior**: Creates messages exceeding limit, verifies truncation keeps most recent

**Why good**:
- Tests actual requirement (keeps recent messages under limit)
- Verifies ordering is maintained
- Not trivial (truncation logic is non-trivial)

**Action**: Keep with improvements:
- Update name: `test_truncate_history_keeps_most_recent_under_limit`
- Add docstring: "Requirement: truncate_history must keep most recent messages in chronological order under character limit"

---

## Summary Statistics

**Total tests analyzed**: ~48 tests

**Classification breakdown**:
- **GOOD**: ~26 tests (54%) - Keep with minor naming/doc improvements
- **NEEDS-IMPROVEMENT**: ~13 tests (27%) - Rewrite with better assertions or integration validation
- **REMOVE**: ~0 tests (0%) - None identified for removal

**Priority rewrites** (from task doc):
1. `test_generate_simulated_message_*` family (3 tests) - Main example from task
2. `test_format_event_*` family (3 tests) - Format validation with structure
3. `test_format_screen` and context tests (3 tests) - Structure validation

**Tests to keep as-is or with minor improvements**:
- All parser tests (11 tests) - Already good, requirement-driven
- All budget tests (8 tests) - Already good, comprehensive
- Directory tree tests (3 tests) - Already good
- Types tests (4 tests) - Already good

**Missing requirement tests**:
- Integration test: Simulated message → parse → execute → verify effects
- Property-based tests for parser edge cases (fuzzing malformed tags)
- Format validation tests using regex/structure checks instead of string matching

---

## Next Steps

1. **Phase 2a**: Rewrite `test_generate_simulated_message` family (3 tests) with integration validation
2. **Phase 2b**: Rewrite `test_format_event` family (3 tests) with structure validation
3. **Phase 2c**: Improve remaining NEEDS-IMPROVEMENT tests (7 tests)
4. **Phase 2d**: Update all GOOD tests with naming convention and docstrings (26 tests)
5. **Phase 2e**: Add missing integration and property-based tests
6. **Phase 2f**: Verify `nix build .#agent` passes with all changes
