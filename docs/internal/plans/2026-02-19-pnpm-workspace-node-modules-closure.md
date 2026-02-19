# Plan: Workspace-safe `nodeModules` export for pnpm workspaces

## Context

Issue: <https://github.com/jmmaloney4/jackpkgs/issues/160>

Current `jackpkgs.nodejs` behavior installs dependencies with `pnpmConfigHook`, then exports only `node_modules` via:

```sh
cp -a node_modules $out
```

In pnpm workspaces, some links inside `node_modules/.pnpm/node_modules/*` point back to local workspace directories (for example `../../../../packages/lib`).
When we copy only `node_modules`, those workspace targets are missing in `$out`, so the links become dangling and fail `noBrokenSymlinks` in fixup.

This is reproducible with our own fixtures: workspace links resolve in source tree, but become broken after a `node_modules`-only copy.

## Goals

- Keep pnpm workspace support reliable for `jackpkgs.nodejs.enable = true`.
- Preserve strict behavior by default (do not silently ignore broken links).
- Keep the public output contract (`$out/node_modules`) stable.
- Add explicit regression coverage so this cannot silently reappear.

## Non-goals

- Redesign pnpm install semantics in nixpkgs (`pnpmConfigHook`, `fetchPnpmDeps`).
- Eliminate all symlinks from pnpm outputs.
- Solve unrelated private registry auth concerns in this plan.

## Option Analysis

### A) Disable broken symlink checks

Implementation: set `dontCheckForBrokenSymlinks = true` on `nodeModules` derivation.

Pros:
- Very small change.
- Immediate unblock.

Cons:
- Weakens guarantees.
- Can hide real breakage and make downstream failures harder to diagnose.

### B) Workspace-aware export (materialize targets)

Implementation: keep strict checks; when a `node_modules` symlink resolves to a local workspace path, copy that path into `$out` so the existing symlink resolves.

Pros:
- Keeps strong guarantees.
- Fixes root cause instead of suppressing symptom.
- Works with existing pnpm link topology.

Cons:
- Slightly larger output size.
- More implementation complexity.

### C) Configurable behavior

Implementation: expose mode option so users can pick strict or escape-hatch behavior.

Pros:
- Backward compatibility and operational flexibility.
- Lets strict mode be default without blocking edge cases.

Cons:
- Adds API surface area.

## Recommendation

Implement **B + C**:

- Default mode: strict workspace-aware materialization.
- Escape hatch mode: allow broken workspace links (temporary/advanced use).

This provides a safe default while still giving consumers an emergency override.

## Proposed Design

### 1) Module option changes (`modules/flake-parts/nodejs.nix`)

Add:

- `jackpkgs.nodejs.nodeModulesWorkspaceMode` (enum)
  - `"materialize-workspace"` (default)
  - `"allow-broken"`

Behavior:

- `materialize-workspace`:
  - build with current pnpm flow;
  - export `node_modules` to `$out`;
  - copy local workspace symlink targets into `$out/<workspace-relative-path>`;
  - keep standard symlink checks enabled.
- `allow-broken`:
  - preserve current copy-only behavior;
  - set `dontCheckForBrokenSymlinks = true`.

### 2) Export algorithm (strict/materialize mode)

In `installPhase`, after pnpm install:

1. Identify all symlinks under source `node_modules`.
2. Resolve each link target.
3. Select targets that:
   - resolve inside workspace root (`$PWD`), and
   - are outside `$PWD/node_modules`.
4. Record target paths relative to workspace root.
5. `cp -a node_modules $out`.
6. For each recorded relative target path:
   - create parent dirs in `$out`;
   - copy source path from `$PWD/<rel>` to `$out/<rel>` preserving symlinks/metadata.

Important details:

- Deduplicate target paths before copy.
- Keep copy deterministic (stable sorted list).
- Do not materialize paths outside workspace root.
- Preserve pnpm symlinks; only ensure their targets exist in output.

### 3) Output contract

- Continue to guarantee `node_modules` at `$out/node_modules`.
- Allow additional paths in `$out` when required to satisfy workspace links.
- Document this explicitly (ADR + README module options section).

## Test Plan (Thorough)

### A) New integration checks (`flake.nix`)

Add a dedicated check for workspace export closure using a fixture with `workspace:*` dependency:

- Build with same pnpm inputs as module (`fetchPnpmDeps` + `pnpmConfigHook`).
- Use the same export logic path as module (prefer shared helper to avoid drift).
- Assertions:
  - expected workspace symlink exists (for regression signal),
  - symlink target resolves after export (`test -e` on symlink),
  - no broken links under exported `node_modules`.

Add a second check for escape hatch mode:

- `nodeModulesWorkspaceMode = "allow-broken"`.
- Build succeeds despite dangling workspace link.
- Assert at least one known workspace symlink is dangling (`test -L` and `! test -e`) to prove mode is active.

### B) Nix-unit tests (`tests/*.nix`)

Add option/evaluation coverage:

- default value is `"materialize-workspace"`;
- explicit `"allow-broken"` value is accepted;
- invalid enum value fails evaluation;
- derivation wiring toggles `dontCheckForBrokenSymlinks` only in `allow-broken` mode.

### C) Regression fixture strategy

Reuse or add minimal fixture containing:

- `pnpm-workspace.yaml`
- `workspace:*` dependency from app -> lib
- lockfile where importer resolves workspace link (`link:../...`)

Keep fixture intentionally small to minimize hash churn and CI time.

### D) End-to-end verification commands

Run at minimum:

- `nix build .#checks.$(nix eval --raw --expr builtins.currentSystem).pnpm-workspace-node-modules-closure`
- `nix build .#checks.$(nix eval --raw --expr builtins.currentSystem).pnpm-workspace-node-modules-allow-broken`
- `nix flake check`

If available, run one real-consumer smoke test (`nix develop --command true`) on the repo that originally reported #160.

## Implementation Steps

1. Add new mode option and docs in `modules/flake-parts/nodejs.nix`.
2. Implement workspace-target materialization in `nodeModules.installPhase`.
3. Add `allow-broken` branch (`dontCheckForBrokenSymlinks = true`).
4. Add integration check(s) in `flake.nix` that exercise exported output closure.
5. Add nix-unit option wiring tests.
6. Update ADR-023 with explicit output contract + mode semantics.
7. Update `README.md` module options/docs (flake-only scope) to include new option and guidance.

## Risks and Mitigations

- Output size increase from copied workspace paths.
  - Mitigation: copy only paths actually referenced by workspace symlinks.
- Behavior drift between module logic and integration checks.
  - Mitigation: factor export logic into shared helper used by both.
- Hidden misuse of escape hatch.
  - Mitigation: document `allow-broken` as temporary/advanced mode, default strict.

## Acceptance Criteria

- `jackpkgs.nodejs` works for workspace fixtures with `workspace:*` without broken symlink failures in strict/default mode.
- New regression checks fail on pre-fix behavior and pass after fix.
- Escape-hatch mode remains available and explicitly tested.
- ADR-023 and README accurately describe behavior and option surface.
