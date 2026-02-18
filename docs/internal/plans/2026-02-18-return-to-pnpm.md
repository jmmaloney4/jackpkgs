# Implementation Plan: Return to pnpm (ADR-023)

**Date:** 2026-02-18
**ADR:** 023-return-to-pnpm (Accepted)
**Supersedes:** ADR-019, ADR-022
**Prior plans:** 2026-01-31-return-to-pnpm, 2026-02-01-pnpm-migration-spike-plan

---

## Consumer Monorepo Survey

This plan must satisfy all three consumer monorepos. Their structures were
investigated via GitHub on 2026-02-18.

### cavinsresearch/zeus

- **Workspace type:** pnpm (`pnpm-workspace.yaml`, `pnpm-lock.yaml` v9.0, no
  `package-lock.json`).
- **Packages:** 8 — `atlas` (shared Pulumi component lib) + 7 deploy stacks
  under `deploy/`.
- **Workspace patterns:** explicit paths (`atlas`, `deploy/data-catalog`,
  `deploy/iam`, etc.) — no globs.
- **Inter-workspace deps:** 4 stacks depend on `@cavinsresearch/atlas` via
  `workspace:*`.
- **postinstall:** Root `postinstall` runs
  `pnpm --filter "@cavinsresearch/atlas" run build` to compile the shared lib
  before stacks can type-check.
- **Private registry:** `.npmrc` routes `@jmmaloney4` scope to GitHub Packages
  (`npm.pkg.github.com`).
- **TypeScript:** `tsconfig.base.json` at root; most packages extend it.
  `deploy/iam` uses ESM (`type: module`, `NodeNext`).
- **Tests:** Only `atlas/` has tests (Jest via `ts-jest`). No vitest.
- **Pulumi:** All 8 packages are Pulumi stacks with `runtime: nodejs`,
  `packagemanager: pnpm`.
- **jackpkgs usage:** Imports `jackpkgs.flakeModule` (default). Sets
  `projectRoot`, `gcp.*`, `pulumi.*`, `python.*`. Does **not** explicitly set
  `jackpkgs.nodejs.*`.

### addendalabs/yard

- **Workspace type:** Currently npm (active `package-lock.json`, stale
  `pnpm-lock.yaml` leftover from prior pnpm era). **Must migrate to pnpm.**
- **Packages:** 9 real packages under `deploy/`, though root `workspaces` array
  is stale (lists 2 removed dirs, omits 2 real ones).
- **Inter-workspace deps:** `@addenda/infra` (shared lib) consumed by
  `platform-shared`, `platform-flyte`, `bid-viewer`, `ingest-pipeline`.
- **Private registry:** None (no scoped private packages).
- **TypeScript:** All packages use `type: module`, ESM. Individual
  `tsconfig.json` per package.
- **Tests:** 2 packages have vitest: `deploy/lib/infra`,
  `deploy/platform/flyte`.
- **Pulumi:** All 9 packages are Pulumi TS stacks.
- **jackpkgs usage:** Imports `jackpkgs.flakeModules.default`. Sets `python.*`,
  `gcp.*`, `pulumi.*`, `just.*`, `fmt.*`. Does **not** explicitly set
  `jackpkgs.nodejs.*`.

### jmmaloney4/garden

- **Workspace type:** pnpm (`pnpm-workspace.yaml` with 4 entries including 1
  stale, `pnpm-lock.yaml` v9.0, no `package-lock.json`). Root `package.json`
  also has npm-style `workspaces` (3 entries).
- **Packages:** 3 real — `theoretical-edge` (Quarto blog + CF Workers Pulumi),
  `brain2` (Quarto only, no deps), `admin` (GCP Pulumi).
- **Inter-workspace deps:** None.
- **Private registry:** `.npmrc` routes `@jmmaloney4` scope to GitHub Packages.
- **TypeScript:** `theoretical-edge` and `admin` only. `type: module`.
- **Tests:** None.
- **Pulumi:** 2 stacks (`theoretical-edge`, `admin`).
- **jackpkgs usage:** Imports `jackpkgs.flakeModule`. Sets `pulumi.*`,
  `quarto.*`, `projectRoot`, `python.*`, `fmt.*`. Does **not** explicitly set
  `jackpkgs.nodejs.*`.

### Cross-cutting Requirements Derived from Survey

