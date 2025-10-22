# ADR-011: Nix Unit Testing Framework

## Status

Accepted and Implemented (2025-10-21)

## Context

The jackpkgs flake contains Nix library functions and helpers (e.g., `mkRecipe`, `optionalLines`) that generate justfile content. Currently, these functions have no automated tests, relying instead on manual verification in consumer projects.

As the codebase grows and more helpers are added, the risk of regressions increases:
- Recent work (ADR-010) introduced `mkRecipe` and `optionalLines` helpers for justfile generation
- Changes to these helpers could break consumer justfiles without immediate detection
- Manual testing is time-consuming and error-prone
- Refactoring is risky without test coverage

**Prior Art:**
- The `jmmaloney4/latex-utils` project successfully uses `nix-unit` for testing flake-parts modules
- `nix-unit` is a mature testing framework from nix-community designed specifically for testing Nix expressions
- Many Nix projects use `nix-unit` for unit testing library functions

**Constraints:**
- Tests must run in CI (garnix or GitHub Actions)
- Test framework should integrate with Nix flakes
- Tests should be fast (pure Nix evaluation, no builds)
- Should support testing both pure functions and flake-parts module outputs

## Decision

Add `nix-unit` as the unit testing framework for jackpkgs.

Tests MUST:
- Live in a `tests/` directory at the repository root
- Use `nix-unit` test file format (`.nix` files returning test attrsets)
- Be runnable via `nix build .#checks.<system>.<test-name>`
- Cover all helper functions (starting with `mkRecipe` and `optionalLines`)
- Run automatically in CI on every PR

Tests SHOULD:
- Test both success cases and edge cases
- Include descriptive test names
- Be organized by module/feature (one test file per module)
- Use a `tests/test-helpers.nix` for shared test utilities

### Scope

**In Scope:**
- Testing helper functions (`mkRecipe`, `optionalLines`)
- Testing justfile generation logic
- Testing pure Nix functions in `lib/`
- Setting up CI integration

**Out of Scope:**
- Integration testing of actual justfile execution
- Testing external dependencies (treefmt, pre-commit, etc.)
- Performance testing

## Consequences

### Benefits
- **Regression prevention:** Catch breaking changes before they reach consumers
- **Refactoring confidence:** Safe to improve code with test coverage
- **Documentation:** Tests serve as executable examples of how to use helpers
- **Faster development:** Quick feedback loop for development (no need to test in consumer projects)
- **CI validation:** Automated verification on every PR
- **Maintainability:** Easier to onboard contributors with clear test examples

### Trade-offs
- **Setup overhead:** Initial investment to write test infrastructure
- **Maintenance burden:** Tests need to be updated when intentionally changing behavior
- **Learning curve:** Contributors need to understand nix-unit syntax
- **CI time:** Additional checks add to CI runtime (though Nix evaluation is fast)

### Risks & Mitigations
- **Risk:** Tests become stale or get skipped when rushing features
  - **Mitigation:** Make CI required for merging; tests are fast enough to not be a bottleneck
- **Risk:** Over-testing implementation details instead of behavior
  - **Mitigation:** Focus on testing public API (helper outputs), not internal implementation
- **Risk:** Flaky tests or environment-specific issues
  - **Mitigation:** Keep tests pure (no I/O, no network); pin nixpkgs version

## Alternatives Considered

### Alternative A — NixOS VM Tests
- Use NixOS VM tests to actually run `just` commands
- Pros: End-to-end validation; tests real behavior
- Cons: Much slower (builds VMs); overkill for testing string generation; harder to debug
- Why not chosen: Too heavy for unit testing pure functions; better suited for integration testing later

### Alternative B — nixpkgs lib.runTests
- Use built-in `nixpkgs.lib.runTests` function
- Pros: No external dependencies; simple
- Cons: Limited features; poor error messages; no structured output; not widely adopted
- Why not chosen: nix-unit provides better DX with detailed error messages and standard test format

### Alternative C — Manual Testing Only
- Continue relying on manual testing in consumer projects
- Pros: No setup overhead; no test maintenance
- Cons: Slow feedback; easy to miss regressions; hard to refactor safely
- Why not chosen: Not sustainable as codebase grows; recent indentation issues could have been caught with tests

### Alternative D — Shell Script Tests
- Write shell scripts that call `nix eval` and assert outputs
- Pros: Language-agnostic; familiar to many developers
- Cons: Verbose; poor error messages; no integration with Nix tooling
- Why not chosen: nix-unit is purpose-built for testing Nix and integrates better

## Implementation Plan

