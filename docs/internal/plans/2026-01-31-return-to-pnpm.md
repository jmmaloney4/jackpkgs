# Plan: Return to pnpm for nodejs module (2026-01-31)

## Goal

Replace npm-based `jackpkgs.nodejs` implementation with pnpm-based nixpkgs tooling,
and update tests/docs accordingly.

Target monorepo compatibility: `cavinsresearch/zeus` style workspace:

- root `pnpm-workspace.yaml`
- shared TypeScript library (e.g. `atlas`) consumed via `workspace:*`
- multiple Pulumi TypeScript stacks (e.g. `deploy/*`)

## Background & Rationale

### Historical Context

| ADR     | Decision                    | Actual Reason                           | Current Validity                                                  |
| ------- | --------------------------- | --------------------------------------- | ----------------------------------------------------------------- |
| ADR-019 | pnpm → npm                  | dream2nix lacks pnpm-lock translator    | **Obsolete** - We ended up using `buildNpmPackage`, not dream2nix |
| ADR-020 | dream2nix → buildNpmPackage | External dep, API instability           | Valid, but nixpkgs has native pnpm support too                    |
| ADR-022 | npm-lockfile-fix workaround | npm v9+ lockfiles incompatible with Nix | **Symptom of the problem** - pnpm doesn't have this issue         |

**Key insight**: The migration to npm was driven by dream2nix limitations that became
irrelevant when we switched to nixpkgs native tooling. nixpkgs has **excellent
native pnpm support** via `fetchPnpmDeps` and `pnpmConfigHook`.

### Why Return to pnpm?

| Benefit                        | Detail                                                                             |
| ------------------------------ | ---------------------------------------------------------------------------------- |
| **Stable lockfile format**     | `pnpm-lock.yaml` has consistent `resolved` + `integrity` fields; no npm v9+ quirks |
| **No normalization needed**    | Eliminates `npm-lockfile-fix` workaround (ADR-022)                                 |
| **Better monorepo ergonomics** | pnpm workspace model designed for strict isolation; matches zeus/yard usage        |
| **Disk efficiency**            | Content-addressable store with hard links (faster, less disk usage)                |
| **Native workspace support**   | `pnpm-workspaces` parameter in `fetchPnpmDeps` filters to specific packages        |
| **Zeus compatibility**         | Aligns with existing pnpm-based monorepos; consumer already familiar with pnpm     |

### User Confirmation

User confirmed:

- Pulumi + pnpm had no real compatibility issues (ADR-019 claim was incorrect)
- Primary motivation: avoid npm-lockfile-fix, disk/performance benefits, strict isolation, better monorepo UX
- Experiencing active npm workspace build failures even with ADR-022 fix

______________________________________________________________________

## Design Summary

| Aspect              | Current (npm)                                      | Proposed (pnpm)                           |
| ------------------- | -------------------------------------------------- | ----------------------------------------- |
| Package manager     | npm                                                | pnpm                                      |
| Lockfile            | `package-lock.json`                                | `pnpm-lock.yaml`                          |
| Workspace config    | `package.json` workspaces field                    | `pnpm-workspace.yaml`                     |
| Nix tooling         | `buildNpmPackage` + `importNpmLock`                | `fetchPnpmDeps` + `pnpmConfigHook`        |
| Lockfile validation | `npm-lockfile-fix` workaround                      | Not needed                                |
| Hash computation    | Implicit via importNpmLock (from integrity hashes) | Explicit `pnpmDepsHash` option            |
| Workspace filter    | `npmWorkspace` param (single workspace)            | `pnpmWorkspaces` param (list of packages) |
| Build command       | `npm run build`                                    | `pnpm --filter=<name> build`              |
| fetcherVersion      | N/A                                                | 3 (reproducible tarball)                  |

______________________________________________________________________

## Implementation Steps

### Phase 1: Add YAML parsing helper (IFD)

**File:** `modules/flake-parts/lib.nix`

**Add:**

