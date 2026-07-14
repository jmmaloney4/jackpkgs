# ADR-041: Python Monorepo Type-Check Path Derivation

## Status

Proposed

## Context

### Problem Statement

All three Python monorepos in Jack's owned ecosystem (Zeus, Garden, Yard) suffer from
the same configuration drift problem: **workspace membership is declared in one place
(`[tool.uv.workspace].members`), but the import-path lists consumed by pytest, mypy, and
ty are hand-maintained as separate lists in 2-4 different config locations per repo.**

Adding a new workspace package today requires touching up to four places:

1. `[tool.uv.workspace].members` (pyproject.toml)
2. `[tool.pytest.ini_options].pythonpath` (pyproject.toml)
3. `[tool.mypy].mypy_path` (pyproject.toml)
4. `ty.toml [environment].extra-paths` OR `[tool.ty.environment].extra-paths`

When a developer forgets one — which is easy to do because there is no validation — the
package silently fails type-checking or test collection, or worse, the tools resolve against
a stale Nix-store copy instead of the local source tree. This exact failure occurred in Zeus
when `libs/dlt/src` was missing from `ty.toml` `extra-paths`, causing `ty` to report
`Cannot resolve imported module cavins.libs.dlt.mspd` for a newly-added MSPD loader.

### Current State Across Repos

#### cavinsresearch/zeus

- **Workspace members:** `[tool.uv.workspace].members` (24 members, explicit list)
- **pytest:** `[tool.pytest.ini_options].pythonpath` (24 hand-maintained `<dir>/src` entries)
- **mypy:** `[tool.mypy].mypy_path` (colon-separated string, 24 entries)
- **ty:** `ty.toml [environment].extra-paths` (20 entries — **already drifted**, missing 4 members)
- **ty location:** separate `ty.toml` file, not in pyproject.toml

**Drift evidence:** `ty.toml` is missing `services/hades/src`, `services/mnemosyne/src`,
`services/periscope/src`, `libs/spotgamma/src` compared to the pytest/mypy lists. These
packages type-check fine today only because `ty` falls back to resolving them from the
installed environment, not from source — meaning type-checking runs against built artifacts,
not live source.

#### jmmaloney4/garden

- **Workspace members:** `[tool.uv.workspace].members` (15 members, explicit list)
- **pytest:** `[tool.pytest.ini_options].testpaths` (test dirs, not src roots — pytest resolves
  imports from the devshell's editable installs, not from `pythonpath`)
- **mypy:** `[tool.mypy].mypy_path` (list format, 15 entries)
- **ty:** no ty configuration at all (mypy only)

Garden avoids the pythonpath problem for pytest because the devshell provides editable
installs, so test collection resolves `jmmaloney4.*` packages from site-packages. But mypy
still needs an explicit `mypy_path` list that must be manually kept in sync with workspace
membership.

#### addendalabs/yard

- **Workspace members:** `[tool.uv.workspace].members` (glob patterns: `tools/*`, `libs/*`,
  `services/*`, plus exclusions)
- **pytest:** `[tool.pytest.ini_options].pythonpath` (15 hand-maintained entries)
- **mypy:** `[tool.mypy].mypy_path` (32 entries, uses `$MYPY_CONFIG_FILE_DIR` prefix)
- **ty:** `[tool.ty.environment].extra-paths` (34 entries — **more than mypy**, concrete drift)

**Drift evidence:** Yard's ty `extra-paths` has entries (`tools/capability_eval/src`,
`tools/selection_progress/src`, `tools/similarity_summary_runner/src`,
`tools/trade_taxonomy_seed/src`, `tools/trades_involved_runner/src`, `tools/features_runner/src`)
that are absent from `mypy_path`. These packages are type-checked by ty but not by mypy.

### Root Cause

The tools (pytest, mypy, ty) each have their own configuration format for declaring import
roots, and none of them natively understands `uv` workspace membership. `uv` knows the
workspace members; the type-checkers and test runners don't. The gap is bridged by manually
copying paths into each tool's config, with no mechanism to detect staleness.

This is not a bug in any individual tool — it's a **missing bridge** between workspace
metadata and tool configuration.

### Constraints

- All three repos use `uv` workspaces with `[tool.uv.workspace].members`
- All three use PEP 420 namespace packages (`cavins.*`, `jmmaloney4.*`, `addenda.*`)
- All three run type-checking from the repo root in pre-commit hooks and `nix flake check`
- Garden (Python 3.13) and Yard (Python 3.12) may not have `uv.workspace.members` in the
  same explicit-list format as Zeus (Yard uses glob patterns)
- jackpkgs already owns the Python environment infrastructure (`modules/flake-parts/python.nix`)
  and should own shared tooling that all three repos consume

## Decision

### 1. Workspace membership is the single source of truth

**MUST:** The `[tool.uv.workspace].members` list is the authoritative registry of workspace
packages. No other config may independently maintain a list of workspace package paths.

### 2. Type-check and test-runner paths are derived, not hand-maintained

