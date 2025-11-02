# ADR-014: Adopt Official nix-unit Flake-Parts Module

## Status

Proposed

## Context

ADR-011 established nix-unit as the testing framework for jackpkgs and implemented a custom integration using `pkgs.runCommand` to wrap nix-unit invocations. This implementation has encountered sandbox permission issues in CI environments.

### The Problem

When running tests in CI (specifically on Linux), the custom `mkTest` implementation fails with:
```
error: creating directory '/nix/var/nix/profiles': Permission denied
warning: `--gc-roots-dir' not specified
```

This occurs because nix-unit, when run inside a Nix build sandbox via `runCommand`, attempts to access `/nix/var/nix/profiles` for garbage collection roots and state management. The build sandbox restricts access to these directories for security and reproducibility.

### Discovery of Official Solution

Research into this issue revealed that the nix-unit project **provides an official flake-parts module** (`inputs.nix-unit.modules.flake.default`) that properly handles sandbox isolation. This module:

1. Sets up a proper isolated Nix environment within the sandbox:
   ```nix
   export HOME="$(realpath .)"
   unset NIX_STORE
   export NIX_STORE_DIR=${builtins.storeDir}
   export NIX_REMOTE="$HOME/storedata"
   ```

2. Provides additional features:
   - `perSystem.nix-unit.tests` option for declaring tests
   - `perSystem.nix-unit.inputs` for passing flake inputs to avoid re-downloads
   - `perSystem.nix-unit.allowNetwork` for tests requiring network access
   - Automatic integration with `checks` output
   - Template via `nix flake init -t github:nix-community/nix-unit#flake-parts`

3. Is maintained by the nix-unit project team, ensuring compatibility with future versions

### Current State

The custom implementation in `flake.nix:136-150` defines a `mkTest` helper that:
- Uses `pkgs.runCommand` to create test derivations
- Serializes test cases using `lib.generators.toPretty`
- Runs nix-unit on the serialized test file
- Works locally on macOS but fails in Linux CI due to sandbox restrictions

**Prior Art:**
- The nix-unit project's own `lib/modules/flake/system.nix` demonstrates the correct pattern
- Other projects using nix-unit successfully use the official module
- The project `jmmaloney4/latex-utils` (mentioned in ADR-011) may use this pattern

**Constraints:**
- Must work in GitHub Actions CI on Linux
- Must maintain existing test structure in `tests/` directory
- Must integrate with flake-parts (already in use)
- Should not require rewriting existing tests

## Decision

Migrate from the custom nix-unit integration to the **official nix-unit flake-parts module**.

The integration MUST:
- Import `inputs.nix-unit.modules.flake.default` in the flake's imports list
- Declare tests using `perSystem.nix-unit.tests` instead of custom `mkTest` wrapper
- Maintain existing test files in `tests/` directory without modification
- Continue to expose tests via `checks` output for CI integration

The integration SHOULD:
- Use `perSystem.nix-unit.inputs` to pass required flake inputs if needed
- Set `perSystem.nix-unit.allowNetwork = false` (default) to keep tests pure
- Configure per-system tests for `mkRecipe`, `optionalLines`, and other helpers
- Leverage the module's automatic check generation

### Scope

**In Scope:**
- Replacing custom `mkTest` function with official module
- Updating flake imports to include nix-unit module
- Migrating test declarations to `perSystem.nix-unit.tests`
- Updating ADR-011 implementation notes to reference this ADR
- Verifying tests pass in Linux CI

**Out of Scope:**
- Rewriting existing test files (they remain in `tests/` directory)
- Changing test format or structure
- Adding new tests (covered separately)
- Module evaluation testing (future work per ADR-011)

## Consequences

### Benefits

- **CI Compatibility:** Fixes sandbox permission errors in Linux CI environments
- **Official Support:** Leverages maintained integration from nix-unit project
- **Robustness:** Properly handles edge cases (isolated store, gc-roots, environment variables)
- **Features:** Gains access to input overrides and network control options
- **Simplicity:** Removes custom sandbox setup code from our flake
- **Future-Proof:** Automatic compatibility with nix-unit updates
- **Best Practices:** Aligns with recommended nix-unit integration pattern

