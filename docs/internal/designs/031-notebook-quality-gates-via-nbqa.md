---
id: ADR-031
title: Notebook Quality Gates via nbqa
status: proposed
date: 2026-02-21
---

# ADR-031: Notebook Quality Gates via nbqa

## Status

Proposed

## Context

### 1. Problem

jackpkgs currently enforces Python quality gates for `.py` files across three
surfaces:

- `fmt.nix` for formatting (treefmt)
- `checks.nix` for CI checks (`nix flake check`)
- `pre-commit.nix` for local hooks (mirroring `checks.nix` per ADR-029)

Notebook sources (`.ipynb` and `.qmd`) do not have equivalent coverage. This
creates drift between notebook code quality and Python source quality.

### 2. Existing architecture constraints

- ADR-016 established formatter/check separation:
  - `fmt.nix` is for formatters.
  - `checks.nix` is for checks.
- ADR-029 established unified control:
  - check enablement is controlled in `jackpkgs.checks`.
  - pre-commit mirrors check enablement.

Any notebook quality-gate design MUST preserve these boundaries.

### 3. Why nbqa

`nbqa` is the adapter that runs Python tools against notebook cell code. It can
wrap `ruff`, `black`, `isort`, `mypy`, and others.

Notebook quality gates SHOULD be designed around a general nbqa wrapper so we do
not redesign the option schema when adding additional tools.

### 4. Correctness note: `--nbqa-shell`

`nbqa` CLI shape is:

```text
nbqa <command> <notebooks...> [nbqa-options] [tool-args]
```

`--nbqa-shell` is a boolean flag. It does not take a command argument. The tool
command is positional (first argument after `nbqa`).

For treefmt integration, this means formatter option vectors MUST place the
command positional first, then `--nbqa-shell`, then tool args.

## Decision

### Core principle

Notebook quality gates will mirror `.py` quality gates:

- formatting in `fmt.nix`
- lint checks in `checks.nix`
- pre-commit hooks mirrored from `checks.nix`

### 1) `fmt.nix`: notebook formatting only

`jackpkgs.fmt.nbqa` remains the formatter surface for notebooks, but with strict
scope: formatting only.

- Keep notebook formatting (initially ruff format).
- Remove notebook linting (`ruff check --fix`) from treefmt formatters.
- Keep includes default notebook-focused (`*.ipynb`, `*.qmd`).

Formatter invocation MUST follow correct nbqa ordering:

```nix
command = "${nbqaPackage}/bin/nbqa";
options = [ "${ruffCmd} format" "--nbqa-shell" ] ++ ruffFormatOptions ++ [ "--" ];
```

### 2) `checks.nix`: notebook lint checks

Add notebook lint checks under `jackpkgs.checks.python.notebook`.
Initial tool: ruff.

```nix
jackpkgs.checks.python.notebook.ruff = {
  enable = <bool>;
  extraArgs = <listOf str>;
};
```

Default behavior:

- `jackpkgs.checks.python.notebook.ruff.enable` SHOULD default to
  `jackpkgs.checks.python.ruff.enable`.

This keeps notebook lint behavior aligned with `.py` lint behavior unless the
user overrides it.

### 3) `pre-commit.nix`: mirror notebook lint checks

Add notebook lint hook(s) controlled by `checksCfg.python.notebook.ruff.enable`,
consistent with ADR-029 mirroring.

### 4) General wrapper model for formatter surface

`jackpkgs.fmt.nbqa` SHOULD use a general tool registry shape (`tools` attrset)
instead of ruff-specific flat options. Initial default tool remains ruff format.

This allows adding tools without changing top-level option shape.

### 5) Ruff package consistency

Notebook ruff execution SHOULD reuse the same package source chain already used
for `.py` checks/hooks to avoid package/version drift.

## Consequences

### Benefits

- Notebook quality gates become first-class and consistent with `.py` gates.
- Module boundaries stay clean (`fmt` formats; `checks` checks).
- ADR-029 unified controls remain coherent.
- General nbqa tool shape supports incremental expansion.

### Trade-offs

- Touches three modules (`fmt`, `checks`, `pre-commit`) plus tests and docs.
- Introduces additional option surface under `jackpkgs.checks.python.notebook`.

### Risks and mitigations

- **R1: Incorrect nbqa argument generation.**
  - Mitigation: unit tests assert exact option order, not substring presence.
- **R2: `.qmd` behavior may differ from `.ipynb`.**
  - Mitigation: keep configurable includes; document caveat.
- **R3: notebook output enforcement expectation.**
  - `nbstripout` is pre-commit-only behavior today.
  - Mitigation: open follow-up issue to explicitly document/validate CI semantics
    around notebook outputs.

## Alternatives Considered

### Alternative A: keep notebook linting in `fmt.nix`

Run both `ruff format` and `ruff check --fix` as treefmt formatters.

- Pros: smaller immediate patch.
- Cons: violates formatter/check separation; weak CI semantics.
- Why not chosen: conflicts with ADR-016 and ADR-029 direction.

### Alternative B: ruff-only option shape now, generalize later

Keep flat options (`ruffFormatOptions`, etc.) and postpone generalized design.

- Pros: minimal schema change.
- Cons: future schema churn when adding additional tools.
- Why not chosen: generalized attrset is low-cost now and avoids migration later.

### Alternative C: independent notebook ruff package knobs per module

Separate ruff package options in `fmt`, `checks`, and `pre-commit` notebook
surfaces.

- Pros: maximum control.
- Cons: increased config burden and drift risk.
- Why not chosen: shared package source is simpler and more consistent.

## Implementation Plan (high-level)

1. Correct and scope notebook formatter behavior in `fmt.nix`.
2. Add notebook lint checks in `checks.nix`.
3. Add mirrored notebook lint hook in `pre-commit.nix`.
4. Extend nix-unit tests in `tests/fmt.nix`, `tests/checks.nix`,
   `tests/pre-commit.nix`.
5. Update README (`fmt` and `checks` sections) and open follow-up issue for
   notebook output CI semantics.

## Related

- Issue #50
- ADR-016: CI Checks Module
- ADR-029: Unified Quality-Gate Controls

---

Author: OpenCode
Date: 2026-02-21
PR: (pending)
