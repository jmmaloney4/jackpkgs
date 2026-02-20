# ADR-028: Capture Workspace-Level node_modules in pnpm Nix Derivation

## Status

Proposed

## Context

### How pnpm Workspaces Link Dependencies

pnpm uses a **content-addressable store** with a strict, non-flat `node_modules` layout. In a monorepo with workspaces, pnpm resolves dependencies using three layers of symlinks:

1. **`.pnpm/` virtual store (root):** All packages — across all workspaces — are installed into `node_modules/.pnpm/<name>@<version>_<peer-hash>/node_modules/<name>`. This is the canonical location of every package's files.

2. **Root-level hoisted symlinks:** Dependencies declared in the **root** `package.json` get a symlink at `node_modules/<name>` pointing into `.pnpm/`. These are accessible to any workspace package via Node's upward `node_modules` resolution.

3. **Workspace-level symlinks:** Dependencies declared in a **workspace** `package.json` but **not** in root get a symlink at `<workspace>/node_modules/<name>` pointing into the root `.pnpm/` store. This is pnpm's strict isolation mechanism — packages can only resolve what they explicitly declare.

For example, in a monorepo where root declares `@pulumi/pulumi` but only `atlas/` declares `@pulumi/command`:

```
node_modules/
  .pnpm/
    @pulumi+command@1.1.3_.../node_modules/@pulumi/command/  # actual files
    @pulumi+pulumi@3.214.1_.../node_modules/@pulumi/pulumi/  # actual files
  @pulumi/
    pulumi -> .pnpm/@pulumi+pulumi@3.214.1_.../node_modules/@pulumi/pulumi  # hoisted
    # NO @pulumi/command here — not in root package.json

atlas/
  node_modules/
    @pulumi/
      command -> ../../node_modules/.pnpm/@pulumi+command@1.1.3_.../node_modules/@pulumi/command
      # workspace-level link — only way to resolve @pulumi/command from atlas/
```

This is **by design**. pnpm's strict linking prevents "phantom dependencies" — a workspace package cannot accidentally import something it doesn't declare, even if a sibling workspace caused it to be installed.

### What jackpkgs Currently Does

The `nodeModules` derivation in `nodejs.nix` runs `pnpm install` (via `pnpmConfigHook`) and then captures the result:

```nix
installPhase = ''
  mkdir -p "$out"
  cp -a node_modules "$out/"
'';
```

This copies **only** the root `node_modules/` directory. Workspace-level `node_modules/` directories (e.g., `atlas/node_modules/`) are silently dropped.

The `typescript-tsc` check in `checks.nix` then:

1. Copies the project source into a writable sandbox.
2. Calls `linkNodeModules` which symlinks `$nm_root` to `node_modules` at root.
3. For each workspace, conditionally links `$nm_root/<pkg>/node_modules` **if it exists** in the store.
4. Runs `tsc --noEmit` in each workspace.

### How This Breaks