### Trade-offs

- **Refactoring Required:** Need to restructure how tests are declared in `flake.nix`
- **Module Dependency:** Adds dependency on nix-unit's flake-parts module structure
- **Learning Curve:** Team needs to understand module's options (though well-documented)
- **Less Control:** Delegates sandbox setup to upstream module (generally good, but removes customization)

### Risks & Mitigations

- **Risk:** Migration introduces new bugs or breaks existing tests
  - **Mitigation:** Test locally on both macOS and Linux before merging; existing test files don't change
- **Risk:** Official module has different behavior or limitations
  - **Mitigation:** Module is well-tested by nix-unit project; provides more features than custom implementation
- **Risk:** Future nix-unit module changes break our setup
  - **Mitigation:** Flake inputs are locked; we control when to update
- **Risk:** Team unfamiliar with new configuration structure
  - **Mitigation:** Update ADR-011 with new pattern; document in implementation plan

## Alternatives Considered

### Alternative A — Fix Custom Implementation with Environment Variables

Apply the workaround discovered during investigation:
```nix
export NIX_STATE_DIR=$TMPDIR/nix-state
mkdir -p $NIX_STATE_DIR
```
Or the more robust pattern:
```nix
export HOME="$(realpath .)"
unset NIX_STORE
export NIX_STORE_DIR=${builtins.storeDir}
export NIX_REMOTE="$HOME/storedata"
```

- **Pros:** Minimal changes; keeps custom implementation; simpler diff
- **Cons:** Reimplements what official module provides; misses additional features; requires maintenance if nix-unit requirements change
- **Why not chosen:** Official module is the proper solution; maintaining custom sandbox setup is unnecessary technical debt

### Alternative B — Use Different Testing Framework

Switch to `lib.runTests`, `nixpkgs.testers`, or NixOS VM tests

- **Pros:** No dependency on nix-unit; potentially simpler
- **Cons:** ADR-011 already justified nix-unit choice; breaking change; worse developer experience
- **Why not chosen:** nix-unit is the right tool; we just need to use it correctly

### Alternative C — Disable Sandbox for Tests

Configure tests to run with `sandbox = false` or `sandbox = "relaxed"`

- **Pros:** Would bypass permission issues
- **Cons:** Defeats purpose of Nix sandbox; unreproducible tests; security concerns; not supported in many CI environments
- **Why not chosen:** Sandbox is a Nix best practice; proper solution is to work within sandbox

### Alternative D — Keep Custom Implementation, Only Fix for CI

Apply environment variable fix only in CI-specific configuration

- **Pros:** Minimal local changes
- **Cons:** Divergent behavior between local and CI; masks the real issue; still misses official module features
- **Why not chosen:** Want consistent behavior everywhere; official module is superior solution

## Implementation Plan

### Phase 1: Update Flake Configuration (30 min)

1. **Import official module** in `flake.nix` imports list:
   ```nix
   imports = [
     ./modules/flake-parts
     (import ./modules/flake-parts/all.nix {jackpkgsInputs = inputs;})
     inputs.nix-unit.modules.flake.default  # Add this
   ];
   ```

2. **Remove custom `mkTest` function** from `flake.nix` (lines ~136-150)

3. **Migrate test declarations** from custom checks to module pattern:
   ```nix
   perSystem = { config, pkgs, lib, system, ... }: {
     nix-unit = {
       package = inputs.nix-unit.packages.${system}.default;
       tests = {
         mkRecipe = import ./tests/mkRecipe.nix {
           inherit lib;
           testHelpers = import ./tests/test-helpers.nix { inherit lib; };
         };
         mkRecipeWithParams = import ./tests/mkRecipeWithParams.nix {
           inherit lib;
           testHelpers = import ./tests/test-helpers.nix { inherit lib; };
         };
         optionalLines = import ./tests/optionalLines.nix {
           inherit lib;
           testHelpers = import ./tests/test-helpers.nix { inherit lib; };
         };
       };
     };

     # Keep existing justfile validation checks as-is
     # (they're already using separate pattern)
   };
   ```

