# Implementation Plan: Capture Workspace-Level node_modules (ADR-028)

**Date:** 2026-02-19
**ADR:** 028-pnpm-workspace-node-modules-capture
**Scope:** `modules/flake-parts/nodejs.nix`

## Problem Summary

The `nodeModules` derivation in `nodejs.nix` only copies root `node_modules/` into `$out`. pnpm also creates workspace-level `node_modules/` directories (e.g., `atlas/node_modules/`) containing symlinks for dependencies not hoisted to root. These are dropped, making non-hoisted workspace dependencies unreachable in Nix checks like `typescript-tsc`.

## Approach

The simplest correct fix: after `pnpm install` completes, find all workspace-level `node_modules/` directories and copy them into `$out` alongside the root `node_modules/`.

`linkNodeModules` in `checks.nix` already handles this case — it conditionally links `$nm_root/<pkg>/node_modules` if the directory exists. Once the store output includes these directories, checks work without any changes to `checks.nix`.

## Changes

### 1. `modules/flake-parts/nodejs.nix` — Expand `installPhase`

**Current** (lines ~122-125):

```nix
installPhase = ''
  mkdir -p "$out"
  cp -a node_modules "$out/"
'';
```

**Proposed:**

```nix
installPhase = ''
  mkdir -p "$out"
  cp -a node_modules "$out/"

  # Capture workspace-level node_modules directories.
  # pnpm creates these for dependencies not hoisted to root.
  # Without them, non-hoisted deps are unreachable in Nix checks.
  find . -mindepth 2 -name 'node_modules' -type d \
    -not -path './node_modules/*' \
    | while read -r ws_nm; do
      ws_dir="$(dirname "$ws_nm")"
      mkdir -p "$out/$ws_dir"
      cp -a "$ws_nm" "$out/$ws_nm"
    done
'';
```

**Why `find` instead of using workspace discovery from Nix:**
- pnpm only creates workspace-level `node_modules/` when needed (non-hoisted deps exist). Not all workspaces will have one.
- Using `find` captures exactly what pnpm produced — no reimplementation of pnpm's hoisting logic.
- The `nodejs.nix` module doesn't currently have access to workspace package lists, and adding that coupling isn't necessary.

**Constraints on `find`:**
- `-mindepth 2`: skip root `node_modules/` (already copied).
- `-not -path './node_modules/*'`: skip anything inside root `node_modules/` (e.g., `.pnpm/*/node_modules`).
- `-type d`: only actual directories, not symlinks named `node_modules`.

### 2. Verify `checks.nix` — No Changes Needed

The `linkNodeModules` function (lines ~291-325) already does:

```bash
if [ -d "$nm_root/$pkg/node_modules" ]; then
  ln -sfn "$nm_root/$pkg/node_modules" "$pkg/node_modules"
fi
```

Once `$out/atlas/node_modules/` exists in the store, this conditional will fire and link it into the check sandbox. No modifications needed.

### 3. No Changes to `pnpmDepsHash`

The `pnpmDeps` (fetchPnpmDeps) derivation captures the pnpm store tarball, not the linked `node_modules` layout. The hash doesn't change. Only the `nodeModules` derivation output changes (it's not fixed-output, so no hash update is needed).

## Verification

1. **Build the check:**
   ```
   nix build .#checks.aarch64-darwin.typescript-tsc -L
   ```
   Should pass — `@pulumi/command` (and any other non-hoisted workspace deps) will be resolvable.

2. **Inspect the store output:**
   ```
   ls $(nix build .#nodeModules --print-out-paths)/atlas/node_modules/@pulumi/
   ```
   Should show `command` (and any other atlas-specific deps).

3. **Full flake check:**
   ```
   nix flake check -L
   ```

## Estimated Effort

~15 minutes. Single-file change, 6 lines of Bash in `installPhase`.

## Risks

| Risk | Likelihood | Mitigation |
|------|-----------|-----------|
| Workspace `node_modules/` dirs contain broken symlinks (to workspace source files outside store) | Medium | Already handled: `dontCheckForBrokenSymlinks = true` is set on this derivation. Only the dep symlinks into `.pnpm/` are needed for resolution, and those resolve correctly within `$out/node_modules/.pnpm/`. |
| `find` picks up unexpected `node_modules/` dirs | Low | The `-mindepth 2 -not -path './node_modules/*'` filter is tight. Any extra dirs found would still be valid pnpm output. |