```nix
jackpkgsLib = {
  # ... existing helpers ...

  # YAML parsing via IFD (requires yq-go at eval time)
  # Note: YAML file must be in source tree for builtins.pathExists to work
  fromYAML = pkgs: yamlPath:
    let
      # Use yq-go for YAML -> JSON conversion in a derivation
      # yq -o=json outputs directly to stdout
      jsonFile = pkgs.runCommand "yaml-to-json" {
            nativeBuildInputs = [ pkgs.yq-go ];
          } ''
            yq -o=json < ${yamlPath} > $out
          '';
      # Import JSON from the derivation's output
      # Since jsonFile is a derivation, we use builtins.readFile on its path
    in
      lib.importJSON jsonFile;

  # Keep nodejs helpers (findNodeModulesBin, findNodeModulesRoot) - these work for both
  # npm and pnpm output structures

  nodejs = {
    # Shell script snippet to find node_modules/.bin
    # pathVar: name of shell variable to export/set
    # storePath: nix store path to search in
    findNodeModulesBin = pathVar: storePath: ''
      if [ -d "${storePath}/node_modules/.bin" ]; then
        ${pathVar}="${storePath}/node_modules/.bin"
      elif [ -d "${storePath}/lib/node_modules/.bin" ]; then
        ${pathVar}="${storePath}/lib/node_modules/.bin"
      elif [ -d "${storePath}/lib/node_modules/default/node_modules/.bin" ]; then
        ${pathVar}="${storePath}/lib/node_modules/default/node_modules/.bin"
      fi
    '';

    # Shell script snippet to find root of node_modules
    # rootVar: name of shell variable to set to the root
    # storePath: nix store path to search in
    findNodeModulesRoot = rootVar: storePath: ''
      if [ -d "${storePath}/node_modules" ]; then
        ${rootVar}="${storePath}/node_modules"
      elif [ -d "${storePath}/lib/node_modules/default/node_modules" ]; then
        ${rootVar}="${storePath}/lib/node_modules/default/node_modules"
      elif [ -d "${storePath}/lib/node_modules" ]; then
        ${rootVar}="${storePath}/lib/node_modules"
      fi
    '';
  };
};
```

**Remove:**

```nix
lockfileIsCacheable = lockfile: let
  lockfileVersion = lockfile.lockfileVersion or 1;
  isV3 = lockfileVersion == 3;
  packages = lockfile.packages or {};
  isWorkspaceLink = pkg: (pkg.link or false) == true;
  isCacheable = name: pkg:
    name == "" || isWorkspaceLink pkg || ((pkg ? resolved) && (pkg ? integrity));
  uncacheablePackages =
    if isV3
    then lib.filterAttrs (name: pkg: !isCacheable name pkg) packages
    else {};
  uncacheableNames = lib.attrNames uncacheablePackages;
in {
  valid = (!isV3) || (uncacheableNames == []);
  uncacheablePackages = uncacheableNames;
  skipped = !isV3;
};
```

______________________________________________________________________

### Phase 2: Rewrite nodejs module for pnpm

**File:** `modules/flake-parts/nodejs.nix`

**New options:**

```nix
jackpkgs.nodejs = {
  enable = mkEnableOption "jackpkgs-nodejs (opinionated Node.js envs via pnpm)";

  version = mkOption {
    type = types.enum [18 20 22];
    default = 22;
    description = "Node.js major version to use.";
  };

  pnpmVersion = mkOption {
    type = types.enum [8 9 10];
    default = 10;
    description = ''
      pnpm major version. Should match lockfile version and consumer's
      pinned pnpm version. Recommended: pnpm_10.
    '';
  };

  projectRoot = mkOption {
    type = types.path;
    default = config.jackpkgs.projectRoot or inputs.self.outPath;
    defaultText = "config.jackpkgs.projectRoot or inputs.self.outPath";
    description = ''
      Root of Node.js project (containing pnpm-lock.yaml and
      pnpm-workspace.yaml).
    '';
  };

  pnpmDepsHash = mkOption {
    type = types.str;
    description = ''
      Hash for fetchPnpmDeps. To compute:
        1. Set to "" (empty string) initially
        2. Run: nix build .#pnpmDeps
        3. Copy -> "got: sha256-..." hash from the error message

      Example:
        jackpkgs.nodejs.pnpmDepsHash = "";
        # After first build, error shows: "got: sha256-abc123..."
        jackpkgs.nodejs.pnpmDepsHash = "sha256-abc123...";
    '';
    example = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  # Optional: filter to specific workspaces
  # If null, installs dependencies for ALL workspaces
  workspaces = mkOption {
    type = types.nullOr (types.listOf types.str);
    default = null;
    description = ''
      Workspace package names to pass to pnpm's --filter flag.
      If null, all workspaces are installed (pnpm default).
      Use this to optimize builds for large monorepos.

      Example: workspaces = ["@test/infra-dev", "@test/lib-common"];
    '';
  };
};
```

