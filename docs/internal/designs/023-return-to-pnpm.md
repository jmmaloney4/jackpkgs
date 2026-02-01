---
id: ADR-023
title: "Return To Pnpm"
status: proposed
date: 2026-02-18
---

# ADR-023: Return to pnpm from npm

## Status

Accepted

## Context

`jackpkgs.nodejs` previously migrated from pnpm to npm (ADR-019) primarily due to
limitations in dream2nix (legacy API) around pnpm lockfile support.

We later migrated away from dream2nix to nixpkgs tooling (ADR-020), which makes the
original dream2nix-specific constraint largely irrelevant.

After adopting npm workspaces + nixpkgs offline caching, we hit recurring
workspace-lockfile compatibility issues (ADR-022) and added `npm-lockfile-fix` as a
required workflow step. We are also still seeing failures in real monorepos even
with the ADR-022 normalization.

At the same time, nixpkgs has native pnpm support via:

- `fetchPnpmDeps` (fixed-output derivation of pnpm store)
- `pnpmConfigHook` (offline install from the prefetched store)
- explicit workspace filtering via `pnpmWorkspaces`

This is compatible with the monorepo structure used by
`cavinsresearch/zeus`:

- multiple Pulumi TypeScript stacks (e.g. `deploy/*`)
- a shared TypeScript library (e.g. `atlas`) consumed via `workspace:*`
- a root `pnpm-workspace.yaml`

## Decision

Switch `jackpkgs.nodejs` to be pnpm-only:

- Use `fetchPnpmDeps` + `pnpmConfigHook` to build a hermetic `node_modules`.
- Keep the existing `jackpkgs.outputs.nodeModules` API (`$out/node_modules/`).
- Discover TypeScript/Vitest workspace packages from `pnpm-workspace.yaml`.
- Parse `pnpm-workspace.yaml` using the recommended IFD pattern (YAML -> JSON via
  `yq-go` in a derivation, then import JSON during eval).
- Remove `npm-lockfile-fix` and npm-specific lockfile cacheability checks.

## Consequences

### Benefits

- Eliminates npm workspace lockfile normalization (`npm-lockfile-fix`).
- Uses nixpkgs-native pnpm support designed for offline builds.
- Better monorepo ergonomics and strictness (pnpm workspace model).
- Aligns with existing pnpm-based monorepos like `zeus`.

### Trade-offs

- Requires a fixed output hash (`pnpmDepsHash`) for `fetchPnpmDeps`.
- Introduces IFD for `pnpm-workspace.yaml` parsing (acceptable for this use case).

### Migration Notes

- Consumers set `jackpkgs.nodejs.pnpmDepsHash = "";` initially, run
  `nix build .#pnpmDeps`, then copy the expected hash from the failure message.
- Workspace discovery for checks relies on `pnpm-workspace.yaml` `packages` globs.

## Supersedes

- ADR-019: Migrate from pnpm to npm (package-lock)
- ADR-022: Make npm workspace lockfiles cacheable for Nix

## References

- ADR-020: Migrate from dream2nix to buildNpmPackage
- nixpkgs JavaScript docs: pnpm (`fetchPnpmDeps`, `pnpmConfigHook`, `pnpmWorkspaces`)

---

Author: jackpkgs maintainers
Date: 2026-01-31
