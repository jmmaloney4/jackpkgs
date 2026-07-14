# ADR 044: Isolated uv2nix Python environment helper

## Status

Proposed

## Context

- `jackpkgs.python` manages **one** uv workspace root with one `uv.lock`. This
  is the right design for the main repo Python environment.
- Some tool-specific ecosystems — `dbt-core` + `dbt-bigquery` is the canonical
  example — cannot coexist with the repo's main workspace lock. Their transitive
  constraints downgrade shared packages (`protobuf`, `google-cloud-storage`,
  `pathspec`, etc.) or require a different Python minor than the repo default.
- `cavinsresearch/zeus` solved this by wiring a **repo-local** `nix/dbt-env.nix`
  that calls `uv2nix` / `pyproject-nix` directly against a separate
  `warehouse/uv.lock`. This works but duplicates the same boilerplate in every
  repo that needs an isolated tool env:
  - Darwin SDK override (duplicated because the isolated env bypasses
    `jackpkgs.python`'s internal override).
  - `addMainProgram` post-processing (copied from the jackpkgs python module).
  - `venvIgnoreCollisions` wiring for namespace packages like `dbt/__init__.py`.
  - Overlay composition (base + build-systems).
- `jmmaloney4/garden` was bitten by the same problem: its `nix/dbt.nix` used
  nixpkgs `python3Packages.dbt-bigquery` (bypassing the repo's Python 3.13 pin),
  which broke eval when nixpkgs shifted its default `python3` to 3.14.

### Related prior art

- ADR 003 (python flake-parts module) — established the uv2nix workspace model.
- ADR 005 (editable vs non-editable envs) — environment type semantics.
- ADR 037 (Python 3.14 default interpreter) — `python314` became the default,
  which is what exposed the garden dbt bypass.

## Decision

- `jackpkgs` MUST provide a reusable helper function `mkIsolatedUvEnv` that
  builds a self-contained uv2nix Python virtualenv from a dedicated workspace
  root, independent of the main `jackpkgs.python` workspace.
- The helper MUST accept its own Python interpreter so it can be pinned to a
  different minor than the repo default.
- The helper MUST handle the Darwin SDK override internally so downstream repos
  do not duplicate it.
- The helper MUST support `ignoreCollisions` for namespace-package patterns
  (e.g., `dbt/__init__.py` shipped by both `dbt-core` and `dbt-bigquery`).
- The helper MUST set `meta.mainProgram` for clean `nix run` UX.
- The helper MUST NOT manage devshell integration or `PYTHONPATH` scrubbing.
  Those are the consumer's responsibility (different repos have different
  devshell shapes).
- The helper MUST NOT attempt to merge the isolated env into the main
  `jackpkgs.python` workspace. Isolation is the entire point.

### API

```nix
jackpkgs.lib.python.mkIsolatedUvEnvFactory {
  inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;
} {
  name = "python-dbt";
  workspaceRoot = ../warehouse;
  python = pkgs.python313;
  mainProgram = "dbt";
  ignoreCollisions = ["*/site-packages/dbt/__init__.py"];
}
```

The factory pattern is necessary because `lib/default.nix` is evaluated with
`{pkgs}` only — it does not have access to flake inputs. The consumer calls
`mkIsolatedUvEnvFactory` with the three uv2nix-related inputs, which returns
the parameterized `mkIsolatedUvEnv` function for per-system use.

### Consumer pattern

```nix
perSystem = {
  pkgs,
  config,
  inputs,
  ...
}: let
  mkIsolatedUvEnv = config.jackpkgs.lib.python.mkIsolatedUvEnvFactory {
    inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;
  };

  dbtEnv = mkIsolatedUvEnv {
    name = "python-dbt";
    workspaceRoot = ../warehouse;
    python = pkgs.python313;
    mainProgram = "dbt";
    ignoreCollisions = ["*/site-packages/dbt/__init__.py"];
  };
in {
  packages.python-dbt = dbtEnv;

  devShells.default = pkgs.mkShell {
    inputsFrom = [config.jackpkgs.outputs.devShell];
    buildInputs = [
      (pkgs.writeShellScriptBin "dbt" ''
        exec env -u PYTHONPATH -u PYTHONHOME ${dbtEnv}/bin/dbt "$@"
      '')
    ];
  };
};
```

### Scope

In scope:

- `lib/python-isolated-env.nix` — the helper function.
- `lib/default.nix` — factory exposure under `python.mkIsolatedUvEnvFactory`.
- `tests/python-isolated-env.nix` — nix-unit tests.
- `tests/fixtures/python-isolated-env/standard/` — minimal uv.lock fixture.
- ADR 044 (this document).
- README documentation.

Out of scope:

- A flake-parts module option (`jackpkgs.python.isolatedEnvironments`). This can
  be layered on later if multiple repos want declarative config; the function
  API is sufficient for now.
- Devshell wrapper generation. The consumer wraps the CLI shim because devshell
  composition varies per repo.
- Migrating downstream repos (Zeus, Garden). Separate PRs after this lands.

## Consequences

### Benefits

- Eliminates ~75 lines of duplicated uv2nix boilerplate per repo that needs an
  isolated tool env.
- Centralizes the Darwin SDK override so it stays in sync with jackpkgs'
  internal version.
- Makes the isolated-env pattern discoverable: `jackpkgs.lib.python.*` is where
  Python env helpers live.
- Tests validate the helper against a real `uv.lock` fixture.

### Trade-offs

- The factory pattern is slightly more complex than a direct function call.
  This is forced by lib/default.nix's `{pkgs}`-only evaluation context.
- Consumers still need to pass three flake inputs. A flake-parts module could
  hide this, but that's deferred (see scope).

### Risks & Mitigations

- **Stale SDK version**: the helper defaults `darwinSdkVersion = "15.0"`,
  matching the current jackpkgs.python default. If that default changes, both
  places need updating. Mitigation: the helper accepts `darwinSdkVersion` as
  an argument, and consumers can override it.
- **Helper drift from jackpkgs.python internals**: the overlay composition and
  `addMainProgram` logic mirror what `python.nix` does internally. If
  `python.nix` changes its approach, the helper may need updating. Mitigation:
  both are in the same repo and should be reviewed together.

## Alternatives Considered

### Alternative A — Flake-parts module option (`jackpkgs.python.isolatedEnvironments`)

```nix
jackpkgs.python.isolatedEnvironments.dbt = {
  workspaceRoot = ./warehouse;
  python = pkgs.python313;
  mainProgram = "dbt";
};
```

- Pros: declarative; consumer doesn't pass flake inputs; integrates with the
  existing module system.
- Cons: adds significant complexity to the already-large `python.nix` module;
  couples isolated env lifecycle to the main python module's `enable` flag;
  harder to unit-test in isolation.
- Why not chosen now: the function API is simpler and sufficient. The module
  option can be layered on top later without breaking the function.

### Alternative B — Keep the repo-local pattern (do nothing)

- Pros: zero work; repos already have working implementations.
- Cons: continued duplication; the Darwin SDK override drifts independently per
  repo; new repos that need isolation copy-paste from Zeus with no test
  coverage.
- Why not chosen: the pattern is now recurring (Zeus, Garden) and stable enough
  to abstract.

## Implementation Plan

1. Add `lib/python-isolated-env.nix` with `mkIsolatedUvEnv`.
2. Expose `python.mkIsolatedUvEnvFactory` from `lib/default.nix`.
3. Add `tests/fixtures/python-isolated-env/standard/` with a real `uv.lock`.
4. Add `tests/python-isolated-env.nix` nix-unit tests.
5. Register test in `flake.nix`.
6. Write ADR 044 (this document).
7. Update README.

### Rollout

- Zeus and Garden migrate in separate follow-up PRs after this helper lands.
- No backward compatibility concern — this is purely additive.

## Related

- Zeus implementation: `cavinsresearch/zeus/nix/dbt-env.nix`
- Zeus warehouse subproject: `cavinsresearch/zeus/warehouse/pyproject.toml`
- Garden dbt bug: `nix/dbt.nix` bypassing `jackpkgs.python.pythonPackage`

______________________________________________________________________

Author: Arthur (agent)
Date: 2026-07-14
