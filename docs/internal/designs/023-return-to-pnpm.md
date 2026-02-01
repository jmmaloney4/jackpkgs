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

## Appendix A: Zeus Monorepo Compatibility

The zeus repository (`cavinsresearch/zeus`) represents the primary target monorepo structure for
this migration. This appendix documents key compatibility considerations and implementation details.

### Zeus Structure

```
zeus/
├── pnpm-workspace.yaml           # Workspace configuration
├── pnpm-lock.yaml               # Lockfile
├── package.json                  # Root hoisting all shared deps
├── tsconfig.base.json           # Shared TypeScript config
├── atlas/                       # Shared library (e.g. @cavinsresearch/atlas)
├── deploy/                      # Pulumi stacks
│   ├── data-catalog/
│   ├── iam/
│   ├── ib-gateway/
│   ├── infra/
│   ├── klosho/
│   ├── poseidon/
│   └── redis/
└── libs/                       # Additional libraries (not in workspace)
```

### Key Patterns

| Pattern | Zeus Example | Nix Implementation |
|---------|--------------|-------------------|
| **Root workspace config** | `pnpm-workspace.yaml` with `packages: ['atlas', 'deploy/*']` | Parsed via `fromYAML` helper |
| **Workspace protocol** | `"dependencies": { "@cavinsresearch/atlas": "workspace:*" }` | Native to pnpm; `fetchPnpmDeps` handles |
| **Shared library** | `atlas/` with `postinstall: pnpm --filter atlas build` | Runs during `pnpmConfigHook` automatically |
| **Multiple stacks** | `deploy/*` each consuming atlas | Each typechecks against linked `node_modules` |
| **External registry** | `@jmmaloney4/toolbox` via `.npmrc` | Respected by `fetchPnpmDeps` |

### Build Order Dependency

The zeus repository relies on the shared `atlas` library being built **before** any Pulumi
stack that consumes it. This is handled in zeus by a root `postinstall` hook:

```json
{
  "scripts": {
    "postinstall": "pnpm --filter @cavinsresearch/atlas run build"
  }
}
```

**In Nix:** This hook executes automatically during the `pnpmConfigHook` phase, ensuring `atlas/dist/`
exists before TypeScript checks run on consumer packages.

### TypeScript Configuration

Zeus uses a shared base configuration with package-specific extensions:

**tsconfig.base.json (root):**
```json
{
  "compilerOptions": {
    "strict": true,
    "target": "ES2020",
    "module": "CommonJS",
    "declaration": true
  }
}
```

**Deploy project tsconfig.json:**
```json
{
  "extends": "../../tsconfig.base.json",
  "include": ["*.ts"],
  "compilerOptions": {
    "outDir": "bin"
  }
}
```

**For Nix:** The `linkNodeModules` function in checks.nix provides `node_modules` at the workspace root.
TypeScript's `extends` mechanism finds `node_modules/typescript` without issue; the shared
`atlas/dist` is found via workspace resolution.

### Compatibility Checklist

| Requirement | Implementation | Status |
|-------------|----------------|--------|
| Parse `pnpm-workspace.yaml` | `fromYAML` helper using `yq-go` | ✓ Planned |
| Workspace globs expansion | Reuse `expandWorkspaceGlob` | ✓ Existing |
| Shared lib build order | `pnpmConfigHook` runs `postinstall` | ✓ Automatic |
| Multiple stack support | Checks iterate all packages | ✓ Existing |
| `workspace:*` resolution | Native pnpm support | ✓ Native |
| External registry deps | Respects `.npmrc` | ✓ Native |

### Implementation Notes

1. **YAML Parsing:** `fromYAML` is called at Nix evaluation time on a YAML file from
   the source. This means the YAML file itself must be in the source tree (checked in as
   `builtins.pathExists` before calling `fromYAML`).

2. **Workspace Filtering:** `pnpmWorkspaces` option in `fetchPnpmDeps` allows filtering to specific
   packages. For zeus, we use `null` to install all workspaces, then let pnpm's workspace
   resolution handle dependencies.

3. **Binary Exposure:** The `node_modules/.bin` directory is linked into the devshell and checks via
   the existing `findNodeModulesBin` helper. This works identically for pnpm and npm since both
   produce this structure.

---

Author: jackpkgs maintainers
Date: 2026-01-31
