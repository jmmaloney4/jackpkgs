---
id: ADR-031
title: Notebook Quality Gates via nbqa and jupytext
status: accepted
date: 2026-02-21
---

# ADR-031: Notebook Quality Gates via nbqa and jupytext

## Status

Accepted

## Context

### 1. Problem

jackpkgs currently enforces Python quality gates for `.py` files across three surfaces:

- `fmt.nix` for formatting (treefmt)
- `checks.nix` for CI checks (`nix flake check`)
- `pre-commit.nix` for local hooks (mirroring `checks.nix` per ADR-029)

Notebook sources do not have equivalent coverage. This creates drift between notebook code quality and Python source quality.

### 2. Existing architecture constraints

- ADR-016 established formatter/check separation:
  - `fmt.nix` is for formatters.
  - `checks.nix` is for checks.
- ADR-029 established unified control:
  - check enablement is controlled in `jackpkgs.checks`.
  - pre-commit mirrors check enablement.

Any notebook quality-gate design MUST preserve these boundaries.

### 3. Why nbqa for `.ipynb`

`nbqa` is the adapter that runs Python tools against notebook cell code. It can wrap `ruff`, `black`, `isort`, `mypy`, and others.

For Jupyter `.ipynb` files, `nbqa` is the correct tool: it discovers, extracts, and round-trips `.ipynb` notebooks directly.

### 4. Why jupytext for MyST-NB `.md`

`nbqa` does not work for MyST-NB markdown notebooks. Live testing shows `nbqa` returns `No notebooks found in given path(s)` for `.md` files, even with `--nbqa-md`.

`jupytext` supports MyST markdown notebooks natively as `md:myst` format and provides a `--pipe` contract that runs tools on a temporary script representation, then round-trips back into MyST markdown.

Validated commands:

- **Lint:** `jupytext --check "ruff check --fix --exit-non-zero-on-fix {}" --pipe-fmt py:percent <file.md>`
- **Format:** `jupytext --pipe "ruff format {}" --pipe-fmt py:percent <file.md>`

The `{}` placeholder tells `jupytext` to create a temporary file for the tool; this is the correct contract for tools like `ruff` that do not accept stdin pipelines.

### 5. Correctness notes

`nbqa` CLI shape for `.ipynb`:

```text
nbqa <command> <notebooks...> [nbqa-options] [tool-args]
```

`--nbqa-shell` is a boolean flag. It does not take a command argument. The tool command is positional (first argument after `nbqa`).

For treefmt integration, formatter option vectors MUST place the command positional first, then `--nbqa-shell`, then tool args.

`jupytext` CLI shape for MyST `.md`:

```text
jupytext --pipe "<tool-cmd {}>" --pipe-fmt py:percent <file.md>
```

The `{}` placeholder is required for tools that do not support stdin pipelines.

### 6. What we are NOT supporting

- **Quarto (`.qmd`):** previously mentioned in early drafts, but not part of our toolchain. All `qmd` support is removed.
- **`mdformat-myst` as a notebook formatter:** live testing shows `mdformat-myst` mangles MyST notebook frontmatter and is not safe as the primary formatter. If you need markdown structure formatting, use `mdformat` for non-notebook markdown files and keep notebook formatting via the code-cell toolchain.

## Decision

### Core principle

Notebook quality gates will mirror `.py` quality gates, with two separate backends:

- **For `.ipynb` notebooks:** `nbqa` + `ruff`
- **For MyST-NB `.md` notebooks:** `jupytext` + `ruff`
- **Formatter/check separation preserved:** formatting in `fmt.nix`, lint checks in `checks.nix`, pre-commit hooks in `pre-commit.nix`
- **`qmd` support removed entirely**

### 1) `fmt.nix`: split notebook formatting surface

Split `jackpkgs.fmt.nbqa` into two formatters:

- `python-notebook-format` for `.ipynb` via `nbqa`
- `python-myst-notebook-format` for `.md` via `jupytext`

Remove `qmd` from all defaults and includes.

#### `.ipynb` formatter (`nbqa`)

Formatter invocation MUST follow correct nbqa ordering:

```nix
python-notebook-format = {
  command = "${nbqaPackage}/bin/nbqa";
  options = ["${ruffCmd} format" "--nbqa-shell"] ++ ruffFormatOptions ++ ["--"];
  includes = ipynbIncludes;  # default ["*.ipynb"]
};
```

#### MyST `.md` formatter (`jupytext`)

Formatter invocation uses temp-file placeholder contract:

```nix
python-myst-notebook-format = {
  command = "${jupytextPackage}/bin/jupytext";
  options = ["--pipe" "${ruffCmd} format {}" "--pipe-fmt" "py:percent"];
  includes = mystIncludes;  # default []; user configures (e.g. ["docs/**/*.md"])
};
```

Include globs SHOULD be configured conservatively. Not all `.md` files are MyST notebooks.

### 2) `checks.nix`: split notebook lint checks

Add separate lint checks under `jackpkgs.checks.python.notebook`:

- `ipynb.ruff` for `.ipynb` via `nbqa`
- `myst.ruff` for `.md` via `jupytext`

Both default to mirroring `jackpkgs.checks.python.ruff.enable` when enabled.

#### `.ipynb` lint check (`nbqa`)

