# ADR 045: Explicit check-environment selection for Python checks

## Status

Proposed

## Context

- Every Python check emitted by `modules/flake-parts/checks.nix` (pytest,
  type-check, ruff, notebook-ruff) resolves against a **single shared
  environment**, `pythonEnvForChecks`, selected at `checks.nix:563-566`:
  prefer `jackpkgs.outputs.pythonDefaultEnv` (the environment literally named
  `default`), else fall back to the `provideDevTools` helper
  (`lib/python-env-selection.nix`), else synthesize an all-groups
  `python-ci-checks` env.
- The pre-commit and just modules resolve their tool environment through
  `selectDevToolsPackage` (`lib/python-env-selection.nix:58-73`,
  consumed at `pre-commit.nix:498` and `just.nix:207,214`) with the
  **opposite preference order**: devtools env first, `pythonDefaultEnv`
  second. The same concept — "which env carries the quality-gate tools" —
  is answered by two divergent code paths.
- The `default`-first preference in `checks.nix` (introduced in `303c371`)
  assumes the default env carries dev tools via the workspace spec. Both
  known consumers structure their environments the other way — a
  runtime-only `default` plus a leaned-down dev-tools env — and both were
  forced into the identical sledgehammer workaround:
  - `cavinsresearch/zeus` `flake.nix:394`:
    `jackpkgs.outputs.pythonDefaultEnv = lib.mkForce ...pythonEnvironments.dev;`
  - `jmmaloney4/garden` `flake.nix:381`: same `mkForce`, with a comment
    explicitly blaming the `303c371` preference change.

  `mkForce` on a module *output* re-points every consumer of
  `pythonDefaultEnv`, not just checks — it works only because nothing else
  currently depends on the distinction. Without it, checks silently resolve
  against a runtime-only env and fail with `pytest: command not found` (or
  worse, run against an env missing dev-only stubs).
- One per-check escape hatch already exists and works:
  `checks.python.numpydoc.package` (`checks.nix:177-195`, resolution at
  `checks.nix:617-620`). It is the precedent this ADR generalizes.
- `pythonVersion` (and thus `PYTHONPATH`) is derived once from the shared
  env (`checks.nix:570-576`). This is a latent bug the moment any two
  checks resolve against environments with different interpreters.
- Downstream motivation (zeus): checks should run against tightly-scoped
  environments so that operator-facing environments (research/notebook
  tooling) can grow without fattening the CI check closure or gaining the
  ability to break quality gates. Tracked in ergodicsystems/hq#236
  (private).

### Related prior art

- ADR 042 (selective dependency groups) — introduced list-form
  `includeGroups` and `provideDevTools`; this ADR completes the story by
  making check-env selection *declarative* instead of heuristic.
- ADR 041 (typecheck path derivation) — the PYTHONPATH machinery affected
  by per-check version derivation.
- `checks.python.numpydoc.package` — existing per-check env override.

## Decision

1. `jackpkgs.checks.python` MUST gain a new option `environment`
   (`nullOr package`, default `null`): the environment all Python checks
   resolve against when set.
2. Each Python check MUST gain a per-check `environment` option
   (`checks.python.pytest.environment`, `checks.python.ty.environment`
   (see ADR 046), `checks.python.ruff.environment`,
   `checks.python.numpydoc.environment`), default `null`.
3. Resolution order per check MUST be:
   **per-check `environment` → global `checks.python.environment` →
   legacy chain** (`pythonDefaultEnv` → `provideDevTools` helper →
   synthesized all-groups env). The legacy chain is unchanged in ordering
   — consumers migrate by declaring, not by being migrated.
4. The notebook-ruff (nbqa) check MUST follow `ruff.environment`
   resolution; it does not get its own option.
5. `numpydoc.package` MUST become a deprecated alias of
   `numpydoc.environment`: when set it is honored, with an eval-time
   `lib.warn` naming the rename. Its legacy `pythonEnvironments.dev`
   fallback slots *below* the new global option.
6. `selectDevToolsPackage` (pre-commit, just) MUST honor the global
   option first: `checks.python.environment` → devtools env →
   `pythonDefaultEnv` → fallback. Per-check overrides MUST NOT apply to
   pre-commit/just — they configure "the tools env", not a per-check
   split. Existing per-hook `package` options remain as consumer-side
   overrides.
7. Any Python check falling through to the legacy chain MUST emit an
   eval-time `lib.warn` recommending `checks.python.environment`. This is
   deliberately noisy from day one; both known consumers migrate promptly
   (see Migration).
8. Each check's `setupCommands` MUST guard tool presence with a fail-fast
   check (`test -x <env>/bin/<tool>`) that names the check, the
   environment, and the fix ("add <tool> to the env's dependency
   groups"). Contract per tool:
   - pytest / ruff / numpydoc environments MUST provide their binary
     (ruff's env is consulted *only* for its binary);
   - the type-check environment (ADR 046: `ty.environment`) is the
     `--python` resolution target and MUST NOT be required to provide
     the checker binary (that comes from `ty.package`).
9. `pythonVersion` / `PYTHONPATH` MUST be derived per check from that
   check's resolved environment, fixing the shared-derivation latent bug.

## Alternatives considered

- **Flip the legacy preference order** (devtools env before `default`,
  matching `selectDevToolsPackage`): rejected. It silently re-points check
  envs for any consumer defining both, rebuilding every check derivation
  with no opt-in. Explicit declaration supersedes both orderings without
  perturbing either.
- **Global option only, per-check deferred**: rejected. The per-check
  plumbing is what forces the per-check `pythonVersion` fix; deferring it
  means touching every check twice.
- **Promote the option outside `checks.*`** (e.g.
  `jackpkgs.python.toolsEnvironment`) since it also steers pre-commit and
  just: rejected for discoverability — `checks.python.environment` is
  where users will look, and the pre-commit/just coupling is documented
  here and in the option docstring.
- **Silent alias for `numpydoc.package` / no deprecation warning**:
  rejected; the API should converge on one name, and the warning is the
  mechanism.

## Consequences

Pros:

- Check-env selection becomes declarative; both known consumers delete an
  `mkForce` on a module output.
- One source of truth for checks, pre-commit, and just; the
  divergent-orderings asymmetry can no longer bite anyone who sets the
  option.
- Per-check scoping enables downstream env-slicing (e.g. a minimal ruff
  env) without touching jackpkgs again.
- Mis-scoped environments fail with actionable messages instead of
  exit-127 noise.

Cons:

- Eval warnings are noisy for consumers between the jackpkgs bump and
  their adoption change (accepted deliberately).
- Blast radius spans `checks.nix`, `pre-commit.nix`, `just.nix`, and
  `lib/python-env-selection.nix`, not just checks.
- API surface grows by five options plus one alias.

## Migration

1. jackpkgs: implement + release (implementation issue tracks this ADR).
2. zeus: set
   `jackpkgs.checks.python.environment = config.jackpkgs.outputs.pythonEnvironments.dev;`,
   delete the `mkForce` (`flake.nix:394`) and the per-hook pre-commit pins
   (`flake.nix:373-384`).
3. garden: same substitution for its `flake.nix:381` `mkForce`.

## Future work

- Once zeus and garden are migrated, the legacy chain has zero known
  users; the synthesized all-groups `python-ci-checks` fallback becomes a
  **candidate** for removal (kept for zero-config first-run UX until
  explicitly decided).
- A first-class `shell.pathEnvironments`-style option for putting named
  envs on the devshell PATH (today: manual via `shell.packages`) is
  convenience follow-up, out of scope here.
