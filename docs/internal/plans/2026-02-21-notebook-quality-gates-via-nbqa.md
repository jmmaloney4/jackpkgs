# Implementation Plan: Notebook Quality Gates via nbqa (ADR-031)

**Status:** Proposed
**Date:** 2026-02-21
**ADR:** `docs/internal/designs/031-notebook-quality-gates-via-nbqa.md`
**Scope:** `modules/flake-parts/fmt.nix`, `modules/flake-parts/checks.nix`,
`modules/flake-parts/pre-commit.nix`, `tests/fmt.nix`, `tests/checks.nix`,
`tests/pre-commit.nix`, `README.md`

## Objective

Implement notebook quality gates so `.ipynb`/`.qmd` receive the same quality
coverage model as `.py`:

- formatting in `fmt.nix`
- lint checks in `checks.nix`
- pre-commit mirroring from `checks.nix`

## Non-goals

- Full multi-tool notebook linting in this change (ruff first).
- Reworking `nbstripout` behavior in CI in this change.

## Pre-flight Verification

- [ ] Confirm ADR-031 status is `Proposed` and references issue #50.
- [ ] Confirm next ADR number is `031` and filename is unique.
- [ ] Confirm `tests/fmt.nix` is already wired into `flake.nix` nix-unit tests.
- [ ] Confirm no existing issue tracks notebook output CI semantics (open follow-up after implementation).

---

## Step 1: Refactor `modules/flake-parts/fmt.nix`

### 1.1 Correct nbqa argument structure

Current implementation treats `--nbqa-shell` like a flag with a value. Replace
with positional command-first structure.

Required shape:

```nix
command = "${nbqaCfg.nbqaPackage}/bin/nbqa";
options = [ "${toolCommand}" "--nbqa-shell" ] ++ toolOptions ++ [ "--" ];
```

- [ ] Ensure first options element is the positional nbqa command string.
- [ ] Keep trailing `"--"` separator before filenames.

### 1.2 Keep formatter scope to format-only

- [ ] Remove notebook lint formatter entry (`python-notebook-lint`).
- [ ] Keep notebook formatter entry for `ruff format`.
- [ ] Rename formatter key if needed for extensibility (for example
      `python-notebook-ruff-format`) only if it does not break expected naming
      conventions; otherwise keep stable existing key.

### 1.3 Adopt generalized tool configuration shape

Move from flat ruff-specific option leafs to a `tools` attrset under
`jackpkgs.fmt.nbqa`.

Suggested structure:

```nix
jackpkgs.fmt.nbqa = {
  enable = ...;
  includes = ...;
  nbqaPackage = ...;
  tools = {
    ruff-format = {
      enable = true;
      command = "${ruffPkg}/bin/ruff format";
      options = [];
    };
  };
};
```

- [ ] Preserve backward compatibility strategy decision:
  - Option A: keep old options as deprecated aliases for one cycle.
  - Option B: break immediately (acceptable if internal-only and no consumers).
- [ ] Document chosen compatibility path in PR notes.

### 1.4 Ruff package source consistency

- [ ] Resolve notebook ruff package from the same chain used by current
      `.py` checks/hooks.
- [ ] Avoid introducing independent notebook-specific ruff package knobs unless
      strictly required.

Acceptance criteria:

- [ ] `nix eval` of formatter options produces command-first nbqa args.
- [ ] Notebook lint no longer exists in `fmt` formatter surface.
- [ ] Formatter definitions are generated from generalized `tools` config.

---

## Step 2: Extend `modules/flake-parts/checks.nix`

### 2.1 Add notebook check options

Add options under `jackpkgs.checks.python.notebook.ruff`:

- `enable` (bool)
- `extraArgs` (list of str)

Default behavior:

- [ ] `enable` defaults to `config.jackpkgs.checks.python.ruff.enable`.

### 2.2 Add notebook lint check derivation

Create check name (proposed): `python-notebook-ruff`.

- [ ] Build inputs include nbqa + ruff package.
- [ ] Script discovers notebook files from project root (and handles no-match
      case clearly).
- [ ] Script runs nbqa ruff check with forwarded `extraArgs`.

Acceptance criteria:

- [ ] Check appears when notebook ruff check enabled.
- [ ] Check absent when notebook ruff check disabled.
- [ ] Build script contains expected command fragments and args.

---

## Step 3: Extend `modules/flake-parts/pre-commit.nix`

### 3.1 Add notebook lint hook mirrored from checks

Proposed hook: `nbqa-ruff`.

- [ ] Hook `enable` reads from `checksCfg.python.notebook.ruff.enable`.
- [ ] Hook target file regex includes `.ipynb` and `.qmd` as configured.
- [ ] Hook entry includes nbqa + ruff check wiring with `extraArgs` from checks.

### 3.2 Preserve ADR-029 control model

- [ ] Do not add independent enable toggle under `jackpkgs.pre-commit` for
      notebook linting.
- [ ] Keep `checks` as single source of truth for gate enablement.

Acceptance criteria:

- [ ] Hook enable/disable tracks checks enable/disable.
- [ ] Hook entry string reflects extraArgs from checks config.