Because workspace-level `node_modules/` directories are never captured in the store output, step 3 above finds nothing to link. When `tsc` runs inside `atlas/`, Node's module resolution walks up from `atlas/` to root `node_modules/`. But root `node_modules/@pulumi/command` doesn't exist (it's not hoisted — only in `.pnpm/` virtual store). The workspace-level link that would normally resolve it (`atlas/node_modules/@pulumi/command`) is missing.

Result: `TS2307: Cannot find module '@pulumi/command'`.

This affects **any** dependency that is:

- Declared in a workspace package but not in root `package.json`, AND
- Therefore not hoisted to root `node_modules/`

This will grow more common as workspaces add workspace-specific dependencies.

### Relationship to Existing Work

ADR-023 established the pnpm migration and the `$out/node_modules` API. Existing remediation plans (v1 and v2) addressed a related but distinct issue: **broken symlinks** inside `.pnpm/` where workspace packages' symlinks point to workspace directories outside `node_modules/`. The `dontCheckForBrokenSymlinks = true` workaround was applied.

This ADR addresses a **different gap**: workspace-level `node_modules/` directories are not captured at all, making non-hoisted dependencies unreachable in Nix checks.

## Decision

Extend the `nodeModules` derivation's `installPhase` to also capture workspace-level `node_modules/` directories, preserving pnpm's intended resolution structure.

The output API expands from `$out/node_modules/` to also include `$out/<workspace>/node_modules/` for any workspace that pnpm created a `node_modules/` directory for.

## Consequences

### Benefits

- **Correct pnpm semantics in Nix:** The Nix-built `node_modules` output faithfully represents pnpm's resolution structure, including workspace-specific dependency links.
- **No consumer workarounds:** Downstream repos don't need to force-hoist dependencies to root `package.json` to work around Nix packaging limitations.
- **Scales with workspaces:** New workspace-specific dependencies automatically work without manual intervention.
- **`linkNodeModules` already handles it:** The existing conditional in `checks.nix` (`if [ -d "$nm_root/<pkg>/node_modules" ]`) will automatically start linking workspace `node_modules/` once they appear in the store output.

### Trade-offs

- **Slightly larger store output:** Workspace `node_modules/` directories contain symlinks back to `.pnpm/`, so the size increase is minimal (symlinks, not file copies).
- **Output API surface grows:** Consumers that inspect `$out/` will see workspace directories alongside `node_modules/`. This is a minor but observable change.

### Risks & Mitigations

| Risk                                                                                                         | Mitigation                                                                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Workspace `node_modules/` may contain broken symlinks (pointing to workspace source files outside the store) | Already mitigated by `dontCheckForBrokenSymlinks = true` from remediation v2. Only `@pulumi/*`-style dep symlinks (pointing into `.pnpm/`) are needed; those resolve correctly within the copied `node_modules/`. |
| `find` command to discover workspace `node_modules/` may pick up unwanted directories                        | Scope the find to known workspace paths from `pnpm-workspace.yaml`, or exclude `.pnpm/` and root `node_modules/` explicitly.                                                                                      |
| Breaking change for consumers relying on `$out/` containing only `node_modules/`                             | Low risk. `linkNodeModules` already conditionally handles workspace dirs. No known consumer inspects `$out/` layout beyond `node_modules/`.                                                                       |

## Alternatives Considered

### A: Force-Hoist All Dependencies to Root `package.json`

Add every workspace dependency to root `package.json` so pnpm hoists everything, eliminating the need for workspace-level `node_modules/`.

**Pros:** No Nix changes needed; works immediately.

**Cons:** Anti-pattern that defeats pnpm's strict isolation. Creates phantom dependency risk — any workspace could import anything without declaring it. Requires manual maintenance as workspaces evolve. Scales poorly.

**Why not:** This fights pnpm's design philosophy. The tooling should support the package manager's semantics, not the other way around.

### B: Reconstruct Workspace `node_modules/` in `linkNodeModules` Instead of Capturing Them

Rather than copying workspace `node_modules/` from the build, have `linkNodeModules` in `checks.nix` parse workspace `package.json` files and create the necessary symlinks into `.pnpm/` at check time.

**Pros:** Keeps the `nodeModules` output minimal.

**Cons:** Reimplements pnpm's linking logic in Bash/Nix. Fragile — must track pnpm version changes and peer dependency hashing. More complex code to maintain. Duplicates work that pnpm already did correctly during install.

**Why not:** Capturing what pnpm produces is simpler and more correct than reimplementing its logic.

## Implementation Plan

See `docs/internal/plans/2026-02-19-pnpm-workspace-node-modules-capture.md`.

## Related

- **ADR-023:** Return to pnpm — established the `nodeModules` derivation and `$out/node_modules` API.
- **Remediation v2 plan:** Fixed `$out` layout bug and added `dontCheckForBrokenSymlinks`.
- `modules/flake-parts/nodejs.nix` — `nodeModules` derivation.
- `modules/flake-parts/checks.nix` — `linkNodeModules` and `typescript-tsc` check.

______________________________________________________________________

**Author:** jack
**Date:** 2026-02-19