**Implementation (pnpm-based):**

```nix
config = mkIf cfg.enable {
  perSystem = {
    pkgs,
    lib,
    config,
    system,
    ...
  }: let
    # Select Node.js package based on version option
    nodejsPackage =
      if cfg.version == 18
      then pkgs.nodejs_18
      else if cfg.version == 20
      then pkgs.nodejs_20
      else pkgs.nodejs_22; # Default to 22

    # Select pnpm package (pinned version)
    pnpmPackage = pkgs."pnpm_${toString cfg.pnpmVersion}";

    # Determine workspaces filter for fetchPnpmDeps
    # If cfg.workspaces is null, let pnpm install all workspaces
    # If specified, filter to only those packages
    pnpmDeps = pkgs.fetchPnpmDeps ({
      pname = "pnpm-deps";
      version = "1.0.0";
      src = cfg.projectRoot;
      pnpm = pnpmPackage;
      fetcherVersion = 3;  # Version 3: reproducible tarball
      hash = cfg.pnpmDepsHash;
    } // lib.optionalAttrs (cfg.workspaces != null) {
      # Only install dependencies for specific workspaces
      pnpmWorkspaces = cfg.workspaces;
    });

    # Build node_modules derivation using stdenv + pnpmConfigHook
    # pnpmConfigHook is a setup hook that:
    # 1. Copies pnpmDeps store to cache
    # 2. Runs pnpm install --frozen-lockfile
    # 3. Produces node_modules with workspace symlinks
    nodeModules = pkgs.stdenv.mkDerivation {
      name = "node-modules";
      src = cfg.projectRoot;

      nativeBuildInputs = [
        nodejsPackage
        pnpmPackage
        pkgs.pnpmConfigHook
      ];

      inherit pnpmDeps;

      # Build phase is handled by pnpmConfigHook
      # We just need to copy node_modules to output
      dontBuild = true;

      installPhase = ''
        # Copy the entire node_modules directory to $out
        # This preserves symlinks and workspace structure
        cp -a node_modules $out
      '';
    };
  in {
    # Expose node_modules for consumption by checks module
    # Output structure: <store>/node_modules/ (flat, same as before)
    jackpkgs.outputs.nodeModules = nodeModules;

    # Expose pnpmDeps for easy hash computation
    # Allows consumer to run: nix build .#pnpmDeps
    packages.pnpmDeps = pnpmDeps;

    # Create devshell fragment
    jackpkgs.outputs.nodejsDevShell = pkgs.mkShell {
      packages = [
        nodejsPackage
        pnpmPackage
      ];

      # NOTE: We check for .bin paths at runtime (shellHook execution time), not at
      # Nix evaluation time, because the derivation doesn't exist yet.
      # builtins.pathExists would always return false for unbuilt store paths.
      shellHook = ''
        node_modules_bin=""

        ${lib.optionalString (nodeModules != null) ''
          # Use Nix-built binaries from node_modules derivation (pure, preferred)
          # findNodeModulesBin handles both buildNpmPackage and pnpm structures
          ${jackpkgsLib.nodejs.findNodeModulesBin "node_modules_bin" nodeModules}
        ''

        if [ -n "$node_modules_bin" ]; then
          export PATH="$node_modules_bin:$PATH"
        else
          # Fallback: Add local node_modules/.bin for impure builds (pnpm install)
          # This allows devshell to work even without Nix-built node_modules
          export PATH="$PWD/node_modules/.bin:$PATH"
        fi
      '';
    };

    # Auto-configure main devshell
    jackpkgs.shell.inputsFrom =
      lib.optional (config.jackpkgs.outputs.nodejsDevShell != null)
        config.jackpkgs.outputs.nodejsDevShell;
  };
};
```

______________________________________________________________________

### Phase 3: Update checks to discover pnpm workspaces

**File:** `modules/flake-parts/checks.nix`

**Replace npm workspace discovery with pnpm discovery:**