| Requirement | zeus | yard | garden |
| --- | --- | --- | --- |
| `pnpm-workspace.yaml` parsing | Yes (explicit paths) | Needs migration | Yes (explicit paths) |
| Glob patterns in workspace YAML | No | Likely after migration | No |
| `workspace:*` inter-package deps | Yes (4 stacks → atlas) | Yes (infra lib) | No |
| `postinstall` script execution | Yes (atlas build) | No | No |
| Private npm registry via `.npmrc` | Yes (@jmmaloney4 scope) | No | Yes (@jmmaloney4 scope) |
| TypeScript type-checking (tsc) | Yes (8 packages) | Yes (9 packages) | Yes (2 packages) |
| Vitest | No | Yes (2 packages) | No |
| Jest | Yes (atlas only) | No | No |
| ESM (`type: module`) | Partial (iam only) | All packages | Partial (TE, admin) |
| pnpm-lock.yaml already present | Yes (v9.0) | No (needs generation) | Yes (v9.0) |

---

## Implementation Phases

### Phase 0: Prerequisite — Consumer Repo Preparation

Before jackpkgs changes land, yard must be migrated from npm to pnpm. Zeus and
garden are already pnpm-native.

**yard migration steps (out-of-scope for jackpkgs, but documented here):**

1. Add `pnpm-workspace.yaml` listing all 9 real packages under `deploy/`.
2. Clean up stale `workspaces` entries in root `package.json` (or remove the
   field entirely — pnpm ignores it in favor of `pnpm-workspace.yaml`).
3. Run `pnpm import` to generate `pnpm-lock.yaml` from existing
   `package-lock.json`.
4. Delete `package-lock.json` and stale `pnpm-lock.yaml`.
5. Run `pnpm install` to verify.
6. Update any CI scripts that reference `npm` commands to use `pnpm`.

---

### Phase 1: `modules/flake-parts/lib.nix` — YAML Parsing and Workspace Discovery

**Goal:** Replace npm-centric helpers with pnpm-centric equivalents.

#### 1a. Add `fromYAML` helper

Add a `jackpkgsLib.fromYAML` function that uses Import From Derivation (IFD)
with `yq-go` to convert YAML to JSON at eval time:

```nix
fromYAML = yamlFile: builtins.fromJSON (
  builtins.readFile (
    pkgs.runCommand "yaml-to-json" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
      yq -o=json '.' ${yamlFile} > $out
    ''
  )
);
```

This enables reading `pnpm-workspace.yaml` as a Nix attrset.

#### 1b. Add `discoverPnpmPackages` helper

Replace `discoverNpmPackages` (which reads `package.json.workspaces`) with
`discoverPnpmPackages` that reads `pnpm-workspace.yaml`:

```
jackpkgsLib.nodejs.discoverPnpmPackages :: path -> [string]
```

- Read `pnpm-workspace.yaml` from `projectRoot` using `fromYAML`.
- Parse the `.packages` list.
- Expand glob entries (`dir/*`) to concrete subdirectory names by listing
  directories.
- Support `!`-prefixed negation patterns (filter out matches).
- Validate paths (no `..`, no absolute, no newlines — same guards as current
  `validateWorkspacePath`).
- Filter to entries that contain `package.json`.

**Glob edge cases to handle:**

- `deploy/*` — list subdirs of `deploy/`.
- `packages/**` — currently NOT supported; same limitation as current module.
  Document this. If a consumer needs `**`, they can enumerate explicit paths in
  `pnpm-workspace.yaml` or use the `packages` override option.
- `!deploy/local-redis` — filter out from prior matches.

#### 1c. Remove `lockfileIsCacheable`

This function validates npm `package-lock.json` v3 entries. No equivalent is
needed for pnpm because `fetchPnpmDeps` handles integrity natively.

#### 1d. Simplify `findNodeModulesRoot` / `findNodeModulesBin`

After migration, only one layout exists: `<store>/node_modules`. The dream2nix
compatibility probes (`lib/node_modules/default/node_modules`,
`lib/node_modules`) can be removed. Simplify to:

```nix
findNodeModulesRoot = rootVar: storePath: ''
  ${rootVar}="${storePath}/node_modules"
'';

findNodeModulesBin = pathVar: storePath: ''
  ${pathVar}="${storePath}/node_modules/.bin"
'';
```

**Concrete edits to `modules/flake-parts/lib.nix`:**

