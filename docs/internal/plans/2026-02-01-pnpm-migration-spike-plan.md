# Plan: pnpm migration spike plan (2026-02-01)

## Goal

De-risk the pnpm migration by validating high-risk assumptions before the full
implementation lands.

## Scope

These spikes are targeted, time-boxed experiments. Each has:

- A concrete hypothesis
- A minimal reproducible fixture
- A single success/failure signal
- Recommended remediation if it fails

## Spike 1: pnpmConfigHook script execution

### Hypothesis

`pnpmConfigHook` runs lifecycle scripts (specifically `postinstall`) during the
offline install phase.

### Why it matters

Zeus relies on a root `postinstall` to build the shared library before checks run
(`pnpm --filter @cavinsresearch/atlas run build`). If scripts do not run under the
hook, the migration will fail for zeus-style monorepos without extra build steps.

### Setup

Create a minimal fixture:

```
tests/fixtures/spikes/pnpm-postinstall/
├── package.json
├── pnpm-lock.yaml
└── pnpm-workspace.yaml
```

**package.json:**

```json
{
  "name": "pnpm-postinstall-spike",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "postinstall": "node -e \"require('fs').writeFileSync('postinstall-ran', 'ok')\""
  },
  "devDependencies": {
    "typescript": "^5.4.0"
  }
}
```

**pnpm-workspace.yaml:**

```yaml
packages: []
```

### Execution

- Build a derivation that uses `pnpmConfigHook` against this fixture
- After build, verify whether `postinstall-ran` exists in the build directory

### Success criteria

- `postinstall-ran` is present and contains `ok`

### Failure remediation

- Add an explicit `postinstall` build step in the nodeModules derivation
- Or add an option to enable/disable scripts during the hook
- Document that zeus-like monorepos must provide an explicit build step

______________________________________________________________________

## Spike 2: Zeus-style build order (shared library)

### Hypothesis

pnpm workspace install (via `pnpmConfigHook`) builds the shared library before
consumer packages are typechecked.

### Why it matters

Zeus’s `atlas` must be built to `dist/` before `deploy/*` typechecks can succeed.

### Setup

Create a minimal monorepo fixture:

```
tests/fixtures/spikes/pnpm-shared-lib/
├── package.json
├── pnpm-workspace.yaml
├── pnpm-lock.yaml
├── tsconfig.base.json
├── shared-lib/
│   ├── package.json
│   ├── tsconfig.json
│   └── src/index.ts
└── stack-a/
    ├── package.json
    └── index.ts
```

**Root package.json** includes:

```json
{
  "private": true,
  "scripts": {
    "postinstall": "pnpm --filter @test/shared-lib run build"
  },
  "devDependencies": {
    "typescript": "^5.4.0"
  }
}
```

**shared-lib/package.json** outputs to `dist/`.
**stack-a/package.json** depends on `@test/shared-lib` via `workspace:*` and
imports from `dist`.

### Execution

- Build `nodeModules` derivation using `pnpmConfigHook`
- Run the TypeScript check phase for `stack-a` using linked `node_modules`

### Success criteria

- `shared-lib/dist` exists after `pnpmConfigHook`
- `tsc` in `stack-a` succeeds without manual build steps

### Failure remediation

- Add an explicit buildPhase to nodeModules derivation:
  `pnpm --filter @test/shared-lib run build`
- Or introduce a `jackpkgs.nodejs.postInstallCommands` option to run extra steps

______________________________________________________________________

## Spike 3: Private registry dependency resolution

### Hypothesis

`fetchPnpmDeps` and `pnpmConfigHook` respect `.npmrc` for private registries
(e.g., GitHub Packages) in offline mode.

### Why it matters

Zeus depends on `@jmmaloney4/toolbox` from GitHub Packages. Failing to resolve
private registry packages will block the migration.

### Setup

Create a fixture with `.npmrc` and a private package dependency:

```
tests/fixtures/spikes/pnpm-private-registry/
├── package.json
├── .npmrc
└── pnpm-lock.yaml
```

**.npmrc:**

```
@jmmaloney4:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${NPM_TOKEN}
```

### Execution

- Wire `NPM_TOKEN` through Nix explicitly (e.g. build with `--impure` and set
  `impureEnvVars = [ "NPM_TOKEN" ]` for the derivation running pnpm)
- Run `fetchPnpmDeps` and `pnpmConfigHook`

### Success criteria

- The private package is present in the pnpm store
- No auth failures during fetch

### Failure remediation

- Document required environment variables for builds
- Provide a `pnpmConfigHook` wrapper to inject auth
- Add a `jackpkgs.nodejs.npmrcPath` option to pass custom config

______________________________________________________________________

## Spike 4: Workspace glob edge cases

### Hypothesis

`discoverPnpmPackages` handles glob patterns and excludes correctly:

- `**` recursive patterns
- `!` negation patterns

### Why it matters

Some monorepos use `pnpm-workspace.yaml` with negated paths. A naive glob
expansion could include unwanted packages or miss valid ones.

### Setup

Create a fixture:

```
tests/fixtures/spikes/pnpm-glob-edgecases/
├── pnpm-workspace.yaml
├── packages/a/
├── packages/b/
└── packages/ignored/
```

**pnpm-workspace.yaml:**

```yaml
packages:
  - "packages/**"
  - "!packages/ignored"
```

### Execution

- Run `discoverPnpmPackages` on this fixture

### Success criteria

- Returns `packages/a` and `packages/b`
- Excludes `packages/ignored`

### Failure remediation

- Extend `expandWorkspaceGlob` to support `!` negation and `**`
- Or document unsupported patterns and require explicit package lists

______________________________________________________________________

## Spike 5: Symlink preservation in node_modules copy

### Hypothesis

`cp -R node_modules $out` preserves pnpm symlink structure correctly.

### Why it matters

pnpm uses extensive symlink trees in `node_modules`. If `cp -R` dereferences
links, the output will be bloated or incorrect.

### Setup

Use a fixture with multiple dependencies to ensure a `.pnpm` store and symlinks
exist:

```
tests/fixtures/spikes/pnpm-symlink-copy/
├── package.json
└── pnpm-lock.yaml
```

### Execution

- Build `nodeModules` derivation
- Inspect `$out/node_modules` for symlink structure:
  - `node_modules/.pnpm` exists
  - package entries are symlinks

### Success criteria

- `stat` or `ls -l` shows symlinks preserved

### Failure remediation

- Replace `cp -R` with `cp -a` or `rsync -a`
- Add a unit test to assert symlink presence

______________________________________________________________________

## Deliverables

- A spike summary doc (notes on outcomes)
- Fixes or plan adjustments based on results
- Updated ADR/plan if assumptions change

## Ownership and Timebox

- Each spike should be timeboxed to 30–60 minutes
- Stop early if a spike confirms the hypothesis
- Capture both results and remediation steps
