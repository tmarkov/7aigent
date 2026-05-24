# Agent test suite — 3 requirements with inadequate or missing tests

**Status**: DONE — all three have been addressed.

## Summary

Re-audit of the reworked agent test suite (post-refactor) identified 3
requirements whose tests did not fully prove the requirement was satisfied.
All three have now been resolved:

| Req | Verdict | Resolution |
|-----|---------|------------|
| A7  | PASS    | Properly tested in ControllerSpec (streaming chunks verified) |
| A47 | PASS    | Test added to ControllerSpec asserting `SevenAigentREPL.status()` + `_ans` wrapper expression |
| A20b| PASS    | Tested by `test_integration.py::TestSummaryRPC`, now runs via `nix flake check` (sandbox-e2e VM test) |

## Changes made

1. **A47 test added** (`agent/test/ControllerSpec.purs`): verifies that
   `getJuliaState` sends the ans-preserving `SevenAigentREPL.status()` wrapper
   expression to the kernel.

2. **Sandbox pytest integrated into nix**:
   - `test_launcher.py` runs during `nix build .#sandbox` (checkPhase)
   - `test_integration.py` runs during `nix flake check` (sandbox-e2e VM test)
   - Both now support `SANDBOX_LAUNCHER` env var for path flexibility.

3. **pytest added to VM test packages** (`test/sandbox-vm.nix`).

## Original audit (54/57 PASS)

The full re-audit found 54 of 57 agent requirements properly tested. The 3
listed above were the only gaps; they are now closed.

## Methodology

Classification used:
- **PASS**: tests pass ⟹ we can reasonably infer the requirement is satisfied
- **WEAK**: tests are "assigned" to the requirement but don't prove it
- **UNTESTED**: no test covers this requirement at all