| Section | Action |
| --- | --- |
| `lockfileIsCacheable` | Delete entirely |
| `findNodeModulesRoot` | Remove 3-layout probe, hardcode `<store>/node_modules` |
| `findNodeModulesBin` | Remove 3-layout probe, hardcode `<store>/node_modules/.bin` |
| New: `fromYAML` | Add top-level helper (needs `pkgs` access; accept as argument or place in perSystem) |
| New: `discoverPnpmPackages` | Add, consuming `fromYAML` |
| Existing: `discoverNpmPackages` | Delete |
| Existing: `expandWorkspaceGlob` | Keep but adapt for pnpm YAML list semantics |
| Existing: `validateWorkspacePath` | Keep as-is |

---

### Phase 2: `modules/flake-parts/nodejs.nix` — pnpm Deps Build

**Goal:** Replace `buildNpmPackage` + `importNpmLock` with `fetchPnpmDeps` +
`pnpmConfigHook` + `stdenv.mkDerivation`.

#### 2a. Option Changes

| Option | Current | New |
| --- | --- | --- |
| `jackpkgs.nodejs.enable` | `bool` | Keep |
| `jackpkgs.nodejs.version` | `enum "18" "20" "22"` | Keep |
| `jackpkgs.nodejs.projectRoot` | `path` | Keep |
| `jackpkgs.nodejs.pnpmVersion` | — | **Add**: `enum "9" "10"`, default `"10"` |
| `jackpkgs.nodejs.pnpmDepsHash` | — | **Add**: `str`, default `""` (empty → impure build, user must supply) |

Remove all npm-lockfile-fix related outputs. Add new output:

| Output | Description |
| --- | --- |
| `jackpkgs.outputs.nodeModules` | Keep — now built via pnpm |
| `jackpkgs.outputs.npmLockfileFix` | **Remove** |
| `jackpkgs.outputs.pnpmDeps` | **Add** — the FOD from `fetchPnpmDeps` (useful for debugging/caching) |

#### 2b. Build Implementation

Replace the `buildNpmPackage` block with:

```nix
let
  pnpmPackage = pkgs.${"pnpm_" + cfg.pnpmVersion};

  pnpmDeps = pkgs.pnpmDeps.fetchDeps {
    pname = "pnpm-deps";
    version = "1.0.0";
    src = cfg.projectRoot;
    pnpmWorkspace = cfg.projectRoot + "/pnpm-workspace.yaml";
    hash = cfg.pnpmDepsHash;
  };

  nodeModules = pkgs.stdenv.mkDerivation {
    pname = "node-modules";
    version = "1.0.0";
    src = cfg.projectRoot;

    nativeBuildInputs = [
      nodejsPackage
      pnpmPackage
      pkgs.pnpmConfigHook
    ];

    pnpmDeps = pnpmDeps;

    # pnpmConfigHook runs pnpm install --offline in configurePhase.
    # postinstall scripts (e.g., atlas build in zeus) execute automatically.

    installPhase = ''
      cp -R node_modules $out
    '';
  };
in ...
```

> **Note on `installPhase`:** We preserve the flat `<store>/node_modules`
> output layout per ADR-020 appendix rationale. pnpm uses symlinks internally
> inside `node_modules/.pnpm/`, so we must use `cp -R` (not `cp -r`) to
> preserve symlinks, or alternatively use `cp -a`.

**Verification against consumer repos:**

- **zeus:** `postinstall` builds atlas → `pnpmConfigHook` runs lifecycle scripts
  after install, so atlas is compiled before tsc checks run. `workspace:*`
  links are resolved by pnpm natively. `.npmrc` is read by pnpm from
  `projectRoot` (private registry for `@jmmaloney4/toolbox` — but
  `fetchPnpmDeps` runs in a sandbox; private registry auth must be handled
  via `npmrc` option or pre-populated store. **Open question: does
  `fetchPnpmDeps` respect `.npmrc` for GitHub Packages auth in sandboxed
  builds? See Risks section.**)
- **yard (post-migration):** Standard pnpm workspace, no postinstall, no
  private registry. Should work out of the box.
- **garden:** Simple workspace, no postinstall, private registry same as zeus.

#### 2c. Devshell Changes

Update the devshell to include `pnpm` instead of `npm-lockfile-fix`:

```nix
jackpkgs.outputs.nodejsDevShell = pkgs.mkShell {
  packages = [ nodejsPackage pnpmPackage ];
  shellHook = ''
    # Add Nix-built node_modules/.bin to PATH if available
    export PATH="${nodeModules}/node_modules/.bin:$PATH"
  '';
};
```