```nix
# Remove or replace discoverNpmPackages with discoverPnpmPackages
discoverPnpmPackages = workspaceRoot: let
  yamlPath = workspaceRoot + "/pnpm-workspace.yaml";
  yamlExists = builtins.pathExists yamlPath;

  # Use IFD to parse YAML
  # fromYAML returns parsed JSON: { packages: ["libs/*", "deploy/*"]; }
  workspaceConfig =
    if yamlExists
    then jackpkgsLib.fromYAML pkgs yamlPath
    else {};

  # pnpm-workspace.yaml has format: { packages: ["libs/*", "deploy/*"]; }
  packageGlobs = workspaceConfig.packages or [];

  # Expand globs using existing helper (reuse expandWorkspaceGlob)
  # This handles both wildcards ("deploy/*") and plain names
  allPackages = lib.flatten (map (expandWorkspaceGlob workspaceRoot) packageGlobs);

  # Filter for directories that contain package.json
  hasPackageJson = pkg:
    builtins.pathExists (workspaceRoot + "/${pkg}/package.json");

  # Return only packages with package.json
in
  if yamlExists
  then lib.filter hasPackageJson allPackages
  else [];  # No pnpm-workspace.yaml, no auto-discovery
```

**Update TypeScript package discovery:**

```nix
# In the typescriptChecks section, update tsPackages
tsPackages =
  if cfg.typescript.tsc.packages != null
  then map validateWorkspacePath cfg.typescript.tsc.packages
  else discoverPnpmPackages projectRoot;  # Changed from discoverNpmPackages
```

**Update Vitest package discovery:**

```nix
# In the vitestChecks section, update vitestPackages
vitestPackages =
  if cfg.vitest.packages != null
  then map validateWorkspacePath cfg.vitest.packages
  else discoverPnpmPackages projectRoot;  # Changed from discoverNpmPackages
```

______________________________________________________________________

### Phase 4: Remove npm lockfile cacheability logic

**File:** `modules/flake-parts/lib.nix`

**Remove entirely:**

```nix
# Delete the lockfileIsCacheable function and its documentation
# It was specific to npm lockfile validation which is no longer needed
```

______________________________________________________________________

### Phase 5: Remove npm-specific hooks/recipes

**File:** `modules/flake-parts/pre-commit.nix`

**Check for and remove:**

```nix
# Search for npm-lockfile-fix hook reference and remove
# This should only be present if it was added for ADR-022
# Remove any lines like:
#   jackpkgs.pre-commit.hooks.npm-lockfile-fix = { ... };
```

**File:** `modules/flake-parts/just.nix`

**Check for and remove:**

```nix
# Search for fix-npm-lock recipe and remove
# Remove any lines like:
#   npmLockfileFixPackage = ...
#   jackpkgs.just.npmLockfileFixPackage = ...
```

______________________________________________________________________

### Phase 6: Update tests

**Files to delete:**

| File/Directory                           | Reason                                                          |
| ---------------------------------------- | --------------------------------------------------------------- |
| `tests/lockfile-cacheability.nix`        | Tests npm lockfile validation (no longer needed)                |
| `tests/lockfile-nixpkgs-integration.nix` | Tests importNpmLock behavior (npm-specific)                     |
| `tests/fixtures/checks/npm-lockfile/`    | npm lockfile fixtures (workspace-broken, workspace-fixed, etc.) |
| `tests/fixtures/checks/npm-workspace/`   | npm workspace fixtures (if exists)                              |
| `tests/fixtures/integration/simple-npm/` | Simple npm test fixture                                         |

**Run:**

```bash
rm -rf tests/lockfile-cacheability.nix
rm -rf tests/lockfile-nixpkgs-integration.nix
rm -rf tests/fixtures/checks/npm-lockfile
rm -rf tests/fixtures/checks/npm-workspace
rm -rf tests/fixtures/integration/simple-npm
```

**New test fixture: Convert pulumi-monorepo to pnpm**

**File:** `tests/fixtures/integration/pulumi-monorepo/pnpm-workspace.yaml`

```yaml
packages:
  - 'packages/*'
```

**File:** `tests/fixtures/integration/pulumi-monorepo/package.json`

```json
{
  "name": "pulumi-monorepo-test",
  "version": "1.0.0",
  "private": true,
  "engines": {
    "node": ">=22"
  },
  "workspaces": [
    "packages/*"
  ],
  "scripts": {
    "build": "tsc --build",
    "test": "vitest run",
    "typecheck": "tsc --noEmit"
  },
  "devDependencies": {
    "@types/node": "^20.11.0",
    "typescript": "^5.4.0",
    "vitest": "^1.6.0"
  }
}
```

**Update `packages/*/package.json` files to use `workspace:*`:**