4. **Verify check names** remain accessible via `.#checks.<system>.<name>`

### Phase 2: Local Testing (15 min)

5. Run tests locally on macOS:
   ```bash
   nix flake check
   nix build .#checks.aarch64-darwin.nix-unit  # New check name
   ```

6. Test on Linux if possible (or rely on CI):
   ```bash
   nix build .#checks.x86_64-linux.nix-unit
   ```

### Phase 3: CI Validation (10 min)

7. Push to feature branch and verify CI passes
8. Confirm all test checks run successfully on Linux

### Phase 4: Documentation Updates (15 min)

9. Update ADR-011 "Implementation Notes" section to reference ADR-014
10. Add note about official module adoption and link to this ADR
11. Update any testing documentation if it references `mkTest` directly

### Rollout

- **Migration Strategy:** Single PR with all changes (atomically migrate to new module)
- **Rollback Plan:** Revert PR if issues arise; can return to custom implementation with env var fix as temporary measure
- **Validation:** All existing tests must pass; CI must succeed on Linux

### Dependencies

- nix-unit flake input (already present)
- No additional dependencies required

### Owner

- Jack (implementation and review)
- Timeline: 1-2 hours total work

## Related

- **Amends:** ADR-011 (Nix Unit Testing Framework)
  - ADR-011 established nix-unit as the framework
  - ADR-014 improves the integration by adopting the official module
- **References:**
  - nix-unit official docs: https://nix-community.github.io/nix-unit/
  - flake-parts example: https://nix-community.github.io/nix-unit/examples/flake-parts.html
  - Official module source: https://github.com/nix-community/nix-unit/blob/main/lib/modules/flake/system.nix
- **Issues:**
  - CI error: "Permission denied: /nix/var/nix/profiles"

## Follow-up Findings (2025-10)