The simplified `findNodeModulesBin` from Phase 1d means the shellHook is now a
straightforward `export PATH=` instead of a multi-probe conditional.

---

### Phase 3: `modules/flake-parts/checks.nix` — Workspace Discovery and Linking

**Goal:** Switch workspace discovery from `package.json.workspaces` to
`pnpm-workspace.yaml`, and update node_modules linking for pnpm layout.

#### 3a. Replace `discoverNpmPackages` calls with `discoverPnpmPackages`

In the TypeScript and vitest check definitions, the package list auto-discovery
currently calls `discoverNpmPackages projectRoot`. Replace with
`discoverPnpmPackages projectRoot`.

The fallback behavior when `packages` option is explicitly set remains
unchanged — explicit lists bypass discovery entirely.

#### 3b. Simplify `linkNodeModules`

The current `linkNodeModules` function probes 3 store layouts. After Phase 1d,
simplify to:

```bash
# Link root node_modules
ln -sfn ${nodeModules}/node_modules ./node_modules

# Link per-package node_modules if they exist (hoisted packages)
for pkg in $packages; do
  if [ -d "${nodeModules}/node_modules/$pkg/node_modules" ]; then
    ln -sfn "${nodeModules}/node_modules/$pkg/node_modules" "./$pkg/node_modules"
  fi
done
```

**pnpm-specific consideration:** pnpm uses a `.pnpm` virtual store inside
`node_modules/`. The `cp -R` in Phase 2b preserves this structure. After
symlinking, packages resolve deps through the standard pnpm hoisting algorithm.
The `--shamefully-hoist` flag is NOT needed if we link the full
`node_modules/` tree.

#### 3c. Update tsc Check

The tsc check copies the project source and links node_modules. No fundamental
change needed beyond:

- Use the new simplified `linkNodeModules`.
- Ensure `tsc` binary is resolved from linked `node_modules/.bin/tsc` (already
  the case since tsc is a devDependency in consumer repos).

#### 3d. Update vitest Check

Same as tsc — update `linkNodeModules` call, simplify `.bin` PATH resolution.

**Concrete edits to `modules/flake-parts/checks.nix`:**

| Section | Action |
| --- | --- |
| `discoverNpmPackages` (inline) | Replace calls with `discoverPnpmPackages` from lib |
| `linkNodeModules` | Simplify: remove 3-layout detection, use direct path |
| `findNodeModulesBin` usage | Simplify: direct `${nodeModules}/node_modules/.bin` |
| tsc `buildPhase` | Update linkNodeModules call |
| vitest `buildPhase` | Update linkNodeModules call and .bin resolution |
| `expandWorkspaceGlob` (inline) | Remove (moved to lib.nix as part of discoverPnpmPackages) |
| `validateWorkspacePath` (inline) | Remove (moved to lib.nix) |

---

### Phase 4: `modules/flake-parts/just.nix` — Remove npm-lockfile-fix Recipe

**Goal:** Remove the `fix-npm-lock` recipe and related options.

**Concrete edits to `modules/flake-parts/just.nix`:**

| Section | Action |
| --- | --- |
| `jackpkgs.just.npmLockfileFixPackage` option | Delete |
| `just-flake.features.nodejs` block | Delete the `fix-npm-lock` recipe entirely |

The `just-flake.features.nodejs` feature block should be replaced with a
no-op or removed. If there are useful pnpm-related just recipes to add later
(e.g., `pnpm-install`, `pnpm-update`), they can be added in a follow-up, but
are out of scope for this migration.

---

### Phase 5: `modules/flake-parts/pre-commit.nix` — Remove npm-lockfile-fix Hook

**Goal:** Remove the `npm-lockfile-fix` pre-commit hook and related options.

**Concrete edits to `modules/flake-parts/pre-commit.nix`:**

| Section | Action |
| --- | --- |
| `jackpkgs.pre-commit.npmLockfileFixPackage` option | Delete |
| `settings.hooks.npm-lockfile-fix` | Delete entirely |

No replacement hook is needed. pnpm lockfiles do not suffer from the
`resolved`/`integrity` omission bug that npm workspace lockfiles had.

---

### Phase 6: `pkgs/npm-lockfile-fix/` — Delete Package

Delete `pkgs/npm-lockfile-fix/` directory entirely.

