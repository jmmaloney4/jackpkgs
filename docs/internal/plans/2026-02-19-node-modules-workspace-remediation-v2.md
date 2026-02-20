# Plan: Fix pnpm workspace symlinks in `node-modules` output (v2)

## Why this v2 exists

This replaces parts of the previous analysis with concrete evidence from a real consumer failure.

Issue: <https://github.com/jmmaloney4/jackpkgs/issues/160>

## Evidence from consumer logs

`nix flake check` fails while building `node-modules-1.0.0` during `fixupPhase`:

- `ERROR: noBrokenSymlinks: the symlink .../.pnpm/node_modules/data-catalog points to a missing target: /nix/store/deploy/platform/data-catalog`
- Similar failures for multiple workspace packages.
- Final summary: `found 8 dangling symlinks`.

This confirms the failure is real and is specifically `noBrokenSymlinks`.

## Corrected diagnosis

### 1) `cp -a node_modules $out` currently produces the wrong layout

In `modules/flake-parts/nodejs.nix`, install currently does:

```sh
cp -a node_modules $out
```

If `$out` does not already exist, this copies the *contents* of `node_modules` to `$out` root (not `$out/node_modules`).

That contradicts our own expected contract (`$out/node_modules`) and the checks helper assumptions (`findNodeModulesRoot` hardcodes `${storePath}/node_modules`).

### 2) Workspace links are relative and become store-root dangling targets

pnpm workspace links look like:

- `.pnpm/node_modules/@scope/pkg -> ../../../../deploy/platform/pkg`

With the current flattened output layout, these resolve to `/nix/store/deploy/...` and are missing, which is exactly what the log shows.

### 3) `noBrokenSymlinks` behavior in this case

`noBrokenSymlinks` is recursive and validates symlinks that resolve inside the Nix store.
These links resolve under `/nix/store/...`, so they are checked and fail.

### 4) There is a second, separate warning to address

The same run shows:

- warnings about `builtins.derivation` referencing `/nix/store/...-source` without proper context for `typescript-tsc` and `javascript-vitest`.

This is a checks-module string-context issue and should be treated as a separate fix track.

## Opinionated review of prior plan

What stays valid:

- Root cause is workspace symlink topology plus our export strategy.
- We need regression coverage.

What was missing or risky:

- It did not catch the output-layout bug (`$out` vs `$out/node_modules`).
- It jumped too quickly into a new public mode API without first landing a minimal safe fix.
- It proposed a custom symlink-scanning/materialization algorithm as the primary path, which is high complexity and high drift risk.

## New recommended plan

### Phase 0: Immediate unblock (small, safe, high impact)

1. Fix output layout in `modules/flake-parts/nodejs.nix`:

```sh
mkdir -p "$out"
cp -a node_modules "$out/"
```

2. Set:

- `dontCheckForBrokenSymlinks = true;`

for `jackpkgs.outputs.nodeModules` derivation.

Rationale:

- This unblocks consumers immediately.
- It restores the documented layout contract used by helpers/checks.
- It avoids large API/behavior changes while we validate runtime behavior.

### Phase 1: Make checks robust for workspace links

Current checks strategy symlinks store `node_modules` into sandbox source tree.
Because workspace links are resolved relative to store paths, this can still leave local-workspace links unusable.

Implement one of these (pick one, test, then commit):

- Preferred: in checks derivations, copy `node_modules` into sandbox workspace root instead of symlinking root store path.
- Alternative: keep symlinking but materialize required workspace paths under output.

Start with the preferred approach for lower complexity in module output behavior.

### Phase 2: Decide long-term strictness model

After Phase 0/1 are green in real consumer repos:

- If strict closure guarantees are still desired for `nodeModules`, introduce a mode option and a targeted materialization strategy.
- Do not add this API in the first patch unless required.

## Test plan (revised)

### A) Regression checks for module output shape

Add integration checks that build the actual module path and assert:

- output contains `$out/node_modules` (not flattened root),
- known workspace symlink exists in `.pnpm/node_modules`,
- build no longer fails in fixup with dangling symlink errors.

### B) Checks-runtime coverage

Add/extend integration fixture with `workspace:*` deps and verify `typescript-tsc` and `javascript-vitest` checks succeed with the updated linking/copy strategy.

### C) Negative coverage

Add an assertion that pre-fix behavior reproduces failure (or keep a documented repro command in plan/ADR notes).

### D) Warning cleanup coverage

Add focused test or evaluation assertion for the `builtins.derivation` context warning regression in checks derivations.

## Implementation details to avoid foot-guns

- Keep output contract stable: `jackpkgs.outputs.nodeModules` root is a derivation containing `node_modules/`.
- Do not silently change module public API in the first fix.
- Prefer simple shell logic over bespoke symlink graph walkers in first patch.
- Keep this change independent from private registry/auth concerns.

## Files expected to change

- `modules/flake-parts/nodejs.nix`
- `modules/flake-parts/checks.nix` (Phase 1)
- `flake.nix` integration checks
- `tests/checks.nix` (option/wiring + behavior expectations)
- `docs/internal/designs/023-return-to-pnpm.md` (clarify constraints and current behavior)
- `README.md` (if any user-facing option/behavior changes)

## Acceptance criteria

- Consumer repro no longer fails in `node-modules` fixup due to workspace symlink dangling targets.
- `jackpkgs.outputs.nodeModules` has expected `$out/node_modules` layout.
- `typescript-tsc` and `javascript-vitest` checks pass in workspace fixtures and in at least one real consumer.
- No new public option is added unless strictly necessary after Phase 1 validation.