```nix
python-notebook-ruff = mkCheck {
  name = "python-notebook-ruff";
  buildInputs = [pythonEnvWithDevTools pkgs.nbqa];
  perMemberCommand = "nbqa \"ruff check\" --nbqa-shell ${lib.escapeShellArgs cfg.python.notebook.ipynb.ruff.extraArgs} .";
  // workspaceRoot/members scoped appropriately
};
```

#### MyST `.md` lint check (`jupytext`)

```nix
python-myst-notebook-ruff = mkCheck {
  name = "python-myst-notebook-ruff";
  buildInputs = [pythonEnvWithDevTools pkgs.jupytext pkgs.ruff];
  perMemberCommand = "jupytext --check \"ruff check --fix --exit-non-zero-on-fix {}\" --pipe-fmt py:percent .";
  // workspaceRoot/members scoped appropriately
};
```

### 3) `pre-commit.nix`: mirror notebook lint checks

Split notebook lint hooks:

- `nbqa-ruff` for `.ipynb`
- `jupytext-ruff` for `.md`

Both controlled by their respective check enable flags.

### 4) Package consistency

- `.ipynb` path SHOULD reuse the same package source chain as `.py` checks.
- MyST `.md` path SHOULD use `pkgs.jupytext` and the same `ruff` package as `.py` checks.

### 5) Configuration surface

Split configuration options:

```nix
jackpkgs.fmt.nbqa = {
  ipynb = {
    enable = mkEnableOption "nbqa-based formatting for .ipynb";
    includes = mkOption { default = ["*.ipynb"]; };
  };
  myst = {
    enable = mkEnableOption "jupytext-based formatting for MyST .md notebooks";
    includes = mkOption { default = []; description = "MyST notebook paths; user configures"; };
    jupytextPackage = mkOption { default = pkgs.jupytext; };
  };
  // nbqaPackage, ruffPackage, etc.
};

jackpkgs.checks.python.notebook = {
  ipynb.ruff = { ... };
  myst.ruff = { ... };
};
```

## Consequences

### Benefits

- MyST-NB notebooks get first-class quality gates using the correct toolchain.
- `.ipynb` support remains robust via `nbqa`.
- Module boundaries stay clean.
- ADR-029 unified controls remain coherent.
- `qmd` confusion removed from code/docs.

### Trade-offs

- Touches three modules (`fmt`, `checks`, `pre-commit`) plus tests and docs.
- Introduces additional configuration surface under `jackpkgs.fmt.nbqa.myst` and `jackpkgs.checks.python.notebook.myst`.
- Users must configure MyST includes explicitly to avoid scanning all `.md` files as notebooks.

### Risks and mitigations

- **R1: Incorrect argument generation for either backend.**
  - Mitigation: unit tests assert exact option strings and order.
- **R2: MyST includes too broad by default.**
  - Mitigation: default to empty list, document that user should configure (e.g., `["docs/**/*.md"]`).
- **R3: `jupytext` version/API drift.**
  - Mitigation: pin `jupytextPackage` option so users can override if needed; document tested version.
- **R4: MyST notebooks without proper frontmatter.**
  - Mitigation: document that MyST notebooks should have `jupytext` YAML headers for reliable round-trips; `jupytext` will warn if missing.

## Alternatives Considered

### Alternative A: keep single `nbqa` surface for all notebook types

Attempt to make `nbqa` work for MyST by claiming `.md` as a notebook type.

- Pros: simpler single-backend surface.
- Cons: **does not work** — live testing shows `nbqa` does not discover MyST `.md` files; would lie in code and tests.
- Why not chosen: incorrect implementation; violates grounded-truth requirement.

### Alternative B: use `mdformat-myst` for MyST formatting

Use `mdformat-myst` to format MyST markdown instead of `jupytext` + `ruff`.

- Pros: mdformat-native, no shell round-trip.
- Cons: **mangles notebook frontmatter** in live testing; does not respect notebook semantics; loses cell metadata.
- Why not chosen: unsafe for MyST notebooks; would corrupt notebook structure.

### Alternative C: keep `qmd` support

Retain Quarto file support alongside `ipynb` and MyST.

- Pros: broader compatibility out of the box.
- Cons: we do not use Quarto; adds dead code and test burden; PR prose overclaims.
- Why not chosen: not our toolchain; delete now and avoid drift.

## Implementation Plan

1. Rewrite ADR-031 (this file) to reflect MyST-first, jupytext-based design.
2. Update `fmt.nix`:
   - Split `nbqa` options into `ipynb` and `myst`.
   - Add `jupytextPackage` option.
   - Replace single `python-notebook-format` with separate formatters.
   - Remove `qmd` from defaults.
3. Update `checks.nix`:
   - Split `python.notebook` into `ipynb.ruff` and `myst.ruff`.
   - Add `jupytext` to MyST check buildInputs.
   - Remove `qmd` references from comments.
4. Update `pre-commit.nix`:
   - Split hooks into `nbqa-ruff` and `jupytext-ruff`.
   - Update `files` patterns to `\\.(ipynb)$` and MyST-specific.
   - Remove `qmd` from patterns.
5. Extend/update tests in `tests/fmt.nix`, `tests/checks.nix`, `tests/pre-commit.nix`.
6. Update README:
   - Remove `qmd` from notebook docs.
   - Document MyST `.md` support via `jupytext`.
   - Document that MyST includes require explicit configuration.

## Related

- Issue #50
- ADR-016: CI Checks Module
- ADR-029: Unified Quality-Gate Controls
- PR #110

______________________________________________________________________

Author: Jack
Date: 2026-02-21
PR: #110