**MUST:** `mypy_path`, `ty extra-paths`, and `pytest pythonpath` (where used) MUST be derived
from workspace membership by the mechanism that launches the tool, not hand-copied.

**MUST:** Any supported non-Nix invocation path (for example, direct `pre-commit` hooks)
MUST use the same derived workspace-path source or be explicitly declared unsupported during
rollout.

**MUST:** A repo MUST NOT claim ADR-041 implementation complete while any default developer
entry point still reads hand-maintained path lists. If non-Nix invocations are not yet wired
to the derived source, those commands MUST fail fast with a clear unsupported message rather
than continue with stale configuration.

**SHOULD:** Prefer running pytest against an installed editable environment (the jackpkgs
Python module already supports this) over injecting `pythonpath` entries. This eliminates
the pytest path list entirely — pytest resolves workspace packages from site-packages, same
as runtime.

### 3. jackpkgs provides a path-derivation utility

jackpkgs SHOULD provide a reusable utility (Nix function or Python script) that:

1. Reads `[tool.uv.workspace].members` from a given `pyproject.toml`
2. Resolves glob patterns (Yard uses `tools/*`, `libs/*`)
3. Honors the `exclude` list
4. Validates that each resolved member is an actual Python workspace package (for example,
   by checking for its own `pyproject.toml`), then maps it to its source root
   (`<member>/src` by convention) only when that directory exists or an explicit override is
   provided
5. Falls back to discovery for non-standard layouts and fails clearly when no Python source
   root can be determined for a validated member that should be type-checked
6. Returns the validated list in the format each tool expects

### 4. A drift-detection check catches stale hand-maintained lists

**MUST:** During the transition period (while repos still have hand-maintained lists), a
`nix flake check` or pre-commit check MUST validate that derived paths match the declared
paths, failing the build if they diverge. This prevents silent drift from re-accumulating.

## Consequences

### Benefits

- **One source of truth:** adding a workspace member only requires updating
  `[tool.uv.workspace].members`; all tools pick it up automatically
- **No silent drift:** type-checkers and test runners always see the complete workspace
- **Type-checking against source:** paths point at `src/` trees, not installed artifacts,
  so edits are checked immediately
- **Cross-repo consistency:** all three repos use the same derivation pattern from jackpkgs,
  reducing per-repo configuration burden

### Trade-offs

- **Build-time coupling:** the derivation runs at eval time (Nix) or pre-commit time (script),
  adding a small amount of complexity to config evaluation
- **Convention dependency:** the utility assumes `<member>/src` layout by default; repos with
  non-standard source roots need an escape hatch
- **Glob pattern resolution:** Yard's glob-style membership (`tools/*`) requires filesystem
  enumeration, which is straightforward in Nix but less so in a pure-Python pre-commit hook

### Risks & Mitigations

- **Risk:** Derived paths diverge from what an installed environment provides, causing
  different type-check results in devshell vs CI.

  - **Mitigation:** The utility derives from the same `pyproject.toml` that uv2nix reads, so
    the workspace membership is identical. Document that the editable environment hook (ADR-026)
    and the type-check paths must both originate from the same workspace object.

- **Risk:** Glob-pattern workspace members (Yard) produce non-deterministic path sets if the
  filesystem changes between eval and check.

  - **Mitigation:** Nix evaluates against the source tree at eval time; the derivation is
    deterministic for a given commit. The drift check runs against the same tree.

- **Risk:** Non-standard source roots (packages without `src/` or with nested layouts).

  - **Mitigation:** Provide a `sourceRootMap` override option in the utility for edge cases;
    default to `<member>/src`.

## Alternatives Considered

### Alternative A — Generate config files from a script

Run a Python script (pre-commit or `just` target) that reads `uv.workspace.members` and
regenerates the `mypy_path`, `ty extra-paths`, and `pytest pythonpath` entries in
`pyproject.toml` and `ty.toml`.

- **Pros:** Works with any toolchain; no Nix dependency; simple to understand
- **Cons:** Mutates tracked config files, creating noise in diffs and potential merge
  conflicts; requires all developers to run the script; doesn't help with CI's frozen
  evaluation
- **Why not chosen:** Mutating committed config files for derived values is an anti-pattern.
  The generation step becomes a mandatory pre-commit ritual that developers will forget.

### Alternative B — Nix eval-time derivation (Recommended)

Provide a Nix function in jackpkgs (`lib/python-workspace-paths.nix` or similar) that reads
`pyproject.toml` at eval time, resolves workspace members (including globs), and returns the
path list. The flake-parts checks (mypy, ty, pytest) consume this derivation instead of
hardcoded lists.

- **Pros:** Deterministic, no file mutation, runs in `nix flake check` naturally, integrates
  with the existing jackpkgs Python module infrastructure
- **Cons:** Only works inside Nix evaluation (pre-commit hooks that run tools directly outside
  Nix still need path config); requires the flake-parts checks module to be wired up
- **Why chosen:** All three repos already run their primary validation through `nix flake check`. The Nix derivation is the natural integration point.