### Phase 1: Setup nix-unit Infrastructure (1-2 hours)
1. Add `nix-unit` flake input to `flake.nix`
2. Create `tests/` directory structure
3. Add test helper utilities in `tests/test-helpers.nix`
4. Configure checks output in `flake.nix` to expose tests
5. Document how to run tests locally (README or contributing guide)

### Phase 2: Write Initial Tests (2-3 hours)
6. Write `tests/mkRecipe.nix` to test `mkRecipe` helper:
   - Test basic recipe with single command
   - Test recipe with multiple commands
   - Test recipe with empty commands list
   - Test proper indentation (4 spaces for commands)
   - Test blank line insertion
7. Write `tests/optionalLines.nix` to test `optionalLines` helper:
   - Test with condition true (lines included)
   - Test with condition false (empty list)
   - Test with empty lines list
8. Run tests locally and fix any failures

### Phase 3: CI Integration (30 min)
9. Update `.github/workflows/` or `garnix.yaml` to run checks
10. Verify tests run in CI on a test PR

### Phase 4: Documentation (30 min)
11. Update `AGENTS.md` or `CONTRIBUTING.md` with testing guidelines
12. Add comment in this ADR with link to test examples

### Rollout
- No rollback needed (purely additive)
- Tests can be added incrementally without breaking existing functionality
- Future helpers should include tests from the start

### Dependencies
- `nix-unit` from nix-community (flake input)
- No blocking dependencies

## Related

- ADR-010: Justfile Generation Helpers (the helpers we're testing)
- Module: `modules/flake-parts/just.nix` (contains `mkRecipe` and `optionalLines`)
- Example: `jmmaloney4/latex-utils` (reference implementation of nix-unit testing pattern)
- nix-unit repo: https://github.com/nix-community/nix-unit

## Implementation Notes

### What Was Built

All phases of the implementation plan have been completed:

1. **Infrastructure Setup:**
   - Added `nix-unit` as flake input with `inputs.nixpkgs.follows`
   - Created `tests/` directory with modular structure
   - Created `tests/test-helpers.nix` with shared utilities
   - Configured checks in `flake.nix` to expose tests via `mkTest` helper function
   - Tests automatically run with `nix flake check`
   - **CI Integration:** Tests run automatically in CI via `nix flake check` (Phase 3 complete)

2. **Test Suites:**
   - **mkRecipe Tests** (`tests/mkRecipe.nix`): 12/12 tests passing
     - Basic recipe generation with single/multiple commands
     - Empty commands edge case
     - Special characters in comments
     - Interpolation syntax (just variables)
     - Indentation validation (4 spaces)
     - Trailing blank lines
     - Recipe/comment positioning
     - Backslash handling for multiline commands
     - Silent commands (@echo)
     - Just invocations
   
   - **optionalLines Tests** (`tests/optionalLines.nix`): 14/14 tests passing
     - Conditional inclusion (true/false)
     - Empty list handling
     - Single line cases
     - Complex condition expressions
     - Special characters in lines
     - List concatenation patterns
     - Chaining multiple conditionals
     - Integration with lib functions
     - Type consistency checks

3. **Running Tests:**
   ```bash
   # Run all checks (including tests)
   nix flake check
   
   # Run specific test
   nix build .#checks.<system>.mkRecipe-test
   nix build .#checks.<system>.optionalLines-test
   
   # Quick evaluation check (no build)
   nix flake check --no-build
   ```

4. **Test Implementation Pattern:**
   - Tests are imported with arguments during flake evaluation
   - Test results are serialized to Nix expressions using `lib.generators.toPretty`
   - nix-unit runs in a `pkgs.runCommand` derivation
   - Success creates an empty output file
   - Failure stops the build with detailed error messages

### Lessons Learned

- nix-unit expects attrsets with `expr` and `expected` fields
- Tests need to be evaluated with arguments before passing to nix-unit
- `lib.generators.toPretty` is effective for serializing test cases
- All 26 tests pass, validating the correctness of ADR-010 helpers
- **String comparison tests:** Using indented strings (`''...''`) for `expected` values works reliably. Nix's indented string handling is well-defined and stable. While `lib.strings.stripStringMargin` could be used for extra explicitness, the current pattern is idiomatic and maintainable.

### Future Work

- Module evaluation testing framework (see issue #76)
- Add tests for future helper functions
- Consider integration tests for actual justfile execution (e.g., running recipes in test environment)
- Document testing guidelines in AGENTS.md
- Extend test coverage to other modules (python, quarto, etc.)

---

Author: jack  
Date: 2025-10-21  
Implemented: 2025-10-21