Update `flake.nix`:

- Remove `npm-lockfile-fix` from `packages` output.
- Remove any references to it in overlay or package list.

---

### Phase 7: `modules/flake-parts/lib.nix` — Expose `fromYAML` for General Use

The `fromYAML` helper added in Phase 1a may be useful beyond nodejs (e.g.,
other modules parsing YAML configs). Ensure it is exposed cleanly:

```nix
jackpkgsLib.fromYAML = yamlFile: ...;
```

This requires `pkgs` access. Since `lib.nix` defines perSystem options, the
helper should be defined in the perSystem scope where `pkgs` is available,
similar to existing `findNodeModulesRoot`.

---

### Phase 8: Test Fixtures and Test Updates

#### 8a. Convert integration fixtures from npm to pnpm

**`tests/fixtures/integration/simple-npm/`** → rename to
`tests/fixtures/integration/simple-pnpm/`:

- Replace `package-lock.json` with `pnpm-lock.yaml`.
- Add `pnpm-workspace.yaml` (even for single-package, for consistency, or omit
  if single-package).
- Keep `package.json` and `index.js`.

**`tests/fixtures/integration/pulumi-monorepo/`** → convert in-place:

- Replace `package-lock.json` with `pnpm-lock.yaml`.
- Add `pnpm-workspace.yaml` listing `packages/*`.
- Convert any `workspace:*` references if not already present.
- Keep existing `tsconfig.base.json`, `vitest.config.ts`, package structure.

#### 8b. Convert check fixtures from npm to pnpm

**`tests/fixtures/checks/npm-workspace/`** → rename to
`tests/fixtures/checks/pnpm-workspace/`:

- Add `pnpm-workspace.yaml` with `packages: ["packages/*", "tools/*"]`.
- Remove npm `workspaces` from root `package.json` (or leave it — pnpm ignores
  it).
- Ensure each sub-package has `package.json`.

**`tests/fixtures/checks/npm-lockfile/`** → **delete entirely**. The lockfile
cacheability concept is npm-specific and has no pnpm equivalent.

**`tests/fixtures/checks/no-npm/`** → keep (tests the "no workspace" fallback).

#### 8c. Update test files

**`tests/lockfile-cacheability.nix`** → **delete entirely**. The
`lockfileIsCacheable` function is being removed.

**`tests/lockfile-nixpkgs-integration.nix`** → rewrite to test
`fetchPnpmDeps` + `pnpmConfigHook`:

- Test that `simple-pnpm` fixture builds successfully.
- Test that `pulumi-monorepo` fixture builds successfully with workspace deps.
- Test that output contains `node_modules/` at top level.
- Test that `.pnpm/` virtual store exists inside `node_modules/`.

**`tests/checks.nix`** → update:

- `testTypescriptWorkspaceDiscovery`: Change to parse `pnpm-workspace.yaml`
  instead of `package.json.workspaces`. Use `pnpm-workspace` fixture.
- `testVitestScript`: Update to use simplified `.bin` path resolution.
- `testNodeModulesLinking`: Simplify to test single layout only.
- Add `testPnpmWorkspaceGlobExpansion`: Test `dir/*` glob in
  `pnpm-workspace.yaml`.
- Add `testPnpmWorkspaceNegation`: Test `!dir` exclusion pattern.
- Remove all `lockfileIsCacheable`-related test cases.

#### 8d. Update `flake.nix` integration checks

Update the integration check names and implementations:

| Current | New |
| --- | --- |
| `lockfile-simple-npm-builds` | `pnpm-simple-builds` — use `simple-pnpm` fixture |
| `lockfile-pulumi-monorepo-tsc` | `pnpm-pulumi-monorepo-tsc` — use converted fixture |
| `lockfile-pulumi-monorepo-vitest` | `pnpm-pulumi-monorepo-vitest` — use converted fixture |

Remove `lockfileCacheability` and `lockfileNixpkgsIntegration` test suites
from the nix-unit invocation.

---

### Phase 9: `README.md` — Documentation Update

Update the README to reflect pnpm-only workflow:

- Replace any npm references with pnpm.
- Document `jackpkgs.nodejs.pnpmVersion` and `jackpkgs.nodejs.pnpmDepsHash`
  options.
