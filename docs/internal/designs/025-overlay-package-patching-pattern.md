---
id: ADR-025
title: "Overlay Package Patching Pattern"
status: proposed
date: 2026-02-12
---
# ADR-025: Overlay-First Package Patching for Flake Modules

## Status

Proposed (2026-02-12)

## Context

### Problem

Issue #145 exposed a deprecation warning from `lib.getExe` when `pulumi-bin` did not define `meta.mainProgram`.

The first implementation path attempted to patch this in flake modules (`pulumi.nix`, then `just.nix`) with a local wrapper and module options. Review feedback highlighted that this solved only selected call sites and introduced duplication.

### Constraints

- jackpkgs is a flake that exposes both an overlay and flake-parts modules.
- Consumers may use packages directly from `pkgs` via `jackpkgs.overlays.default`.
- Module defaults should follow `config.jackpkgs.pkgs` to preserve overlay propagation.
- Fixes to package metadata should apply consistently across all consumers, not only within one module.

### Relevant Prior Design

- `pkgs.nix` exists to allow consumers to inject overlayed nixpkgs through `jackpkgs.pkgs`.
- Module package defaults are intended to reference `config.jackpkgs.pkgs`, not raw `pkgs`, when they need consumer overlays.

## Decision

jackpkgs SHOULD apply package-level patches in the overlay first, and modules SHOULD consume the patched package from `config.jackpkgs.pkgs`.

Normative guidance:

- Package metadata or behavior fixes (for example, `meta.mainProgram`) MUST be implemented in `overlays/default.nix` when possible.
- Flake-parts modules MUST NOT introduce one-off wrapper packages for issues that are fundamentally package-level.
- Module defaults SHOULD use `config.jackpkgs.pkgs.<name>` to inherit consumer overlays and jackpkgs overlay patches.
- New module options like `jackpkgs.<module>.package` SHOULD be introduced only when there is a real per-module customization need beyond selecting the package from `config.jackpkgs.pkgs`.

Scope:

- In scope: package patching strategy and module consumption pattern.
- Out of scope: replacing existing module customization options that are intentionally user-configurable.

## Consequences

### Benefits

- Single source of truth for package fixes.
- All overlay consumers receive the fix automatically.
- Simpler module code and fewer cross-module consistency issues.
- Better long-term maintainability as more modules are added.

### Trade-offs

- Overlay changes have broader impact and require careful validation.
- Some fixes may still require module-level options if behavior is module-specific.

### Risks & Mitigations

- Risk: accidental broad impact from overlay override.
  - Mitigation: keep overrides minimal, metadata-focused when possible, and run targeted module checks.
- Risk: contributors repeat module-local patching.
  - Mitigation: reference this ADR in future reviews and module authoring guidance.

## Alternatives Considered

### Alternative A - Module-local wrapper package (initial path)

- Pros:
  - Fast local fix in one module.
  - No overlay change required.
- Cons:
  - Inconsistent behavior across modules.
  - Easy to miss call sites (as happened in `just.nix`).
  - Duplication of package-fix logic.
- Why not chosen:
  - Wrong abstraction layer for a package-level concern.

### Alternative B - Add `jackpkgs.pulumi.package` as module-level source of truth

- Pros:
  - Better than duplicated wrappers in multiple places.
  - Can centralize per-module selection.
- Cons:
  - Still does not help non-module overlay consumers.
  - Adds configuration surface area that may be unnecessary.
- Why not chosen:
  - Solves module consistency, but not the broader package consistency problem.

## Course Correction Notes (What We Learned)

- Misstep 1: We fixed the warning only inside `pulumi.nix` with a wrapper.
  - Why this was insufficient: `just.nix` still referenced unpatched `pulumi-bin`.
- Misstep 2: We considered introducing a new module-level package option as the primary fix.
  - Why this was insufficient: package-level metadata issues should not depend on module usage.
- Adjustment: move the patch to the overlay, then consume through `config.jackpkgs.pkgs` in modules.

This sequence is intentional to preserve history and reviewer context.

## Generalization for Future Modules

When a module depends on a package that needs patching:

1. Determine if the issue is package-level (metadata, build, runtime path, wrapper behavior).
2. If package-level, patch it in `overlays/default.nix`.
3. Ensure module defaults reference `config.jackpkgs.pkgs.<package>`.
4. Add module-level package options only for legitimate per-module customization.
5. Verify at least one module path and one non-module package path where practical.

This pattern applies to existing modules such as `fmt`, `just`, `pre-commit`, `pulumi`, `nodejs`, `python`, and future modules.

## Implementation Plan

- Update overlay package definition(s) for the affected package.
- Remove module-local wrappers that duplicate package patch logic.
- Keep module defaults aligned with `config.jackpkgs.pkgs`.
- Add or update tests/checks to cover the fixed behavior path.

## Related

- Issue: https://github.com/jmmaloney4/jackpkgs/issues/145
- PR: https://github.com/jmmaloney4/jackpkgs/pull/150
- Related module: `modules/flake-parts/pkgs.nix`
- Related overlay: `overlays/default.nix`

---

Author: OpenCode (with reviewer feedback)
Date: 2026-02-12
PR: #150