**File:** `tests/fixtures/integration/pulumi-monorepo/packages/infra-dev/package.json`

```json
{
  "name": "@test/infra-dev",
  "version": "1.0.0",
  "main": "index.ts",
  "scripts": {
    "build": "tsc"
  },
  "dependencies": {
    "@pulumi/gcp": "^7.0.0",
    "@pulumi/pulumi": "^3.100.0",
    "@test/lib-common": "workspace:*",
    "@test/lib-pulumi": "workspace:*"
  },
  "devDependencies": {
    "@types/node": "^20.11.0",
    "typescript": "^5.4.0"
  }
}
```

**File:** `tests/fixtures/integration/pulumi-monorepo/packages/lib-common/package.json`

```json
{
  "name": "@test/lib-common",
  "version": "1.0.0",
  "main": "src/index.ts",
  "types": "src/index.ts",
  "scripts": {
    "build": "tsc",
    "test": "vitest run"
  },
  "devDependencies": {
    "typescript": "^5.4.0",
    "vitest": "^1.6.0"
  }
}
```

**File:** `tests/fixtures/integration/pulumi-monorepo/packages/lib-pulumi/package.json`

```json
{
  "name": "@test/lib-pulumi",
  "version": "1.0.0",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "scripts": {
    "build": "tsc",
    "test": "vitest run"
  },
  "dependencies": {
    "@pulumi/pulumi": "^3.100.0",
    "@test/lib-common": "workspace:*"
  },
  "devDependencies": {
    "@types/node": "^20.11.0",
    "typescript": "^5.4.0",
    "vitest": "^1.6.0"
  }
}
```

**Generate lockfile:** (run in fixture directory)

```bash
cd tests/fixtures/integration/pulumi-monorepo
pnpm install
```

**New test file:** `tests/pnpm-workspace-discovery.nix`

```nix
{
  lib,
  inputs,
}: let
  pkgs = import inputs.nixpkgs {system = "x86_64-linux";};
  libModule = import ../modules/flake-parts/lib.nix {jackpkgsInputs = inputs;};
  jackpkgsLib = (libModule {inherit lib; inherit pkgs;})._module.args.jackpkgsLib;

  fixture = ./fixtures/integration/pulumi-monorepo;
in {
  testPnpmWorkspaceYamlParsable = let
    result = jackpkgsLib.fromYAML pkgs (fixture + "/pnpm-workspace.yaml");
  in {
    expr = result ? packages;
    expected = true;
  };

  testPnpmWorkspacePackagesExtracted = let
    result = jackpkgsLib.fromYAML pkgs (fixture + "/pnpm-workspace.yaml");
  in {
    expr = builtins.elem "packages/*" result.packages;
    expected = true;
  };

  # Test that fromYAML handles missing YAML gracefully (returns null/empty)
  testMissingYamlReturnsEmpty = let
    yamlPath = ./fixtures/integration/simple-npm/pnpm-workspace.yaml;  # Doesn't exist
    yamlExists = builtins.pathExists yamlPath;
  in {
    expr = yamlExists;
    expected = false;
  };
}
```

**Update checks tests to use pnpm fixture:** If there are checks tests that reference
`pulumi-monorepo` fixture, they should continue to work with minimal changes
since we're keeping the same package structure (just adding pnpm-workspace.yaml).

______________________________________________________________________

### Phase 7: Documentation

**File:** `docs/internal/designs/023-return-to-pnpm.md`

The ADR has been written separately (see file). Ensure it references this plan.

**File:** `README.md`

**Update examples:**

```nix
# In Quick Start example
{
  jackpkgs.nodejs = {
    enable = true;
    version = 22;
    pnpmVersion = 10;
    projectRoot = ./.;
    pnpmDepsHash = "";  # Initially empty, compute via: nix build .#pnpmDeps
  };

  jackpkgs.checks = {
    typescript = {
      enable = true;
      packages = ["infra", "tools"];  # Optional: null for auto-discovery
    };
  };
}
```

**Add hash computation section:**

````markdown
### Hash Computation

When you first enable `jackpkgs.nodejs`, set `pnpmDepsHash = "";` (empty string).
Then run:

```bash
nix build .#pnpmDeps
````

This will fail with an error showing the expected hash. Copy the `sha256-...`
value into `pnpmDepsHash` and rebuild.

The hash only needs to be recomputed when `pnpm-lock.yaml` changes.

````

**Update troubleshooting section:**
```markdown
### Node.js (pnpm)

