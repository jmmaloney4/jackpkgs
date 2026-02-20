---
id: ADR-029
title: "Unified Quality Gate Controls"
status: proposed
date: 2026-02-20
---

# ADR-029: Unified Quality-Gate Controls under `jackpkgs.checks`

## Status

Accepted (2026-02-20)

## Context

### 1. Problem

jackpkgs provides two separate surfaces for quality gating: `jackpkgs.checks`
(CI check derivations via `nix flake check`) and `jackpkgs.pre-commit`
(pre-commit hooks). Both surfaces run the same tools — mypy, ruff, pytest, tsc,
vitest — but expose independent enable/disable and `extraArgs` options. This
means:

- Disabling mypy requires setting *two* options: `jackpkgs.checks.python.mypy.enable = false`
  **and** `jackpkgs.pre-commit.python.mypy.enable = false`.
- Enabling numpydoc (opt-in) requires the same two-option dance.
- `extraArgs` can silently diverge between surfaces.
- Users must understand the internal structure of both `nix-pre-commit` hooks
  and the checks derivation system in order to configure a single logical tool.

### 2. Evolution of the duplication

ADR-016 introduced `checks.nix` as the CI checks module. `pre-commit.nix`
already existed with only `mypy` and `numpydoc` hooks. As full parity was added
across issues #165, #166, and #168, both surfaces gained matching hook/check
pairs for every tool, making independent option trees an increasingly bad UX.

### 3. Interim "mirror" mechanism

Issue #168 introduced `jackpkgs.checks.python.mirrorPreCommit.{enable,gates}`
as an opt-in mechanism to copy pre-commit gate states into checks. This solves
the symptom but not the cause: it adds a third option to toggle, makes the
directionality of the sync confusing, and still requires users to understand
both namespaces. This mechanism is removed by this ADR.

### 4. Constraints