### Alternative C — Type-check against installed workspace packages only

Instead of injecting source paths, run mypy and ty against an editable-installed environment
where all workspace packages are in site-packages. This is the "pure installed-package" model.

- **Pros:** Eliminates path injection entirely; tools see exactly what runtime sees
- **Cons:** Pre-commit hooks that run mypy/ty on changed files (not on installed packages)
  still need source roots; editable install in Nix can have namespace-package collision
  issues; adds environment-build latency to every type-check invocation
- **Why not chosen as primary:** Too large a migration for immediate value. This remains the
  ideal long-term target (see "Future Direction" below), but is out of scope for the MVP.

### Alternative D — Do nothing, document the manual process

Add a comment to each repo's config saying "remember to update all four lists when adding a
workspace member."

- **Pros:** Zero implementation effort
- **Cons:** Does not solve the problem; humans will continue to forget; drift will re-accumulate
- **Why not chosen:** The problem has already caused real failures (Zeus ty.toml drift).

## Implementation Plan

### Phase 1: jackpkgs path-derivation utility (MVP)

- **Owner:** jackpkgs maintainers
- Create `lib/python-workspace-paths.nix` with a function:
  ```nix
  workspaceSrcPaths = {
    pyprojectPath,    # path to pyproject.toml
    workspaceRoot,    # repo root as a Nix path
  }: [ ... ];  # returns list of "<member>/src" paths
  ```
- Resolve glob patterns (`tools/*`) against the filesystem at eval time
- Honor the `exclude` list from `[tool.uv.workspace]`
- Default source root convention: `<member>/src`; override via `sourceRootMap` argument
- Add nix-unit tests covering:
  - Explicit member lists (Zeus pattern)
  - Glob members (Yard pattern)
  - Excluded members
  - Non-standard source roots
- **Dependencies:** None
- **Timeline:** 1-2 days

### Phase 2: jackpkgs checks module integration

- **Owner:** jackpkgs maintainers
- Extend `modules/flake-parts/` (new or existing checks module) to accept the derived paths
  and wire them into mypy, ty, and pytest check derivations
- Each tool gets the path list in its native format:
  - mypy: colon-separated string or list (depending on config style)
  - ty: list of relative paths for `[environment].extra-paths`
  - pytest: list for `pythonpath` (or omit if editable env is available)
- Provide a `jackpkgs.checks.python` option that auto-discovers workspace members
- **Dependencies:** Phase 1
- **Timeline:** 2-3 days

### Phase 3: Consumer migration (per-repo)

- **Owner:** Each repo's maintainer (with jackpkgs support)
- Zeus: replace hand-maintained `mypy_path`, `ty.toml extra-paths`, and `pytest pythonpath`
  with the jackpkgs derivation; delete `ty.toml` in favor of inline `[tool.ty]` or
  jackpkgs-managed config
- Garden: replace `mypy_path` with derivation; consider adding ty configuration
- Yard: replace `mypy_path`, `ty extra-paths`, and `pytest pythonpath` with derivation
- Each migration: verify `nix flake check` still passes with the same (or better) coverage
- **Dependencies:** Phase 2
- **Timeline:** 1 day per repo

### Phase 4: Drift-detection guard

- **Owner:** jackpkgs maintainers
- Add a check (in `nix flake check` or pre-commit) that compares derived paths against any
  remaining hand-maintained lists, failing if they diverge
- This is transitional: once repos are fully migrated to Phase 2 derivation, the guard is
  unnecessary and can be removed
- **Dependencies:** Phase 2
- **Timeline:** 0.5 days

### Rollout Considerations

- **Backward compatibility:** repos that don't adopt the jackpkgs utility continue to work
  with their hand-maintained lists
- **Migration is per-repo:** no big-bang cutover; each repo migrates independently
- **ty.toml vs inline:** Zeus should move ty config from `ty.toml` into `[tool.ty]` in
  `pyproject.toml` (like Yard) only to consolidate static `ty` settings; derived path values
  should be supplied by the jackpkgs check integration at invocation time, not written back
  into tracked config files

## Future Direction

The ideal end-state is **Alternative C** (type-check against installed workspace packages).
Once jackpkgs' editable-environment infrastructure (ADR-026) is stable across all three repos
and namespace-package collisions are resolved, the path-injection model can be retired in favor
of tools running against site-packages. This ADR is the stepping stone that makes that
transition safe: by centralizing path derivation in jackpkgs now, the eventual switch from
"injected paths" to "installed packages" is a single change point, not three.

## Related

- ADR-003: Python (uv2nix) Flake-Parts Module
- ADR-005: Editable vs Non-Editable Environments
- ADR-006: Workspace-Only Python Projects
- ADR-026: Editable Environment Spec Logic — Auto-Include Workspace Members
- Zeus MSPD loader PR (triggering incident: missing `libs/dlt/src` in `ty.toml`)

______________________________________________________________________

Author: Jack Maloney (via Arthur)
Date: 2026-06-29
PR: TBD
