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

______________________________________________________________________

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
└── libs/                       # Real repo directory intentionally excluded from workspace patterns
```

### Key Patterns

| Pattern | Zeus Example | Nix Implementation |
|---------|--------------|-------------------|
| **Root workspace config** | `pnpm-workspace.yaml` with `packages: ['atlas', 'deploy/*']` | Parsed via `fromYAML` helper |
| **Workspace protocol** | `"dependencies": { "@cavinsresearch/atlas": "workspace:*" }` | Native to pnpm; `fetchPnpmDeps` handles |
| **Shared library** | `atlas/` publishes `main: dist/index.js` + `types: dist/index.d.ts` | Built explicitly in checks (do not rely on lifecycle scripts) |
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

**In Nix:** Do not rely on this. nixpkgs' `pnpmConfigHook` performs an offline install with
`--ignore-scripts`, so lifecycle scripts like `postinstall` will not run when constructing
the `node_modules` derivation.

Instead, `jackpkgs.checks.typescript` (and optionally the devshell) must run an explicit
bootstrap build step (for example, `tsc -p atlas/tsconfig.json` or `pnpm --filter @cavinsresearch/atlas run build`)
before typechecking consumer stacks.

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
| Shared lib build order | Explicit pre-typecheck bootstrap build step | ✓ Planned |
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

______________________________________________________________________

## Appendix B: Node/TypeScript/Pulumi Module Resolution Patterns

This appendix summarizes common Node.js module resolution patterns, how TypeScript and Pulumi
interact with them, and what this implies for pnpm-based Nix builds.

### What "module resolution" means

There are three layers that must agree:

- **Node runtime resolution:** how `node` locates and loads modules at execution time.
- **TypeScript resolution:** how `tsc` finds type declarations during typechecking/emit.
- **Package manager layout:** what `node_modules` looks like (real directories vs symlinks).

### Common patterns

1. **Classic CommonJS (`moduleResolution: node`, `module: CommonJS`)**
   - Node uses `require()` semantics.
   - TypeScript uses classic `node_modules` lookup rules.
   - Pulumi works well here because program execution is fundamentally Node-based.

2. **Modern ESM (`type: module`, `exports`, `moduleResolution: node16|nodenext`)**
   - Node uses ESM semantics (`package.json` `type`, file extensions, and `exports`).
   - TypeScript `node16`/`nodenext` makes TS follow Node's ESM rules more closely.
   - Pulumi can support this, but ESM/CJS mixing tends to be where breakage happens.

3. **Workspace libraries published via build artifacts (`main`/`types` -> `dist/*`)**
   - A shared workspace package declares `main: dist/index.js` and `types: dist/index.d.ts`.
   - Dependent packages (like Pulumi stacks) import the package name and expect `dist/*` to exist.
   - This is the zeus pattern: `@cavinsresearch/atlas` is imported by stacks, so `atlas/dist` must
     exist for both typechecking (types) and runtime (JS).

4. **Typechecking against source via `compilerOptions.paths`**
   - Can avoid a build-order dependency for TypeScript typechecking.
   - Node (and Pulumi at runtime) does not honor TS `paths` without extra runtime loaders.
   - This is usually not the best fit for Pulumi stacks unless you commit to a loader/bundler.

5. **TypeScript project references (`tsc -b`)**
   - Declares an explicit build graph and builds in dependency order.
   - Works well when workspace packages must emit `.d.ts` before dependents can typecheck.

### Implications for pnpm + Nix

- pnpm is compatible with Node and TypeScript, but it leans heavily on symlinks.
- In nixpkgs, `pnpmConfigHook` installs dependencies offline with `--ignore-scripts`, so build-order
  dependencies cannot depend on lifecycle scripts like root `postinstall`.

This means `jackpkgs` must treat "build workspace libs" as a first-class, explicit step in:

- `nix flake check` (via `jackpkgs.checks.typescript`), and optionally
- the devshell (for developer ergonomics).

### Current `jackpkgs` behavior

- `jackpkgs.nodejs` builds a store-backed `node_modules` tree (today via `buildNpmPackage` and npm
  lockfiles; this ADR migrates that to pnpm tooling).
- `jackpkgs.checks.typescript` links that store `node_modules` into a writable sandbox and runs
  `tsc --noEmit` for configured packages.
- There is no built-in "bootstrap build" step today.

### Recommendation

For Pulumi TypeScript monorepos like zeus:

- Prefer the "workspace library publishes `dist/*`" pattern for shared libraries.
- Add an explicit bootstrap build step in `jackpkgs.checks.typescript` (for example build `atlas`
  before typechecking `deploy/*`).
- Optionally add a devshell hook which builds `atlas` only when `atlas/dist/index.d.ts` is missing,
  but keep CI correctness in `flake check` (shell hooks do not run during `flake check`).

---

Author: jackpkgs maintainers
Date: 2026-01-31
