# Implementation Plan: Unified Quality-Gate Controls (ADR-029)

**Date:** 2026-02-20
**ADR:** `docs/internal/designs/029-unified-quality-gate-controls.md`
**Scope:** `modules/flake-parts/checks.nix`, `modules/flake-parts/pre-commit.nix`,
`tests/checks.nix`, `tests/pre-commit.nix`, `README.md`

## Problem Summary

`jackpkgs.checks` and `jackpkgs.pre-commit` expose independent `enable` and
`extraArgs` options for every shared tool (mypy, ruff, pytest, numpydoc, tsc,
vitest). Toggling a tool requires changing options in two namespaces. The
interim `mirrorPreCommit` mechanism added in issue #168 treats the symptom
without fixing the root cause.

ADR-029 designates `jackpkgs.checks.<tool>.enable` and
`jackpkgs.checks.<tool>.extraArgs` as the single source of truth, and removes
all `enable`/`extraArgs` options from `jackpkgs.pre-commit`.

## Pre-Flight: Verify Scope Access (R1 Risk)

**Implementation outcome note (post-execution):**

Direct access to `config.jackpkgs.checks` from the deferred per-system context
did not resolve reliably. The implemented mitigation matches ADR-029 R1: capture
`checksCfg = config.jackpkgs.checks` at the module top-level scope in
`pre-commit.nix`, then close over `checksCfg` inside the per-system config
function.

Before making any module changes, confirm that `config.jackpkgs.checks` is
accessible from within the `pre-commit.nix` per-system config block (the
`mkDeferredModuleOption` scope). This is believed to work because `checks.nix`
already reads `config.jackpkgs.python.enable` from within `config.perSystem`,
but must be confirmed.

**Verification method:**

Add a temporary assertion to `pre-commit.nix` inside the `perSystem` config
block:

```nix
config.perSystem = { config, lib, pkgs, ... }: {
  assertions = [{
    assertion = config ? jackpkgs && config.jackpkgs ? checks;
    message   = "jackpkgs.checks not visible from pre-commit perSystem scope";
  }];
};
```

Run `nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).nix-unit`.
If the build succeeds, the reference is valid and the assertion can be removed.

**Fallback (if reference does not resolve):**

In `modules/flake-parts/all.nix` or `checks.nix`, inject into module args:

```nix
perSystem = { config, ... }: {
  _module.args.jackpkgsChecksCfg = config.jackpkgs.checks;
};
```

Then read `args.jackpkgsChecksCfg` in `pre-commit.nix` instead of
`config.jackpkgs.checks`. All downstream code references in the plan below
assume direct access; substitute `args.jackpkgsChecksCfg` if the fallback is
needed.

---

## Step 1 — Refactor `modules/flake-parts/checks.nix`

### 1a. Remove `python.mirrorPreCommit` option block

Delete the following option declarations (approximately lines 105–127 in
current file):

```nix
mirrorPreCommit = {
  enable = mkOption { ... };
  gates  = mkOption { ... };
};
```

### 1b. Remove the outer `typescript.enable` option

The current shape has two levels:

```nix
typescript = {
  enable = mkOption { default = config.jackpkgs.pulumi.enable or false; };
  tsc = {
    enable      = mkOption { default = true; };
    nodeModules = ...;
    packages    = ...;
    extraArgs   = ...;
  };
};
```

Remove `typescript.enable`. Change `typescript.tsc.enable`'s default to:

```nix
default = config.jackpkgs.nodejs.enable or false;
```

Update all guards in the `config` block from:

```nix
lib.optionalAttrs (cfg.typescript.enable && cfg.typescript.tsc.enable) { ... }
```

to:

```nix
lib.optionalAttrs cfg.typescript.tsc.enable { ... }
```

### 1c. Add `python.mypy.enable`, `python.ruff.enable`, `python.pytest.enable`

These `enable` options already exist in `checks.nix`. **No additions needed.**

### 1d. Remove the `mirrorPreCommit` config block