- Add hash workflow documentation:

  ```markdown
  ## Updating pnpm deps hash

  When `pnpm-lock.yaml` changes, update the hash:

  1. Set `jackpkgs.nodejs.pnpmDepsHash = "";`
  2. Run `nix build` — it will fail with the correct hash.
  3. Copy the hash into `jackpkgs.nodejs.pnpmDepsHash`.
  ```

- Document that `pnpm-workspace.yaml` is required for workspace discovery.
- Remove npm-lockfile-fix references.

---

## File Change Summary

| File | Action | Phase |
| --- | --- | --- |
| `modules/flake-parts/lib.nix` | Add `fromYAML`, `discoverPnpmPackages`; remove `lockfileIsCacheable`, `discoverNpmPackages`; simplify `findNodeModulesRoot`/`findNodeModulesBin` | 1 |
| `modules/flake-parts/nodejs.nix` | Replace `buildNpmPackage`/`importNpmLock` with `fetchPnpmDeps`/`pnpmConfigHook`/`stdenv.mkDerivation`; add `pnpmVersion`/`pnpmDepsHash` options; remove `npmLockfileFix` output; update devshell | 2 |
| `modules/flake-parts/checks.nix` | Replace `discoverNpmPackages` with `discoverPnpmPackages`; simplify `linkNodeModules` and `.bin` resolution | 3 |
| `modules/flake-parts/just.nix` | Remove `npmLockfileFixPackage` option and `fix-npm-lock` recipe | 4 |
| `modules/flake-parts/pre-commit.nix` | Remove `npmLockfileFixPackage` option and `npm-lockfile-fix` hook | 5 |
| `pkgs/npm-lockfile-fix/` | Delete directory | 6 |
| `flake.nix` | Remove `npm-lockfile-fix` from packages; update integration check names/implementations; remove lockfile test suites | 6, 8d |
| `tests/fixtures/integration/simple-npm/` | Rename to `simple-pnpm/`, convert lockfile | 8a |
| `tests/fixtures/integration/pulumi-monorepo/` | Convert from npm to pnpm lockfile + workspace YAML | 8a |
| `tests/fixtures/checks/npm-workspace/` | Rename to `pnpm-workspace/`, add `pnpm-workspace.yaml` | 8b |
| `tests/fixtures/checks/npm-lockfile/` | Delete entirely | 8b |
| `tests/lockfile-cacheability.nix` | Delete entirely | 8c |
| `tests/lockfile-nixpkgs-integration.nix` | Rewrite for pnpm fixtures | 8c |
| `tests/checks.nix` | Update workspace discovery, linking, and script tests | 8c |
| `README.md` | Update for pnpm-only workflow | 9 |

---

## Module Integration Dependency Graph (Post-Migration)

```
nodejs.nix
  ├── Produces: jackpkgs.outputs.nodeModules (via fetchPnpmDeps + pnpmConfigHook)
  ├── Produces: jackpkgs.outputs.pnpmDeps (FOD, for caching/debugging)
  ├── Produces: jackpkgs.outputs.nodejsDevShell (nodejs + pnpm in PATH)
  └── Wires into: jackpkgs.shell.inputsFrom

checks.nix
  ├── Consumes: jackpkgs.outputs.nodeModules (for tsc and vitest checks)
  ├── Uses: jackpkgsLib.nodejs.discoverPnpmPackages (workspace auto-discovery)
  ├── Auto-enables: when jackpkgs.nodejs.enable = true
  └── typescript.enable defaults: when jackpkgs.pulumi.enable = true

just.nix
  └── (no nodejs integration after migration)

pre-commit.nix
  └── (no nodejs integration after migration)

pulumi.nix
  ├── Uses: pkgs.nodejs (runtime, independent of jackpkgs.nodejs module)
  └── Does NOT consume jackpkgs.outputs.nodeModules
```

---

## Risks and Open Questions

### R1: Private Registry Authentication in Sandboxed Builds

`fetchPnpmDeps` runs in the Nix sandbox. Zeus and garden use `.npmrc` to route
`@jmmaloney4` scope to `npm.pkg.github.com`, which requires a `GITHUB_TOKEN`.

**Options:**

- (a) Use nixpkgs `fetchPnpmDeps`'s `npmrc` option to inject auth at build
  time (requires the token to be available at eval time — problematic for
  purity).
- (b) Pre-populate the pnpm store with private packages using
  `builtins.fetchurl` with GitHub Packages tarball URLs + auth headers.
- (c) Document that consumers with private registries must vendor or use
  `--impure` for the hash generation step, then the FOD hash pins the result.

