# Plan: Return to pnpm for nodejs module (2026-01-31)

## Goal

Replace npm-based `jackpkgs.nodejs` implementation with pnpm-based nixpkgs tooling,
and update tests/docs accordingly.

Target monorepo compatibility: `cavinsresearch/zeus` style workspace:

- root `pnpm-workspace.yaml`
- shared TypeScript library (e.g. `atlas`) consumed via `workspace:*`
- multiple Pulumi TypeScript stacks (e.g. `deploy/*`)

## Design Summary

- Package manager: pnpm-only
- Dependency build: `fetchPnpmDeps` (FOD) + `pnpmConfigHook`
- Output contract: keep `jackpkgs.outputs.nodeModules` with flat layout
  `nodeModules/$out/node_modules/` (same contract expected by checks/devshell)
- Workspace discovery for checks: parse `pnpm-workspace.yaml` using IFD (YAML -> JSON
  via `yq-go`, then import JSON during eval)

## Implementation Steps

### 1) Add YAML parsing helper (IFD)

- Update `modules/flake-parts/lib.nix`
- Add `jackpkgsLib.fromYAML pkgs path` helper using `pkgs.yq-go` to convert YAML ->
  JSON in a derivation and `lib.importJSON` to read it.

### 2) Rewrite nodejs module for pnpm

- Update `modules/flake-parts/nodejs.nix`
- Remove npm-specific implementation:
  - `buildNpmPackage`
  - `importNpmLock`
  - `npm-lockfile-fix` package exposure
- Add pnpm-based implementation:
  - options: `pnpmVersion`, `pnpmDepsHash`, optional `workspaces` filter
  - build `pnpmDeps` via `pkgs.fetchPnpmDeps { fetcherVersion = 3; }`
  - build `nodeModules` via `pkgs.stdenv.mkDerivation` with
    `nativeBuildInputs = [ nodejs pnpm pnpmConfigHook ]`
  - `installPhase = ''cp -R node_modules $out''`
- Expose `packages.pnpmDeps = pnpmDeps` for hash computation.

### 3) Update checks to discover pnpm workspaces

- Update `modules/flake-parts/checks.nix`
- Replace npm workspace discovery (package.json `workspaces`) with pnpm discovery
  from `pnpm-workspace.yaml`:
  - parse YAML via `jackpkgsLib.fromYAML pkgs (projectRoot + "/pnpm-workspace.yaml")`
  - read `packages` globs
  - expand using existing `expandWorkspaceGlob`
  - filter to directories that contain `package.json`

### 4) Remove npm lockfile cacheability logic

- Update `modules/flake-parts/lib.nix`: remove `lockfileIsCacheable`.

### 5) Remove npm-specific hooks/recipes

- Update `modules/flake-parts/pre-commit.nix` to remove `npm-lockfile-fix` hook
  wiring (if present).
- Update `modules/flake-parts/just.nix` to remove any `fix-npm-lock` recipe (if
  present).

### 6) Update tests

Remove nix-unit tests for npm:

- Delete `tests/lockfile-cacheability.nix`
- Delete `tests/lockfile-nixpkgs-integration.nix`
- Delete `tests/fixtures/checks/npm-lockfile/` and other npm-only fixtures as
  applicable.

Add pnpm tests that mirror the Pulumi monorepo pattern:

- Convert or replace `tests/fixtures/integration/pulumi-monorepo/` to pnpm:
  - add `pnpm-workspace.yaml` (e.g. `packages: ['packages/*']`)
  - add `pnpm-lock.yaml`
  - update workspace deps to `workspace:*`
- Add a new nix-unit test that validates:
  - `pnpm-workspace.yaml` parsing via `fromYAML`
  - workspace member discovery returns expected packages
  - (optional) `fetchPnpmDeps` derivation evaluates for fixture

### 7) Documentation

- Add `docs/internal/designs/023-return-to-pnpm.md` (this ADR)
- Update `README.md` to reflect pnpm-only usage and the `pnpmDepsHash` workflow.

## Hash Workflow (Consumer UX)

Recommended pattern:

1. Set `jackpkgs.nodejs.pnpmDepsHash = "";`
2. Run `nix build .#pnpmDeps`
3. Copy the expected hash from the failure message into `pnpmDepsHash`

## Zeus Compatibility Notes

- Shared library build ordering: zeus builds `atlas` in root `postinstall`. This
  should run during pnpm install phases under `pnpmConfigHook`.
- Workspace dependency protocol: `workspace:*` is natively supported by pnpm.
- Multiple Pulumi stacks: checks run `tsc` per workspace member and rely on a
  correctly linked `node_modules` at workspace root.
