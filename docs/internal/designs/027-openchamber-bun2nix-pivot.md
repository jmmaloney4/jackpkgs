# ADR-027: OpenChamber Packaging — Pivot to bun2nix

## Status

Accepted

**Supersedes:** ADR-026

## Context

ADR-026 proposed using a fixed-output derivation (FOD) with `bun install` and `cp -rL` to dereference symlinks. After implementation, this approach failed catastrophically:

### Problems Encountered

1. **`cp -rL` destroys Bun's module resolution**
   - Bun creates a symlink-heavy `node_modules` layout where packages point into `.bun/install/cache/`
   - Dereferencing these symlinks creates a flattened structure where internal `require()` calls between packages break
   - Node/Bun's module resolution algorithms depend on the directory hierarchy and symlink structure

2. **Runtime module resolution failures**
   - `body-parser` was present under `.bun/node_modules` but not exposed at top-level
   - Required a workaround to recreate symlinks for transitive deps
   - This pattern repeated for many packages

3. **Build-time failures**
   - `vite build` failed with `Cannot find module 'rollup/parseAst'`
   - The flattened `node_modules` broke Vite's dependency tree traversal

4. **17+ minute `fixupPhase`**
   - Dereferenced `node_modules` contains thousands of individual files
   - Nix's `fixupPhase` walks every file for shebang patching, reference scanning, and stripping
   - This is architecturally slow for large JS dependency trees

5. **Hash bootstrapping friction**
   - FOD uses `lib.fakeSha256` requiring manual hash prefetch
   - Every upstream dependency change invalidates the entire cache
   - No granular caching

### Research Findings

- nixpkgs has no built-in Bun builder
- **`nix-community/bun2nix`** (v2.0.8) is the idiomatic solution:
  - Per-package FODs using integrity hashes from `bun.lock`
  - Preserves Bun's symlink structure via `$BUN_INSTALL_CACHE_DIR`
  - Respects Nix sandbox fully
  - Supports native deps via `autoPatchElf`
  - No prefetch step needed (uses lockfile hashes directly)

## Decision

Pivot to **`bun2nix`** for packaging OpenChamber.

The package MUST use `bun2nix.fetchBunDeps` to fetch dependencies as per-package FODs, then `bun2nix.hook` to run `bun install` against the pre-fetched cache in a sandboxed derivation.

### Architecture

```
flake.nix
├── inputs.bun2nix = github:nix-community/bun2nix
│
├── packages.openchamber = stdenv.mkDerivation {
│     nativeBuildInputs = [ bun2nix.hook bun nodejs ];
│     bunDeps = bun2nix.fetchBunDeps { bunNix = ./bun.nix; };
│     
│     buildPhase = ''
│       # bun install uses pre-fetched cache, sandboxed
│       bun install --frozen-lockfile
│       
│       # Build frontend with Vite
│       cd packages/web
│       bun run build
## Consequences

### Benefits

- **Sandboxed builds** — No impure network access during build
- **Granular caching** — Per-package FODs; changing one dep doesn't invalidate everything
- **Preserved module resolution** — Bun's symlink structure stays intact
- **No prefetch step** — Uses integrity hashes from `bun.lock` directly
- **Native dep support** — `autoPatchElf` handles sharp/vips, node-pty
- **Faster fixupPhase** — Fewer files in `$out` (no flattened node_modules)

### Trade-offs

- **External flake input** — `bun2nix` is not in nixpkgs
- **Bun 1.2+ required** — Requires `bun.lock` (JSON format), not legacy `bun.lockb`
- **Young tool** — v2.0.8, some workspace-related bugs reported
- **Extra step** — Must run `bun2nix -o bun.nix` to generate the deps file

### Risks & Mitigations

- **Risk**: bun2nix workspace support may be buggy for monorepos
  - **Mitigation**: Fall back to `buildNpmPackage` with `package-lock.json`
- **Risk**: OpenChamber uses legacy `bun.lockb` format
  - **Mitigation**: Regenerate with Bun 1.2+ to get `bun.lock` (JSON)
- **Risk**: Native deps (sharp, node-pty) may need patching
  - **Mitigation**: Use `autoPatchElf` and overrides in `fetchBunDeps`

## Alternatives Considered

### Alternative A — Continue with impure FOD + `cp -rL` (ADR-026)

- Pros: Already implemented
- Cons: Fundamentally broken module resolution, slow fixup, friction on updates
- Why not chosen: Architectural mismatch with Bun's symlink-based layout

### Alternative B — `buildNpmPackage` with `package-lock.json`

- Pros: Battle-tested, built into nixpkgs, well-documented
- Cons: Requires maintaining separate `package-lock.json`, diverges from upstream
- Why not chosen: bun2nix is more faithful to upstream; fallback if bun2nix fails

### Alternative C — `dream2nix`

- Pros: Module-based, flexible
- Cons: No Bun support, unstable APIs, labeled as "experimental"
- Why not chosen: Not applicable to Bun projects

## Implementation Plan

1. Add `bun2nix` as flake input
2. Check if OpenChamber has `bun.lock` (JSON) or `bun.lockb` (binary)
3. If `bun.lockb`, regenerate with Bun 1.2+ to get `bun.lock`
4. Run `bun2nix -o pkgs/openchamber/bun.nix` to generate deps file
5. Rewrite `pkgs/openchamber/default.nix` using `bun2nix.fetchBunDeps` and `bun2nix.hook`
6. Build and verify runtime works
7. Update ADR-026 status to "Superseded by ADR-027"

## Related

- ADR-026 (superseded)
- ADR-020 (migrate-to-buildnpmpackage)
- https://github.com/nix-community/bun2nix
- https://github.com/btriapitsyn/openchamber

______________________________________________________________________

Author: jack
Date: 2026-02-19
PR: N/A