**Recommended:** Option (c) for now. The `pnpmDepsHash` FOD approach means the
sandbox only needs network access during the initial hash computation. Once the
hash is known, the derivation is reproducible. Document this clearly.

### R2: postinstall Script Execution Order

Zeus relies on `postinstall` to build the shared `atlas` library. Verify that
`pnpmConfigHook` runs lifecycle scripts in correct dependency order (atlas
before consumers). pnpm's `--frozen-lockfile` + offline install should handle
this, but needs spike validation.

**Mitigation:** Covered by existing spike plan (2026-02-01, Spike 1 and 2).

### R3: pnpm Symlink Structure in `cp -R`

pnpm's `node_modules/.pnpm/` uses symlinks extensively. `cp -R` on macOS
preserves symlinks; on Linux `cp -R` does NOT dereference by default. Verify
that the copied `node_modules/` tree works correctly in both tsc and vitest
checks.

**Mitigation:** Covered by existing spike plan (2026-02-01, Spike 5). If
`cp -R` is insufficient, use `cp -a` (preserves symlinks, permissions, and
timestamps).

### R4: IFD Performance

`fromYAML` uses Import From Derivation (IFD) which adds a build step during
Nix evaluation. This is a one-time cost per eval and the derivation is tiny
(yq-go converting a small YAML file). Acceptable tradeoff.

### R5: Workspace YAML vs package.json Workspaces Mismatch

Garden has both `pnpm-workspace.yaml` and `package.json.workspaces` with
different entries. After migration, `pnpm-workspace.yaml` is authoritative. The
`package.json.workspaces` field is ignored by pnpm and by our module. Document
this.

### R6: jest Support in Zeus

Zeus uses jest (not vitest) for atlas tests. The current checks module only has
a vitest check, not a jest check. This is a pre-existing gap unrelated to the
pnpm migration, but worth noting. The tsc check covers type-correctness; jest
tests would need to be run separately (e.g., via a custom check or just
recipe).

---

## Implementation Order and Dependencies

```
Phase 0 (external) ─── yard pnpm migration
   │
   ▼
Phase 1 ─── lib.nix (fromYAML, discoverPnpmPackages, remove npm helpers)
   │
   ├──▶ Phase 2 ─── nodejs.nix (fetchPnpmDeps build, new options)
   │       │
   │       ├──▶ Phase 3 ─── checks.nix (discovery + linking updates)
   │       │
   │       ├──▶ Phase 4 ─── just.nix (remove npm-lockfile-fix recipe)
   │       │
   │       └──▶ Phase 5 ─── pre-commit.nix (remove npm-lockfile-fix hook)
   │
   └──▶ Phase 6 ─── delete npm-lockfile-fix package
          │
          ▼
       Phase 7 ─── lib.nix polish (fromYAML exposure)
          │
          ▼
       Phase 8 ─── tests and fixtures
          │
          ▼
       Phase 9 ─── README
```

Phases 2–5 can proceed in parallel once Phase 1 is complete.
Phases 4, 5, and 6 can be a single commit (npm-lockfile-fix removal).

---

## Suggested Commit Sequence

1. `feat(lib): add fromYAML and discoverPnpmPackages, remove npm helpers`
2. `feat(nodejs): switch to fetchPnpmDeps + pnpmConfigHook`
3. `feat(checks): switch workspace discovery to pnpm-workspace.yaml`
4. `refactor(just,pre-commit): remove npm-lockfile-fix integration`
5. `chore: delete pkgs/npm-lockfile-fix`
6. `test: convert fixtures and tests from npm to pnpm`
7. `docs(readme): update for pnpm-only workflow`

---

## Validation Checklist

After implementation, verify against each consumer repo:

- [ ] `nix flake check` passes on jackpkgs itself
- [ ] zeus: `nix develop` provides pnpm + nodejs in PATH
- [ ] zeus: `nix build .#nodeModules` succeeds (or equivalent check)
- [ ] zeus: tsc check passes for all 8 packages
- [ ] zeus: atlas postinstall runs during nodeModules build
- [ ] yard (post-migration): `nix develop` provides pnpm + nodejs
- [ ] yard: tsc check passes for all 9 packages
- [ ] yard: vitest check passes for infra + flyte
- [ ] garden: `nix develop` provides pnpm + nodejs
- [ ] garden: tsc check passes for TE + admin
- [ ] Private registry packages resolve for zeus and garden