---

## Step 4: Unit Tests (nix-unit) — Detailed Plan

This repo uses attrset `{ expr, expected }` tests evaluated through
`inputs.nix-unit` in `flake.nix`. Mirror this exact pattern.

### 4.1 `tests/fmt.nix` updates

Current harness utilities to continue using:

- `evalFlake`, `getTreefmtConfig`, `getSettingsFormatter`
- `hasInfixAll`, `lib.hasAttr`, strict list equality where possible

Add/adjust tests:

- [ ] `testNbqaDisabledByDefault`
  - ensure notebook formatter(s) absent when disabled.
- [ ] `testNbqaEnabledCreatesFormatFormatter`
  - ensure format formatter exists; lint formatter does not.
- [ ] `testNbqaFormatOptionsExactOrder`
  - assert exact vector order:
    `[
      "<ruff command> format"
      "--nbqa-shell"
      ...extra options...
      "--"
    ]`
- [ ] `testNbqaToolRegistryRendersFormatters`
  - define additional tool in `tools` attrset and assert formatter appears.
- [ ] `testNbqaIncludesDefaultAndOverride`
  - default includes and override behavior preserved.
- [ ] `testNbqaRuffPackageSourcePropagation`
  - if package source is wired through shared chain, assert generated command
    contains expected package path.

Important test style requirement:

- [ ] Prefer exact list equality for options order tests.
- [ ] Avoid substring-only assertions for nbqa shell semantics.

### 4.2 `tests/checks.nix` updates

Current harness utilities to continue using:

- `mkChecks`, `mkChecksNoMock`, `getBuildCommand`
- `hasCheck`, `missingCheck`, `hasInfixAll`

Add tests:

- [ ] `testPythonNotebookRuffEnabledWhenPythonRuffEnabled`
  - with `pythonEnable = true` and default options, check exists.
- [ ] `testPythonNotebookRuffCanBeDisabledExplicitly`
  - set `jackpkgs.checks.python.notebook.ruff.enable = false`; check absent.
- [ ] `testPythonNotebookRuffScriptContainsNbqaAndRuffCheck`
  - inspect script for `nbqa`, `ruff check`, `--nbqa-shell` (and expected order
    where feasible in shell snippet).
- [ ] `testPythonNotebookRuffExtraArgsPassThrough`
  - set extraArgs and assert script includes them.
- [ ] `testPythonNotebookRuffNoNotebookGuidance`
  - if no notebooks found behavior is designed, assert guard message/exit behavior.

### 4.3 `tests/pre-commit.nix` updates

Current harness utilities to continue using:

- `mkConfigModule` with `topConfig` + `perSystemConfig`
- `getHooks`
- `hasInfixAll`

Add tests:

- [ ] `testNotebookRuffHookEnabledWhenChecksEnabled`
- [ ] `testNotebookRuffHookDisabledWhenChecksDisabled`
- [ ] `testNotebookRuffHookEntryIncludesNbqaAndRuffCheck`
- [ ] `testNotebookRuffHookIncludesExtraArgsFromChecks`
- [ ] `testNotebookRuffHookFileRegexTargetsNotebookFiles`

Consistency checks:

- [ ] Keep existing style of enabling/disabling via `topConfig.jackpkgs.checks...`.
- [ ] Avoid introducing pre-commit-local enable toggles for notebook lint.

---

## Step 5: Documentation updates

### 5.1 README (`flake-only`) updates

Per repo AGENTS guidance, update README when module options and behavior change.

- [ ] Add/adjust `fmt` module section for `jackpkgs.fmt.nbqa` shape.
- [ ] Add/adjust `checks` section for `jackpkgs.checks.python.notebook.ruff`.
- [ ] Include copy-pasteable snippet showing unified enablement model.
- [ ] Note notebook lint lives in checks, not formatter surface.

### 5.2 Follow-up tracking issue

- [ ] Open issue: clarify/verify CI semantics for notebook output stripping
      (`nbstripout`) independent of this change.

---

## Step 6: Verification and completion

### 6.1 Local verification commands

```bash
system=$(nix eval --impure --raw --expr builtins.currentSystem)
nix build ".#checks.${system}.nix-unit" -L
```

If needed, run targeted eval checks during development:

```bash
nix eval --json .#checks.x86_64-linux.nix-unit.tests.fmt
```

### 6.2 Completion checklist

- [ ] All new/updated nix-unit tests pass.
- [ ] ADR file exists and links issue/related ADRs.
- [ ] Plan file exists and reflects final implementation decisions.
- [ ] README updated for consumer-facing option changes.
- [ ] Follow-up issue created for notebook output CI semantics.

---

## Implementation order recommendation

1. `fmt.nix` correction and scope cleanup
2. `tests/fmt.nix` updates
3. `checks.nix` notebook check additions
4. `tests/checks.nix` updates
5. `pre-commit.nix` hook mirroring
6. `tests/pre-commit.nix` updates
7. README updates
8. full nix-unit run

This order minimizes cross-file breakage and keeps test feedback loops tight.