#### Hash error on first build
**Problem:** `error: hash mismatch in fixed-output derivation... got: sha256-...`
**Solution:** Copy the shown hash into `jackpkgs.nodejs.pnpmDepsHash`.

#### Workspace discovery fails
**Problem:** `WARNING: Vitest binary not found...`
**Solution:** Ensure `pnpm-workspace.yaml` exists and lists your workspace packages.
````

**Remove npm-specific sections:** Delete any references to `package-lock.json`,
`npm-lockfile-fix`, `importNpmLock`.

______________________________________________________________________

## Hash Workflow (Consumer UX)

### Step-by-Step

```bash
# 1. Enable jackpkgs.nodejs with empty hash
# In flake-module.nix:
{
  jackpkgs.nodejs = {
    enable = true;
    pnpmVersion = 10;
    projectRoot = ./.;
    pnpmDepsHash = "";  # Initially empty
  };
}

# 2. Build to get expected hash
nix build .#pnpmDeps

# Expected error:
# error: hash mismatch in fixed-output derivation ...
# got: sha256-aBc1d2eF3...  <-- COPY THIS
# expected: sha256-aBc1d2eF3...

# 3. Update with the hash
# In flake-module.nix:
{
  jackpkgs.nodejs = {
    # ...
    pnpmDepsHash = "sha256-aBc1d2eF3...";  # PASTE COPIED HASH
  };
}

# 4. Rebuild (now succeeds)
nix build

# 5. Enable devshell
nix develop

# 6. When lockfile changes:
# a. Update dependencies: pnpm install <package>
# b. Run: pnpm install  (updates pnpm-lock.yaml)
# c. Build to get NEW hash: nix build .#pnpmDeps
# d. Copy new hash into pnpmDepsHash
```

______________________________________________________________________

## Zeus Monorepo Compatibility

The zeus repository (`cavinsresearch/zeus`) represents the primary target monorepo
structure for this migration.

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

### Key Patterns in Zeus

| Pattern                   | Zeus Example                                                 | Nix Implementation                            |
| ------------------------- | ------------------------------------------------------------ | --------------------------------------------- |
| **Root workspace config** | `pnpm-workspace.yaml` with `packages: ['atlas', 'deploy/*']` | Parsed via `fromYAML` helper                  |
| **Workspace protocol**    | `"dependencies": { "@cavinsresearch/atlas": "workspace:*" }` | Native to pnpm; `fetchPnpmDeps` handles       |
| **Shared library**        | `atlas/` with `postinstall: pnpm --filter atlas build`       | Runs during `pnpmConfigHook` automatically    |
| **Multiple stacks**       | `deploy/*` each consuming atlas                              | Each typechecks against linked `node_modules` |
| **External registry**     | `@jmmaloney4/toolbox` via `.npmrc`                           | Respected by `fetchPnpmDeps`                  |

### Build Order Dependency

The zeus repository relies on a shared `atlas` library being built **before** any Pulumi
stack that consumes it. This is handled in zeus by a root `postinstall` hook:

```json
{
  "scripts": {
    "postinstall": "pnpm --filter @cavinsresearch/atlas run build"
  }
}
```

**In Nix:** This hook executes automatically during the `pnpmConfigHook` phase
(which runs `pnpm install --frozen-lockfile`), ensuring `atlas/dist/`
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

**For Nix:** The `linkNodeModules` function in checks.nix provides `node_modules` at the
workspace root. TypeScript's `extends` mechanism finds `node_modules/typescript` without
issue; shared `atlas/dist` is found via workspace resolution.

### Implementation Notes

1. **YAML Parsing:** `fromYAML` is called at Nix evaluation time on a YAML file from
   the source tree. The `pnpm-workspace.yaml` must be committed to the repo for
   `builtins.pathExists` to work before calling `fromYAML`.

2. **Workspace Filtering:** The `pnpmWorkspaces` option in `fetchPnpmDeps` allows
   filtering to specific packages. For zeus, we use `null` (install all workspaces),
   then let pnpm's workspace resolution handle `workspace:*` dependencies.

3. **Binary Exposure:** The `node_modules/.bin` directory is linked into the devshell and
   checks via the existing `findNodeModulesBin` helper. This works identically for
   pnpm and npm since both produce this structure.

______________________________________________________________________

## Testing Strategy

