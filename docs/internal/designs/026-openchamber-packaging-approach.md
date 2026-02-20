---
id: ADR-026
title: Openchamber Packaging Approach
status: proposed
date: 2026-02-18
---

# ADR-026: OpenChamber Packaging Approach

## Status

**Superseded by ADR-027**

This approach was implemented but failed due to fundamental incompatibility between `cp -rL` (symlink dereferencing) and Bun's module resolution. See ADR-027 for the pivot to `bun2nix`.

## Context

- We want to package [OpenChamber](https://github.com/btriapitsyn/openchamber) CLI (`@openchamber/web`) for Nix
- The project is a Bun monorepo with native dependencies (node-pty, bun-pty)
- nixpkgs has no built-in support for `bun.lockb` (only npm, yarn, pnpm lockfiles)
- Initial attempts using npm registry tarball failed due to missing lockfile

## Decision

Use **GitHub source + fixed-output derivation + bun** for packaging OpenChamber.

The package MUST fetch source from GitHub (includes `bun.lockb`) and use a fixed-output derivation to install dependencies with `bun install --frozen-lockfile`.

## Consequences

### Benefits

- Fully reproducible builds (lockfile + fixed-output hash verification)
- No `--impure` flag required (fixed-output derivations allow network access)
- Faster than npm (bun is significantly faster)
- Stays close to upstream (uses their lockfile directly)

### Trade-offs

- First build requires hash bootstrapping (run with `lib.fakeHash`, replace with real hash)
- Updates require recalculating the output hash
- Bun version should be pinned for additional reproducibility

### Risks & Mitigations

- **Risk**: Bun version changes could affect reproducibility
  - **Mitigation**: Pin specific Bun version in `nativeBuildInputs`
- **Risk**: Native dependencies may fail to compile
  - **Mitigation**: Include necessary build tools in `nativeBuildInputs`

## Alternatives Considered

### Alternative A — npm registry tarball + npm install

- Pros: Simple, standard approach
- Cons: No lockfile in tarball → non-deterministic resolution → builds hang
- Why not chosen: Lack of lockfile makes reproducibility impossible

### Alternative B — buildNpmPackage

- Pros: Well-supported in nixpkgs, fast incremental builds
- Cons: Requires `package-lock.json` which project doesn't have
- Why not chosen: Would require generating lockfile manually, which drifts from upstream

### Alternative C — Convert bun.lockb to package-lock.json

- Pros: Enables use of standard `buildNpmPackage`
- Cons: Binary format conversion is non-trivial, manual process error-prone
- Why not chosen: Adds maintenance burden, not a standard practice

## Implementation Plan

1. Create `pkgs/openchamber/default.nix` with fixed-output derivation for node_modules
2. Build with `lib.fakeHash` to get real hash
3. Replace hash and verify build succeeds
4. Add to flake outputs
5. Update README

## Related

- https://github.com/btriapitsyn/openchamber
- ADR-020 (migrate-to-buildnpmpackage) - similar JS packaging concerns
