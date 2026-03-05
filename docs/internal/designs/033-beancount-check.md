# ADR-033: Beancount `bean-check` Flake Check

## Status

Accepted

## Context

The `checks.nix` flake-parts module (established in ADR-016) provides reusable CI
quality gates for Python (pytest, mypy, ruff) and TypeScript (tsc, vitest, biome).
The module explicitly comments `# Future: golang, rust, etc. can be added here`,
signalling that additional language/tool checks are a natural extension point.

Consumers using jackpkgs to manage a [Beancount](https://beancount.github.io/)
double-entry accounting ledger need a way to run `bean-check` — the standard
Beancount linter — as a Nix flake check. This ensures the ledger is always
syntactically and semantically valid in CI and via `nix flake check`.

Key constraints:

- Beancount ledgers commonly use `include` directives and glob patterns (e.g.,
  `40-imports/mercury/*.beancount`). Running `bean-check` on a single file that
  references other files requires the full ledger directory to be present in the
  Nix sandbox.
- The consumer's Python environment (managed via `jackpkgs.python`) already
  includes beancount as a dependency; reusing it avoids a separate nixpkgs
  beancount package that may be a different version.
- Per ADR-029, `jackpkgs.checks` is the single source of truth for check
  enable/extraArgs configuration.
- The check should be **disabled by default** (opt-in), consistent with
  `jackpkgs.checks.biome.lint` and `jackpkgs.checks.python.numpydoc`.

## Decision

Add opt-in beancount check support to `modules/flake-parts/checks.nix` via three
new options under `jackpkgs.checks.beancount`:

- **`enable`** (`bool`, default `false`): opt-in gate; must be explicitly set to
  `true` by the consumer.
- **`ledgerFile`** (`nullOr path`, default `null`): path to the main beancount
  entry-point file. The entire parent directory (`builtins.dirOf ledgerFile`) is
  copied to the Nix store so that all `include` directives and glob patterns
  resolve correctly inside the sandbox.
- **`extraArgs`** (`listOf str`, default `[]`): additional arguments forwarded to
  `bean-check`.

The check is implemented using the existing `mkCheck` factory (`pkgs.runCommand` +
`touch $out`) consistent with all other checks in the module. The `bean-check`
binary is sourced from `pythonEnvWithDevTools` — the same Python environment used
for pytest, mypy, and ruff — so no additional package inputs are required.

The check is guarded by:

```
cfg.enable && cfg.beancount.enable && cfg.beancount.ledgerFile != null && pythonEnvWithDevTools != null
```

If `pythonEnvWithDevTools` is null (i.e., no Python workspace is configured), the
check silently produces an empty attrset, consistent with the existing behavior
of `pythonChecks` and `typescriptChecks`.

Consumer configuration example:

```nix
jackpkgs.checks.beancount = {
  enable = true;
  ledgerFile = ./books/beancount/ledger/main.beancount;
};
```

## Consequences

**Benefits:**

- Beancount ledger validity is enforced hermetically via `nix flake check` and CI.
- Reuses the existing Python environment — no version skew between the dev shell
  and the check.
- Opt-in default means existing consumers are unaffected.
- Copying `builtins.dirOf ledgerFile` (the ledger directory only, not the full
  project root) keeps the Nix derivation input small and fast.

**Trade-offs:**

- The check only validates that `bean-check` exits cleanly; it does not enforce
  balance assertions or custom plugin rules beyond what `bean-check` itself checks.
- If `pythonEnvWithDevTools` is null, the check silently skips rather than
  emitting a warning. This is consistent with other checks in the module but means
  a misconfigured consumer (python not enabled) gets no feedback.

**Risks and Mitigations:**

- *Risk:* Consumer sets `beancount.enable = true` without `jackpkgs.python.enable`
  and gets a silent no-op.
  *Mitigation:* Document the dependency in the option description. A future
  improvement could add a `lib.warn` when both conditions are met.
- *Risk:* Large ledger directory increases derivation build time.
  *Mitigation:* Only the ledger directory is copied, not the full project root.
  Nix content-addressing ensures the derivation is only rebuilt when ledger files
  change.

## Alternatives Considered

### A: Copy full `projectRoot` (like TSC/vitest checks)

Pros: consistent with TypeScript check pattern; no need to compute `dirOf`.
Cons: copies the entire repository into the Nix store unnecessarily. A ledger
directory is typically a small fraction of the project. Rejected for efficiency.

### B: Use `pkgs.beancount` from nixpkgs

Pros: no dependency on the jackpkgs Python environment; works even without
`jackpkgs.python.enable`.
Cons: the nixpkgs beancount version may differ from the version pinned in the
consumer's uv workspace, causing false passes or failures. Rejected to avoid
version skew.

### C: Add the check directly in the consumer flake (not in jackpkgs)

Pros: zero changes to jackpkgs; consumer has full control.
Cons: no reusability across consumers; boilerplate must be repeated. Rejected
because upstreaming is the explicit goal.

## Implementation Plan

1. Add `jackpkgs.checks.beancount.{enable,ledgerFile,extraArgs}` options to
   `modules/flake-parts/checks.nix` (before the `# Future` comment).
2. Add `beancountChecks` let-binding in the `perSystem` config block.
3. Add `{checks = beancountChecks;}` to the final `lib.mkMerge` list.
4. Update consumer flake (`jackpkgs.checks.beancount.enable = true; ledgerFile = ...`).

## Related

- ADR-016: CI Checks Module (established `checks.nix` and `mkCheck` pattern)
- ADR-029: Unified Quality Gate Controls (`jackpkgs.checks` as single source of truth)
- `modules/flake-parts/checks.nix`
- `modules/flake-parts/python.nix` (pythonEnvWithDevTools source)
- `lib/python-env-selection.nix` (selectPythonEnvWithDevTools logic)

---

*Author: Jack Maloney — 2026-03-05*
