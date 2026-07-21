# ADR 046: Remove mypy; ty becomes the sole type checker

## Status

Proposed

## Context

- `checks.python.mypy.typeChecker` is an enum `["mypy" "ty"]` whose
  `"mypy"` default is already documented as **deprecated** and slated for
  removal (`checks.nix:64-75`), and the mypy code path already emits a
  runtime deprecation warning (`checks.nix:609`).
- Both known consumers set `typeChecker = "ty"` (zeus `flake.nix:243`,
  garden `flake.nix:301`). The mypy branch is dead code in practice.
- The current naming is actively confusing: the check output is
  `checks.mypy` and the option namespace is `checks.python.mypy.*` even
  when the thing actually running is ty. Downstream documentation has to
  explain that "the mypy check runs ty".
- The mypy surface spans `checks.nix`, `pre-commit.nix`, `just.nix`,
  `lib/python-workspace-paths.nix`, and `lib/python-env-selection.nix`
  comments.

### Related prior art

- ADR 041 (typecheck path derivation) — PYTHONPATH machinery that exists
  substantially for mypy's benefit; ty resolves via `--python <env>` and
  does not need it.
- ADR 045 (explicit check-environment selection) — sibling ADR; the
  renamed `ty.environment` option defined there is the `--python`
  resolution target.

## Decision

1. The mypy code path MUST be removed entirely. ty is the only type
   checker.
2. Option namespace rename, hard break:
   - `checks.python.mypy.enable` → `checks.python.ty.enable`
   - `checks.python.mypy.extraArgs` → `checks.python.ty.extraArgs`
   - `checks.python.mypy.tyPackage` → `checks.python.ty.package`
     (the ty tool derivation)
   - `checks.python.ty.environment` — new, per ADR 045 (the `--python`
     resolution target; MUST NOT be required to provide the ty binary).
   - `checks.python.mypy.typeChecker` — deleted.
3. The check output MUST be renamed `checks.mypy` → `checks.ty`; the
   pre-commit hook id and just recipe MUST be renamed correspondingly.
4. Throwing tombstones MUST be provided for exactly the two option paths
   consumers are known to set — `mypy.typeChecker` and `mypy.tyPackage` —
   failing eval with migration text pointing at the ADR-046 renames. All
   other `mypy.*` paths fail naturally as unknown options of a closed
   submodule.
5. Dead-code sweep: the mypy check branch, `MYPY_CACHE_DIR`,
   `mypyDeprecationWarning`, mypy-specific `PYTHONPATH` export plumbing,
   and any helpers in the ADR-041 path-derivation lib that serve only
   mypy MUST be removed.

## Alternatives considered

- **Keep `typeChecker` enum with ty-only value**: rejected; a one-value
  enum is API noise, and the namespace would still be called `mypy`.
- **Silent compatibility shims for `mypy.*`**: rejected; both consumers
  are coordinated and adopt at input-bump time, so shims would be dead
  code from day one. Tombstones give the same migration UX at eval time
  without carrying a parallel API.
- **Rename options but keep `checks.mypy` output name** (avoid CI
  churn): rejected; CI enumerates outputs dynamically (nix-eval-jobs),
  so the only real blast radius is human, and the rename is precisely
  what deletes the standing confusion.

## Consequences

Pros:

- Names finally mean what they say; downstream "the mypy check runs ty"
  footnotes are deleted.
- Less code: one check implementation instead of two, no cache/PYTHONPATH
  plumbing that exists only for mypy.

Cons:

- Eval-breaking for any consumer still on `mypy.*` options (both known
  consumers are ready; the break is the point).
- Human-facing renames: docs, dashboards, and `just mypy`-style muscle
  memory need one-time updates in adoption PRs.

## Migration

Coordinated with ADR 045 adoption, same input bump per consumer:

1. zeus: `checks.python.mypy.typeChecker`/`extraArgs` config moves to
   `checks.python.ty.*`; per-hook pre-commit pins already deleted by the
   ADR 045 step; update any `just`/docs references to the `mypy` check
   name.
2. garden: same (`flake.nix:301-323`).