- **CI failure analysis:** In October 2025 CI began failing during `.#checks.x86_64-linux.nix-unit` with repeated DNS errors (`Could not resolve host: cache.nixos.org/github.com`). Despite the runner having general outbound access, the nix-unit derivation was evaluating the flake in isolation and trying to refetch inputs that were not present in the sandbox.
- **Mitigation:** Propagating the flake's locked inputs to the nix-unit module via `perSystem.nix-unit.inputs` resolved the problem. We now compute `builtins.removeAttrs inputs ["self"]`, normalise any flake inputs to their realised `outPath`, and assign the result to `nix-unit.inputs` (`flake.nix:142-149`), ensuring the derivation never attempts network fetches.
- **Upstream guidance:** The nix-unit flake-parts documentation highlights this requirement and provides the same pattern (<https://nix-community.github.io/nix-unit/examples/flake-parts.html>). Issue nix-community/nix-unit#213 documents identical behaviour and the maintainers recommend specifying `perSystem.nix-unit.inputs` (<https://github.com/nix-community/nix-unit/issues/213>).
- **Testing notes:** On macOS we can build the native check directly; cross-building the Linux check still requires access to an `x86_64-linux` builder (e.g., RunsOn runner or remote builder).

## Appendix A: Transitive Dependency Resolution Issue (2025-11)

### Problem Statement

In November 2025, CI continued to fail with network errors despite the October mitigation:

```
error: Failed to open archive (Source threw exception: error: unable to download
'https://github.com/hercules-ci/flake-parts/archive/af66ad14b28a127c5c0f3bbb298218fc63528a18.tar.gz':
Could not resolve hostname (6) Could not resolve host: github.com)
```

The specific SHA `af66ad14b28a127c5c0f3bbb298218fc63528a18` corresponds to `flake-parts_2` in the lock file—this is **nix-unit's own flake-parts dependency**, not jackpkgs' flake-parts input.

### Root Cause Analysis

The issue was that jackpkgs was passing **all** flake inputs (excluding only `self`) to `perSystem.nix-unit.inputs`, including the `nix-unit` input itself:

```nix
nixUnitInputs = builtins.mapAttrs (_: sanitizeInput) (builtins.removeAttrs inputs ["self"]);
```

When the nix-unit module invokes the test flake with `--override-input nix-unit /nix/store/...-source`, it causes Nix to re-evaluate the nix-unit flake source. This re-evaluation triggers dependency resolution for nix-unit's own inputs:
- `flake-parts` (nix-unit's version, not jackpkgs')
- `treefmt-nix` (a dependency of nix-unit, not jackpkgs)
- `nixpkgs` (nix-unit's version)

Since these transitive dependencies are not present in the sandbox and network access is disabled, the build fails with DNS resolution errors.

### Solution

Provide all of nix-unit's required inputs using both top-level and nested input overrides:

```nix
nixUnitInputs =
  (builtins.mapAttrs (_: sanitizeInput) (builtins.removeAttrs inputs ["self"]))
  // {
    # nix-unit expects an input named 'treefmt-nix', but we call it 'treefmt'
    treefmt-nix = sanitizeInput inputs.treefmt;
    # Override nix-unit's locked dependencies using nested syntax
    "nix-unit/flake-parts" = sanitizeInput inputs.flake-parts;
    "nix-unit/nixpkgs" = sanitizeInput inputs.nixpkgs;
    "nix-unit/treefmt-nix" = sanitizeInput inputs.treefmt;
  };
```

**Rationale:** The nix-unit flake has its own `flake.lock` with specific commits for its dependencies:
- `flake-parts` at commit `af66ad14...` (different from jackpkgs' version)
- `nixpkgs` at its own pinned version
- `treefmt-nix` (which jackpkgs calls `treefmt`)

When nix-unit's flake.nix is evaluated in the sandbox, it reads its own flake.lock and tries to fetch those specific commits. Top-level overrides aren't sufficient—we must use nested override syntax (`nix-unit/input-name`) to replace nix-unit's locked dependencies with our already-fetched versions.

### Upstream Precedent

This pattern directly implements the solution from nix-community/nix-unit#224, where a user encountered identical DNS errors when nix-unit tried to fetch `treefmt-nix`.

From the issue: "nix-unit flake's inputs contain treefmt-nix, so you have to provide all inputs there in the perSystem.nix-input.inputs object."

The key insight is that you must provide **all of nix-unit's transitive dependencies** under the names it expects, even if you have the same repository under a different name in your flake.

### Technical Details

When `--override-input nix-unit <path>` is passed, Nix:
1. Treats `<path>` as a flake source directory
2. Reads its `flake.nix` and evaluates its inputs
3. Looks for those inputs in the provided `--override-input` arguments
4. Falls back to fetching from network if inputs are missing
5. Fails in the sandbox because network is disabled

By providing all inputs that nix-unit's flake.nix expects (including the `treefmt-nix` alias), we ensure that step 3 succeeds and step 4 is never reached.

The aliasing and nested override techniques work together:
1. **Top-level aliases** (like `treefmt-nix`) make inputs available under the names nix-unit expects
2. **Nested overrides** (like `nix-unit/flake-parts`) replace nix-unit's locked dependencies with our versions
3. Both map input names to `/nix/store/...` paths, preventing any network access

The nested syntax `nix-unit/flake-parts` tells Nix: "when evaluating the nix-unit flake, override its `flake-parts` input with this path" rather than using the commit specified in nix-unit's flake.lock.

### References

- Issue: nix-community/nix-unit#224 (<https://github.com/nix-community/nix-unit/issues/224>)
- Related: nix-community/nix-unit#213 (<https://github.com/nix-community/nix-unit/issues/213>)
- Implementation: `flake.nix:142-162`

---

Author: jack (with Claude Code assistance)
Date: 2025-10-29
PR: TBD
