# ADR-048: Secondary uv Workspaces via `jackpkgs.python.extraWorkspaces`

## Status

Proposed

## Context

- `jackpkgs.python.workspaceRoot` is single-valued: the module loads exactly one
  uv2nix workspace and every `jackpkgs.python.environments.<name>` env is built
  from that one workspace's `uv.lock`. A repo with a second, standalone uv
  project (its own `pyproject.toml` + `uv.lock`, deliberately outside the
  primary workspace's resolution) has no supported path to a nix-built env — it
  must hand-roll the whole uv2nix chain (workspace load, Darwin SDK stdenv
  override, overlay composition, `mkVirtualEnv` post-processing) that this
  module already implements.
- Consumer evidence: cavinsresearch/zeus's `libs/trident-v2` (zeus ADR 265
  Decision 4; zeus#2310) is a standalone uv project pinned to a different
  `nautilus_trader` major than the primary workspace. It needs a nix env whose
  `nautilus-trader` package is replaced by a locally-built wheel derivation via
  an overlay — i.e. per-workspace `extraOverlays` on a second lockfile.
- Prior art: ADR-044 (`mkIsolatedUvEnv`) built a *standalone* simplified
  uv2nix helper in `lib/python-isolated-env.nix` for one-off tool envs, but it
  is deliberately decoupled from the module (no `buildFixes`, no
  `deterministicBytecode`, no group-spec combinators, no `packages.<name>` /
  `pythonEnvironments` publication). ADR-042 factored the group-selection
  combinators into `lib/python-group-spec.nix`, whose inputs are
  `workspace.deps.*` — already per-workspace by construction.
- Spec: jmmaloney4/jackpkgs#375 (cross-repo node PR0 of the Implementation
  Plan in cavinsresearch/zeus#2306).

## Decision

Add `jackpkgs.python.extraWorkspaces = attrsOf (submodule ...)` — declared
secondary uv workspaces that produce **plain (non-editable) virtual
environments** alongside the primary workspace. The feature is purely additive;
the primary path is behavior-preserving (verified: identical `drvPath` for both
editable and non-editable primary envs before/after the refactor).

### Option surface

Per workspace (`extraWorkspaces.<key>`):

- `workspaceRoot` (path, required) — MUST contain `pyproject.toml` and
  `uv.lock`.
- `sourcePreference` (`null | "wheel" | "sdist"`, default `null` = follow
  `jackpkgs.python.sourcePreference`).
- `extraOverlays` (list, default `[]`) — per-workspace package-set overlays;
  this is the hook the first consumer uses to swap in a locally-built wheel.
- `environments` (attrsOf submodule): `name`, `spec` / `includeGroups` /
  `groups`, `ignoreCollisions` — **same semantics as primary envs** (the spec
  resolution is literally the shared `resolveEnvSpec` code path). With no
  `editable` flag, `includeGroups = null` defaults to `false` (production
  deps only), matching primary non-editable envs.

### `mkWorkspaceScope` refactor (pure code motion)

The workspace → pythonSet → env-builder chain that lived inline in
`modules/flake-parts/python.nix` moved verbatim to
`lib/python-workspace-scope.nix` as `mkWorkspaceScope { workspaceRoot, sourcePreference, extraOverlays, label, ... }`. Deep-module lens: callers hand
in paths and preferences; all uv2nix / pyproject-nix machinery (workspace load,
Darwin SDK stdenv override, wheel-vs-sdist build-system overlay pairing,
deterministic-bytecode and build-fix overlays, `addMainProgram`
post-processing) stays behind the interface. The scope returns `{ workspace, pythonSet, defaultSpec, computeSpec, mkEnv, mkEnvForSpec, mkEditableEnv }`.

- The primary invocation passes the existing `cfg` values (including its
  independently-resolved `pyprojectPath` / `uvLockPath` and the flake-root
  editable default) with `label = "jackpkgs.python"`, so primary error messages
  and derivations are unchanged.
- Secondary invocations pass `label = "jackpkgs.python.extraWorkspaces.<key>"`
  so every fail-fast assert (pyproject present with `[project]` or
  `[tool.uv.workspace]`; `uv.lock` exists) names the offending workspace.
- Global `buildFixes`, `setuptools.packages`, `deterministicBytecode`,
  `darwin.sdkVersion`, and `pythonPackage` apply to **every** workspace
  (per-workspace `buildFixes` are out of scope; the fix overlay skips packages
  absent from a workspace's lock, so sharing is safe).

### Outputs & collision policy

- Secondary envs appear in `jackpkgs.outputs.pythonEnvironments` (flat, keyed
  by environment attribute key) and as `packages.<name>` — same as primary
  non-editable envs.
- Environment **names** and **attribute keys** share one namespace across the
  primary workspace and all `extraWorkspaces`; duplicates in either namespace
  throw at evaluation. The checks are forced via the merged env attrset (the
  pre-existing primary-only duplicate-name check was a latent unreferenced
  `let` binding that never fired; it is now enforced — an error-path-only
  tightening).

### Out of scope for secondary workspaces (enforced by construction)

The secondary `environments` submodule declares **no** `editable`,
`editableRoot`, `members`, or `provideDevTools` options, so setting them fails
module-system evaluation ("option does not exist") — this is the chosen
enforcement, rather than accept-and-throw. Consequences:

- No editable envs and no devshell hook wiring (`pythonEditableHook`,
  `jackpkgs.shell.inputsFrom`) for secondaries; those key off primary
  `environments` only.
- No checks/dev-tools participation: `lib/python-env-selection.nix` and the
  `checks` module discover tool environments from `cfg.environments` only.
- `pythonDefaultEnv` and `_module.args.pythonWorkspace` remain primary-only.

## Consequences

### Benefits

- A consumer declares a second lockfile in ~6 lines instead of hand-rolling
  uv2nix, and gets the module's hardening (Darwin SDK stdenv, deterministic
  bytecode, build fixes, venv post-processing) for free.
- Per-workspace `extraOverlays` gives the package-override hook zeus ADR 265
  Decision 4 needs without touching the primary set.
- The primary chain now has exactly one implementation shared by all
  workspaces; future fixes (e.g. new build hardening) apply everywhere.

### Trade-offs

- Secondary envs deliberately lack the editable/devshell/checks integrations;
  consumers wanting those for a second workspace must promote it to the
  primary workspace or wait for a future ADR.
- Global-only `buildFixes` means a secondary workspace needing a *different*
  fix for the same package name cannot express it; acceptable until a consumer
  actually needs it (compose later).

### Risks & Mitigations

- *Risk:* refactor drift on the primary path. **Mitigation:** verified
  byte-identical primary `drvPath`s (editable and non-editable) against
  origin/main during development; `nix flake check` runs the module tests.
- *Risk:* newly-enforced duplicate-name/key checks break a consumer that was
  silently shipping duplicates. **Mitigation:** duplicates were already
  incoherent (last-write-wins in `packages`), and the error names every
  env; considered an acceptable fail-fast tightening.

## Alternatives Considered

### Alternative A — Point consumers at ADR-044 `mkIsolatedUvEnv`

- Pros: already exists; zero module changes.
- Cons: no `extraOverlays`/`buildFixes`/bytecode hardening; results are not
  published via `pythonEnvironments`/`packages`; a second divergent uv2nix
  chain to maintain.
- Why not chosen: the first consumer specifically needs overlay-based package
  replacement plus standard publication; duplicating the chain again is the
  problem, not the solution.

### Alternative B — Allow multiple full workspaces (list-valued `workspaceRoot`)

- Pros: fully symmetric (editable envs, checks, devshell everywhere).
- Cons: editable-hook/devshell/checks discovery all assume one workspace;
  symmetric support multiplies every integration point and none of it is
  needed by the consumer at hand.
- Why not chosen: additive secondary workspaces cover the concrete need with a
  small, enforceable scope; symmetry can be a future ADR if demanded.

## Implementation Plan

- `lib/python-workspace-scope.nix` — `mkWorkspaceScope` (code motion).
- `modules/flake-parts/python.nix` — option declarations, primary scope
  invocation, secondary scope/env mapping, shared `resolveEnvSpec`, collision
  checks, output wiring.
- `tests/python-extra-workspaces.nix` + fixtures under
  `tests/fixtures/python-extra-workspaces/` (dependency-free `uv lock`
  lockfiles) — env presence, overlay application (module- and scope-level),
  duplicate name/key throws, missing-lock label.
- Consumer smoke (zeus PR3, cavinsresearch/zeus#2310) happens downstream via a
  jackpkgs input bump.

## Related

- Spec: jmmaloney4/jackpkgs#375; plan: cavinsresearch/zeus#2306
- Consumer: zeus ADR 265 Decision 4; cavinsresearch/zeus#2310 (`libs/trident-v2`)
- ADR-042 (group-spec combinators), ADR-044 (isolated uv2nix env helper),
  ADR-045 (explicit check environment selection)

______________________________________________________________________

Author: Claude (Fable 5), for Jack Maloney
Date: 2026-08-16