### Unit Tests

1. **YAML parsing:** Validate `fromYAML` correctly parses:

   - Simple workspace YAML
   - Workspace with multiple globs
   - Missing YAML file (returns gracefully)

2. **Workspace discovery:** Validate `discoverPnpmPackages` expands globs correctly:

   - `packages/*` → expands to actual directories
   - Multiple globs: `["libs/*", "deploy/*"]`

3. **Option handling:** Test all new options work:

   - `pnpmVersion = 8 | 9 | 10`
   - `pnpmWorkspaces = null | ["@test/lib-common"]`
   - \`pnpmDepsHash = "" | "sha256-..."

### Integration Tests

1. **Simple pnpm project:** Single package with `pnpm-lock.yaml`
2. **Pulumi monorepo:** Multiple packages with shared dependencies (zeus-like)
   - TypeScript checks find shared lib
   - Vitest runs correctly
3. **Workspace filtering:** Verify `pnpmWorkspaces` limits dependencies correctly
4. **Build order:** Confirm shared lib is built before consumers (postinstall hook)

### Manual Testing

1. **Hash workflow:** Test consumer UX for computing `pnpmDepsHash`
2. **Zeus-style monorepo:** Create test repo with:
   - Shared library with build step
   - Multiple Pulumi stacks
   - `workspace:*` dependencies
3. **External registry:** Test with `.npmrc` for GitHub Packages

______________________________________________________________________

## Migration Guide for Consumers

### New Projects

1. **Initialize pnpm workspace:**

```bash
cd /path/to/project
pnpm init  # If not already initialized
```

2. **Create `pnpm-workspace.yaml`:**

```yaml
packages:
  - 'libs/*'
  - 'deploy/*'
```

3. **Install dependencies:**

```bash
pnpm install
# This generates pnpm-lock.yaml
```

4. **Configure jackpkgs:**

```nix
# flake-module.nix
{
  jackpkgs.nodejs = {
    enable = true;
    version = 22;
    pnpmVersion = 10;
    projectRoot = ./.;
    pnpmDepsHash = "";  # Start with empty hash
  };
}
```

5. **Compute hash:**

```bash
nix build .#pnpmDeps
# Copy the "got: sha256-..." hash into pnpmDepsHash
```

6. **Rebuild:**

```bash
nix build
```

### Existing npm Projects

1. **Remove npm artifacts:**

```bash
rm package-lock.json
rm -rf node_modules
```

2. **Create `pnpm-workspace.yaml`:**

```yaml
# Convert package.json workspaces field to pnpm format
packages:
  - 'libs/*'
  - 'deploy/*'
```

3. **Generate pnpm lockfile:**

```bash
pnpm install
# Creates pnpm-lock.yaml, reusing package.json versions
```

4. **Update flake config:**

```nix
# flake-module.nix
{
  jackpkgs.nodejs = {
    enable = true;
    # version, projectRoot as before
    pnpmVersion = 10;
    pnpmDepsHash = "";
  };
}
```

5. **Commit changes:**

```bash
git add pnpm-workspace.yaml pnpm-lock.yaml flake-module.nix
git commit -m "chore: migrate from npm to pnpm"
```

______________________________________________________________________

## Backward Compatibility

**Breaking changes:**

- Requires `pnpm-workspace.yaml` (or explicit workspace lists)
- Requires `pnpmDepsHash` to be set
- Removes npm lockfile support

**Migration path for existing jackpkgs users:**

- Users must update their `jackpkgs.nodejs` configuration
- If using `importNpmLock` custom nodeModules, must switch to `fetchPnpmDeps`

______________________________________________________________________

## Rollback Plan

If issues are discovered with pnpm, we can rollback to npm by reverting:

1. This commit (nodejs.nix rewrite)
2. Restoration of npm-specific code (from git)
3. Updates to README.md

The git history will preserve the npm implementation for easy reference.

______________________________________________________________________

## References

- ADR-023: Return to pnpm from npm
- ADR-020: Migrate from dream2nix to buildNpmPackage
- ADR-019: Migrate from pnpm to npm (package-lock) - Superseded
- ADR-022: Make npm workspace lockfiles cacheable for Nix - Superseded
- nixpkgs JavaScript docs: pnpm (`fetchPnpmDeps`, `pnpmConfigHook`, `pnpmWorkspaces`)
- Zeus repository: `cavinsresearch/zeus`