Remove the `lib.mkMerge` wrapper introduced by the mirror mechanism and the
four conditional `jackpkgs.checks.python.*.enable = lib.mkDefault ...`
expressions inside it. The config block should collapse back to a single
`perSystem = { ... }:` block without any outer merge.

**Before:**

```nix
config = lib.mkMerge [
  (lib.mkIf (mirrorGate "mypy")     { jackpkgs.checks.python.mypy.enable     = lib.mkDefault ...; })
  (lib.mkIf (mirrorGate "ruff")     { jackpkgs.checks.python.ruff.enable     = lib.mkDefault ...; })
  (lib.mkIf (mirrorGate "pytest")   { jackpkgs.checks.python.pytest.enable   = lib.mkDefault ...; })
  (lib.mkIf (mirrorGate "numpydoc") { jackpkgs.checks.python.numpydoc.enable = lib.mkDefault ...; })
  {
    perSystem = { pkgs, lib, config, ... }: { ... };
  }
];
```

**After:**

```nix
config = {
  perSystem = { pkgs, lib, config, ... }: { ... };
};
```

Also remove the `let mirrorCfg = ...; mirrorGate = ...; preCommitGateEnabled = ...;` bindings.

---

## Step 2 — Refactor `modules/flake-parts/pre-commit.nix`

### 2a. Remove `enable` and `extraArgs` from all per-system option declarations

For each tool, delete the `enable` and `extraArgs` option definitions from the
`mkDeferredModuleOption` options block:

| Tool | Remove |
|------|--------|
| `python.mypy` | `enable`, `extraArgs` |
| `python.ruff` | `enable`, `extraArgs` |
| `python.pytest` | `enable`, `extraArgs` |
| `python.numpydoc` | `enable`, `extraArgs` |
| `typescript.tsc` | `enable`, `extraArgs` |
| `javascript.vitest` | `enable`, `extraArgs` |

Keep `package` and (for tsc/vitest) `nodeModules`.

### 2b. Add `checksCfg` binding in the config block

At the top of the per-system config let-binding:

```nix
let
  sysCfg    = config.jackpkgs.pre-commit;
  checksCfg = config.jackpkgs.checks;           # ← NEW
  ...
in
```

### 2c. Repoint all hook `enable` fields

For every hook in `pre-commit.settings.hooks.*`, change:

```nix
enable = sysCfg.python.mypy.enable;
```

to:

```nix
enable = checksCfg.python.mypy.enable;
```

Full mapping:

| Hook | Old source | New source |
|------|-----------|-----------|
| `mypy` | `sysCfg.python.mypy.enable` | `checksCfg.python.mypy.enable` |
| `ruff` | `sysCfg.python.ruff.enable` | `checksCfg.python.ruff.enable` |
| `pytest` | `sysCfg.python.pytest.enable` | `checksCfg.python.pytest.enable` |
| `numpydoc` | `sysCfg.python.numpydoc.enable` | `checksCfg.python.numpydoc.enable` |
| `tsc` | `sysCfg.typescript.tsc.enable` | `checksCfg.typescript.tsc.enable` |
| `vitest` | `sysCfg.javascript.vitest.enable` | `checksCfg.vitest.enable` |

### 2d. Repoint all hook `entry` extraArgs references

For every hook whose `entry` string currently interpolates
`sysCfg.<tool>.extraArgs`, replace with the corresponding `checksCfg` path:

| Hook | Old path | New path |
|------|---------|---------|
| `mypy` | `sysCfg.python.mypy.extraArgs` | `checksCfg.python.mypy.extraArgs` |
| `ruff` | `sysCfg.python.ruff.extraArgs` | `checksCfg.python.ruff.extraArgs` |
| `pytest` | `sysCfg.python.pytest.extraArgs` | `checksCfg.python.pytest.extraArgs` |
| `numpydoc` | `sysCfg.python.numpydoc.extraArgs` | `checksCfg.python.numpydoc.extraArgs` |
| `tsc` | `sysCfg.typescript.tsc.extraArgs` | `checksCfg.typescript.tsc.extraArgs` |
| `vitest` | `sysCfg.javascript.vitest.extraArgs` | `checksCfg.vitest.extraArgs` |