- **Backward compatibility is not required** for these options — they were
  introduced in the same development cycle (#165, #166, #168) and have no known
  downstream consumers at stable release tags.
- **Nix module scope constraint:** `jackpkgs.checks` is a top-level flake-parts
  module option; `jackpkgs.pre-commit` per-system options are declared via
  `mkDeferredModuleOption`. Whether top-level `config.jackpkgs.checks` is
  accessible from within a deferred per-system context requires verification
  (see Risk R1).
- **Per-surface package overrides must remain possible.** `jackpkgs.pre-commit`
  retains package and nodeModules configuration so callers can point a hook at a
  custom environment without affecting the CI check.

______________________________________________________________________

## Decision

### Core Principle

`jackpkgs.checks.<tool>.enable` and `jackpkgs.checks.<tool>.extraArgs` are the
**single source of truth** for each tool. Both the CI check derivation and the
pre-commit hook read them. `jackpkgs.pre-commit` retains only surface-specific
knobs: package overrides and nodeModules configuration.

The `jackpkgs.checks.python.mirrorPreCommit` block is **removed entirely**.

### New `jackpkgs.checks` Option Shape

```nix
jackpkgs.checks = {
  enable = true;  # auto: jackpkgs.python.enable || jackpkgs.nodejs.enable

  python = {
    enable = true;  # auto: jackpkgs.python.enable

    mypy     = { enable = true;  extraArgs = []; };
    ruff     = { enable = true;  extraArgs = ["--no-cache"]; };
    pytest   = { enable = true;  extraArgs = []; };
    numpydoc = { enable = false; extraArgs = []; };  # explicit opt-in
  };

  typescript.tsc = {
    enable      = true;  # auto: jackpkgs.nodejs.enable  ← changed from pulumi.enable
    nodeModules = null;
    packages    = null;
    extraArgs   = [];
  };

  vitest = {
    enable      = true;  # auto: jackpkgs.nodejs.enable  (unchanged)
    nodeModules = null;
    packages    = null;
    extraArgs   = [];
  };
};
```

**Removed from `jackpkgs.checks`:**

- `python.mirrorPreCommit.enable` and `python.mirrorPreCommit.gates`
- The outer `typescript.enable` (was auto-gated on `pulumi.enable`); replaced by
  `typescript.tsc.enable` directly

**Changed default:**

- `typescript.tsc.enable` now auto-enables when `jackpkgs.nodejs.enable = true`,
  not `jackpkgs.pulumi.enable`. Rationale: TypeScript checks require Node.js
  tooling in the Nix sandbox. Pulumi users who write TypeScript MUST also enable
  `jackpkgs.nodejs`; it therefore makes no sense for the tsc check to activate
  on pulumi alone.

### New `jackpkgs.pre-commit` Per-System Option Shape

```nix
jackpkgs.pre-commit = {
  enable            = true;   # unchanged
  treefmtPackage    = ...;    # unchanged
  nbstripoutPackage = ...;    # unchanged

  # Package overrides only — no enable, no extraArgs
  python.mypy.package     = <dev-tools env>;
  python.ruff.package     = <dev-tools env>;
  python.pytest.package   = <dev-tools env>;
  python.numpydoc.package = <dev-tools env>;

  typescript.tsc.package     = pkgs.nodePackages.typescript;
  typescript.tsc.nodeModules = null;

  javascript.vitest.package     = pkgs.nodejs;
  javascript.vitest.nodeModules = null;
};
```

**Removed from `jackpkgs.pre-commit`:**

- All `*.enable` options (one per tool: mypy, ruff, pytest, numpydoc, tsc, vitest)
- All `*.extraArgs` options (same six tools)

### How `pre-commit.nix` Reads Gate State

Inside `pre-commit.nix`'s config block, every hook reads enable and extraArgs
from the top-level `jackpkgs.checks` option:

```nix
# pre-commit.nix config block (within perSystem context)
let
  checksCfg = config.jackpkgs.checks;
in {
  settings.hooks.mypy = {
    enable = checksCfg.python.mypy.enable;
    entry  = "${pythonExe} mypy${escapeExtraArgs checksCfg.python.mypy.extraArgs}";
    # ...
  };
  settings.hooks.ruff = {
    enable = checksCfg.python.ruff.enable;
    entry  = "${ruffExe} check${escapeExtraArgs checksCfg.python.ruff.extraArgs}";
    # ...
  };
  # tsc, vitest, pytest, numpydoc follow the same pattern
}
```

### User-Facing UX After This Change

```nix
# Disable mypy in both CI checks and pre-commit with one switch:
jackpkgs.checks.python.mypy.enable = false;

# Enable numpydoc in both CI checks and pre-commit with one switch:
jackpkgs.checks.python.numpydoc.enable = true;

# Override ruff flags for both surfaces at once:
jackpkgs.checks.python.ruff.extraArgs = ["--no-cache" "--select" "ALL"];

# Override the pre-commit mypy package independently (still possible):
jackpkgs.pre-commit.python.mypy.package = myCustomEnv;
```

______________________________________________________________________

## Consequences

### Benefits

1. **Single switch per tool.** One option disables or enables a tool across all
   quality-gate surfaces.
2. **Single `extraArgs` per tool.** No silent drift between CI and pre-commit
   invocations of the same tool.
3. **Simpler mental model.** `jackpkgs.pre-commit` contains only *how* to run a
   tool (which package, which node_modules); `jackpkgs.checks` contains *whether*
   to run it and with *what arguments*.
4. **Removes accidental complexity.** The `mirrorPreCommit` three-way
   configuration interaction is eliminated.
5. **Per-surface package override preserved.** `jackpkgs.pre-commit.python.mypy.package`
   still allows pointing the hook at a custom environment without affecting the
   CI check derivation.

### Trade-offs

1. **Unified `extraArgs` is a slight semantic approximation.** A pre-commit hook
   runs on staged files; a CI check runs on the full workspace. In rare cases
   different flags may be desired. Users who need this can override the hook
   entry directly via `pre-commit.settings.hooks.<name>.entry` in their own
   flake module.
2. **Breaking change.** All `jackpkgs.pre-commit.python.*.enable` and `*.extraArgs`
   options are removed. This is acceptable because these options were introduced
   in the same development cycle as the old design (issue #168, no stable release).

### Risks & Mitigations

**R1 — `mkDeferredModuleOption` scope: can `pre-commit.nix` read `jackpkgs.checks`?**

`jackpkgs.pre-commit` per-system options are declared via `mkDeferredModuleOption`,
meaning option declarations and config expressions are evaluated in a
`perSystem.<system>` scope. The question is whether `config.jackpkgs.checks` —
a top-level module option — is accessible from within that scope.

- **Evidence it works:** `checks.nix` already reads `config.jackpkgs.python.enable`
  from within its own `config.perSystem` block. This works because flake-parts
  passes the top-level `config` argument through to deferred per-system modules.
- **Verification step:** During implementation, add a minimal guard assertion
  (`assert config ? jackpkgs && config.jackpkgs ? checks;`) in the pre-commit
  per-system config block and confirm it evaluates without error.
- **Fallback design:** If the reference does not resolve, `all.nix` can inject
  the values via `_module.args`:
  ```nix
  perSystem.args.jackpkgsChecksCfg = config.jackpkgs.checks;
  ```
  `pre-commit.nix` then reads from `args.jackpkgsChecksCfg` instead of
  `config.jackpkgs.checks` directly. This is guaranteed to work because `args`
  is explicitly threaded through the module system.

**R2 — Option removal breaks in-flight consumer code**

Removing `jackpkgs.pre-commit.python.*.enable` and `*.extraArgs` is a breaking
change for any consumer that adopted the post-#168 pre-commit option shape.

- **Mitigation:** These options were introduced in the same development cycle
  (issue #168, not present in any stable release tag). Removal is acceptable;
  the breaking change is documented in the associated PR.

**R3 — `typescript.tsc` auto-enable default change**

Changing the default from `jackpkgs.pulumi.enable` to `jackpkgs.nodejs.enable`
means a project with `jackpkgs.pulumi.enable = true` and
`jackpkgs.nodejs.enable = false` silently loses tsc checks.

- **Mitigation:** This is the correct behaviour — such a project has no Node.js
  in scope and cannot have working tsc checks anyway. The change is a bug fix,
  not a regression.

______________________________________________________________________

## Alternatives Considered

### Alternative A — Expand the `mirrorPreCommit` Opt-In Mechanism

Extend `mirrorPreCommit` to cover `extraArgs` as well as `enable`.

- **Pros:** Non-breaking; gradual opt-in.
- **Cons:** Adds more options to achieve what should be the default; users still
  need to know both namespaces; `extraArgs` mirroring requires another option
  shape. The root problem (two namespaces for one logical concern) remains.
- **Why not chosen:** Treats the symptom rather than the cause.

### Alternative B — Make `jackpkgs.pre-commit` a Sub-Namespace of `jackpkgs.checks`

Rename `jackpkgs.pre-commit` to `jackpkgs.checks.pre-commit`.

- **Pros:** Makes the parent-child relationship explicit in the option tree.
- **Cons:** Larger breaking change; `pre-commit.nix` handles concerns (treefmt,
  nbstripout) that do not logically belong under `checks`.
- **Why not chosen:** Out of scope; the current top-level split is acceptable.

### Alternative C — Unify `enable` Only; Keep `extraArgs` Per-Surface

Single `enable` under `jackpkgs.checks`; separate `extraArgs` in each surface.

- **Pros:** Accommodates per-surface flag differences without escape-hatch
  gymnastics.
- **Cons:** Reintroduces dual-namespace cognitive load for a common case (tuning
  ruff flags). The direct hook-entry override escape hatch covers the edge cases.
- **Why not chosen:** The unified `extraArgs` trade-off is acceptable; the
  design is cleaner without split configuration.

______________________________________________________________________

## Related

- **Issues:** #168 (pre-commit / checks parity), #165 (mypy env alignment),
  #166 (numpydoc checks and hooks), #167 (PR implementing #165 and #166)
- **Supersedes in part:** ADR-016 (CI Checks Module — `typescript.enable`
  gating logic and the pre-commit/checks option split)
- **Modules:** `modules/flake-parts/checks.nix`, `modules/flake-parts/pre-commit.nix`,
  `lib/python-env-selection.nix`
- **Implementation plan:** `docs/internal/plans/029-unified-quality-gate-controls.md`

______________________________________________________________________

Author: Claude
Date: 2026-02-20