The `tscEntry` and `vitestEntry` local `let` bindings that embed `extraArgs`
must be updated to pull from `checksCfg` before they are used in the hook
`entry` field.

---

## Step 3 — Update `tests/checks.nix`

### 3a. Remove the `jackpkgs.pre-commit.python` stub options from `optionsModule`

The test harness `optionsModule` currently declares stub options for
`jackpkgs.pre-commit.python.{pytest,mypy,ruff,numpydoc}.enable` to support the
`mirrorPreCommit` tests. Remove those stubs entirely.

### 3b. Remove the four `mirrorPreCommit` tests

Delete:

- `testPythonMirrorPreCommitDisabledByDefault`
- `testPythonMirrorPreCommitNumpydoc`
- `testPythonMirrorPreCommitExplicitCheckOverrideWins`
- `testPythonMirrorPreCommitCustomGateSelection`

### 3c. Add `typescript.tsc.enable` default tests

Add two tests that confirm the new default behaviour for `typescript.tsc.enable`:

```nix
# tsc check absent when nodejs disabled (default)
testTypescriptTscDisabledWhenNodejsDisabled = {
  expr     = missingCheck (mkChecks { configModule = mkConfigModule { nodejsEnable = false; }; }) "typescript-tsc";
  expected = true;
};

# tsc check present when nodejs enabled
testTypescriptTscEnabledWhenNodejsEnabled = {
  expr     = hasCheck (mkChecks { configModule = mkConfigModule { nodejsEnable = true; }; }) "typescript-tsc";
  expected = true;
};
```

This requires `mkConfigModule` to accept a `nodejsEnable` parameter (add it if
not already present; wire it to `jackpkgs.nodejs.enable` in the stub).

### 3d. Add `python.mypy.enable` single-switch tests

Confirm that setting `jackpkgs.checks.python.mypy.enable = false` removes the
CI check:

```nix
testPythonMypyDisabledBySwitch = {
  expr     = missingCheck
    (mkChecks { configModule = mkConfigModule {
      pythonEnable = true;
      extraConfig.jackpkgs.checks.python.mypy.enable = false;
    }; })
    "python-mypy";
  expected = true;
};
```

Apply the same pattern for `ruff` and `pytest` if not already covered.

---

## Step 4 — Update `tests/pre-commit.nix`

### 4a. Update `mkConfigModule` stub options module

The test harness `optionsModule` currently stubs only `jackpkgs.python` and
`jackpkgs.outputs`. It now needs `jackpkgs.checks.*` stubs so that
`pre-commit.nix` (which now reads `config.jackpkgs.checks`) can evaluate.

Add to `optionsModule`:

```nix
options.jackpkgs.checks = {
  python = {
    mypy.enable     = mkOption { type = types.bool; default = true; };
    mypy.extraArgs  = mkOption { type = types.listOf types.str; default = []; };
    ruff.enable     = mkOption { type = types.bool; default = true; };
    ruff.extraArgs  = mkOption { type = types.listOf types.str; default = ["--no-cache"]; };
    pytest.enable   = mkOption { type = types.bool; default = true; };
    pytest.extraArgs = mkOption { type = types.listOf types.str; default = []; };
    numpydoc.enable   = mkOption { type = types.bool; default = false; };
    numpydoc.extraArgs = mkOption { type = types.listOf types.str; default = []; };
  };
  typescript.tsc = {
    enable    = mkOption { type = types.bool; default = true; };
    extraArgs = mkOption { type = types.listOf types.str; default = []; };
  };
  vitest = {
    enable    = mkOption { type = types.bool; default = true; };
    extraArgs = mkOption { type = types.listOf types.str; default = []; };
  };
};
```

### 4b. Remove pre-commit-scoped `enable` / `extraArgs` assertions

Delete or rewrite tests that previously toggled `jackpkgs.pre-commit.python.*.enable`:

- `testDisableMypyHook` — change to set `jackpkgs.checks.python.mypy.enable = false`
- `testDisableRuffHook` — change to set `jackpkgs.checks.python.ruff.enable = false`
- `testRuffExtraArgsAppearInEntry` — change to set `jackpkgs.checks.python.ruff.extraArgs`
- `testNumpydocExtraArgsAppearInEntry` — change to set `jackpkgs.checks.python.numpydoc.extraArgs`

### 4c. Update `testRuffPytestNumpydocDefaultToMypyPackage`

This test currently overrides `jackpkgs.pre-commit.python.mypy.package` to a
dummy derivation and asserts that ruff/pytest/numpydoc packages default to the
same value. The assertion logic remains valid; only the override syntax changes
(no change needed if it already uses `extraConfig.jackpkgs.pre-commit.python.mypy.package`).

### 4d. Update enabled-by-default tests

`testMypyEnabledByDefault`, `testRuffEnabledByDefault`, etc. previously read
`hooks.*.enable` which was set from `sysCfg.*.enable`. After the change those
hook enables come from `checksCfg.*.enable`. The assertions remain identical in
form — `hooks.mypy.enable == true` — but now exercise the `checksCfg` path.
No test changes needed unless `mkConfigModule` no longer sets `jackpkgs.checks`
defaults; confirm defaults flow correctly when running the suite.

---

## Step 5 — Update `README.md`

### 5a. `jackpkgs.pre-commit` option list

Remove from the documented option list:

- `python.mypy.enable`
- `python.ruff.enable`
- `python.pytest.enable`
- `python.numpydoc.enable`
- `python.mypy.extraArgs`
- `python.ruff.extraArgs`
- `python.pytest.extraArgs`
- `python.numpydoc.extraArgs`
- `typescript.tsc.enable`
- `typescript.tsc.extraArgs`
- `javascript.vitest.enable`
- `javascript.vitest.extraArgs`

Update the module summary sentence to describe `pre-commit` as providing only
package and nodeModules overrides for the tools configured under
`jackpkgs.checks`.

### 5b. `jackpkgs.checks` option list

Remove `python.mirrorPreCommit.enable` and `python.mirrorPreCommit.gates`.

Update `typescript.tsc.enable` default description from
`"auto when jackpkgs.pulumi.enable"` to `"auto when jackpkgs.nodejs.enable"`.

Add `python.mypy.enable`, `python.ruff.enable`, `python.pytest.enable` to the
documented list if not already present.

### 5c. Single-switch UX example

Replace or add an example showing the unified control:

```nix
# Disable mypy in both CI checks and pre-commit with one line:
jackpkgs.checks.python.mypy.enable = false;

# Enable numpydoc in both surfaces with one line:
jackpkgs.checks.python.numpydoc.enable = true;
```

### 5d. Remove `mirrorPreCommit` from the parity matrix section

The quality-gate parity matrix row description can be simplified: the "Default"
column now just reflects `jackpkgs.checks.*` defaults; no mention of mirror.

---

## Step 6 — Run nix-unit and Commit

### Verification

```bash
system=$(nix eval --impure --raw --expr builtins.currentSystem)
nix build ".#checks.${system}.nix-unit" -L
```

All tests must pass before committing.

### Commit

Single `jj` commit:

```
refactor(checks): unify quality-gate controls under jackpkgs.checks

- Remove jackpkgs.pre-commit.python.*.{enable,extraArgs} options
- Remove jackpkgs.pre-commit.typescript.tsc.{enable,extraArgs} options
- Remove jackpkgs.pre-commit.javascript.vitest.{enable,extraArgs} options
- Remove jackpkgs.checks.python.mirrorPreCommit.* option block
- jackpkgs.checks.<tool>.{enable,extraArgs} are now the single source of
  truth consumed by both check derivations and pre-commit hooks
- Change typescript.tsc.enable default from pulumi.enable to nodejs.enable
- Update tests and README accordingly

Closes #168
```

---

## Rollback

If the R1 scope risk materialises and the fallback via `_module.args` is also
infeasible, the minimal rollback is to revert only `pre-commit.nix` and restore
the removed `enable`/`extraArgs` options, while keeping the `checks.nix`
cleanup (removal of `mirrorPreCommit` and `typescript.enable`) in place.
