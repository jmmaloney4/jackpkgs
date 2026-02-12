# ADR-022: Make npm workspace lockfiles cacheable for Nix

## Status

Proposed

## Context

`jackpkgs.nodejs` uses nixpkgs' `buildNpmPackage` with `importNpmLock`/`prefetch-npm-deps` to build a hermetic `node_modules` derivation.

For monorepos that use **npm workspaces** (e.g. Pulumi repos where `deploy/*` stacks import shared TypeScript libraries in `libs/*` and are run via `pulumi -C deploy/<stack> up`), we need:

- `nix develop` to provide a working Node toolchain and `node_modules` for typecheck/lint/build.
- `nix flake check` to build/typecheck/lint these packages without network.
- Builds to be hermetic (Nix sandbox; no network).

### Failure Mode

npm v9+ may omit `resolved` URLs and `integrity` hashes for some entries in `package-lock.json`, especially in workspace-related paths (commonly under `packages/*/node_modules/*` / other workspace layouts).

nixpkgs' npm caching tooling treats entries without a cacheable `resolved` URL as non-fetchable and excludes them from the prefetched cache. Because `buildNpmPackage` configures npm for offline installs, npm later fails with errors like:

```
ENOTCACHED: request to https://registry.npmjs.org/<pkg> failed: cache mode is 'only-if-cached' but no cached response is available
```

This is not a "consumer misconfiguration" problem; it is a mismatch between:

- The lockfile shapes produced by npm for workspaces, and
- The expectations of nixpkgs' offline cache generation.

## Decision

We will require npm workspace consumers of `jackpkgs.nodejs` to maintain a **cacheable** `package-lock.json` by running a lockfile normalization step outside the Nix build.

Specifically:

- Consumers MUST run `npm-lockfile-fix` on `package-lock.json` whenever it changes.
- Consumers MUST commit the updated `package-lock.json`.
- `jackpkgs` SHOULD make this easy by providing `npm-lockfile-fix` in the Node devshell and as an opt-in pre-commit hook.

Scope:

- This is about producing lockfiles that are compatible with nixpkgs offline npm caching.
- This does not change the runtime behavior of npm workspaces or Pulumi usage (e.g. `pulumi -C deploy/<stack> up`).

Out of scope:

- Allowing network access during Nix builds.
- Replacing npm with pnpm/yarn for this architecture.

## Consequences

### Benefits

- Hermetic builds remain intact (no network required during `nix build`/`nix develop`).
- Workspace monorepos can reliably build and run checks with `buildNpmPackage`.
- Minimal jackpkgs-specific complexity; leverages an existing, focused tool.

### Trade-offs

- Adds a required workflow step for consumers when the lockfile changes.
- `package-lock.json` diffs may be larger / less "pure npm output" because it is normalized.

### Risks & Mitigations

- Risk: Consumers forget to run the fix tool and see confusing offline cache errors.

  - Mitigation: Provide a pre-commit hook and a CI check that fails with a direct message telling users to run `npm-lockfile-fix`.

- Risk: Tool behavior changes or becomes unmaintained.

  - Mitigation: Pin the tool version in nixpkgs/jackpkgs, and keep an escape hatch (documented manual command; option to vendor if needed).

## Alternatives Considered

### Alternative A — Assume consumer lockfiles are always cacheable

We could assume all `package-lock.json` files are already compatible with nixpkgs offline caching and provide no normalization step.

**Rejected because**: npm v9+ workspace lockfiles demonstrably omit `resolved`/`integrity` fields for nested workspace dependencies, causing `ENOTCACHED` errors with `buildNpmPackage`. This is not a theoretical issue—it affects all Pulumi monorepos in the target use cases (zeus, toolbox, yard).

### Alternative B — Patch importNpmLock to fetch missing packages

We could modify nixpkgs' `importNpmLock` to fetch packages that lack `resolved` URLs during the cache generation phase.

**Rejected because**:

- Requires upstream nixpkgs changes (high latency, maintenance burden)
- Violates hermetic build principles (fetches during cache generation = impure)
- Harder to reproduce builds (network state affects cache generation)
- Not composable with other tools in the npm ecosystem

### Alternative C — Use pnpm or yarn instead of npm

We could switch to pnpm or Yarn, which may have different lockfile formats that nixpkgs handles better.

**Rejected because**:

- See ADR-019 and ADR-020: pnpm proved incompatible with Pulumi's CLI assumptions
- npm is the de facto standard for Pulumi projects
- Migration cost too high for existing repos
- Doesn't solve the fundamental problem (lockfile compatibility with nixpkgs caching)

## Implementation

### npm-lockfile-fix Package

The `npm-lockfile-fix` tool (from https://github.com/jeslie0/npm-lockfile-fix v0.1.1) is packaged as a Python application and made available in:

- **nodejs module devshell** (`modules/flake-parts/nodejs.nix`): Automatically included when `jackpkgs.nodejs.enable = true`
- **pre-commit module** (`modules/flake-parts/pre-commit.nix`): Available as `jackpkgs.pre-commit.npmLockfileFixPackage`
- **just module** (`modules/flake-parts/just.nix`): Available as `jackpkgs.just.npmLockfileFixPackage`

The package is built using `python3Packages.buildPythonApplication` with:

- Source: `fetchFromGitHub { owner = "jeslie0"; repo = "npm-lockfile-fix"; rev = "v0.1.1"; }`
- Dependencies: `setuptools` (build), `requests` (runtime)

### Pre-Commit Hook

The `jackpkgs.pre-commit` module provides an automatic pre-commit hook that runs `npm-lockfile-fix` on `package-lock.json` files:

```nix
# Automatically enabled when jackpkgs.nodejs.enable = true
jackpkgs.pre-commit.hooks.npm-lockfile-fix = {
  enable = true;  # Auto-enabled with nodejs module
  files = "package-lock\\.json$";
  pass_filenames = true;
  entry = "${npm-lockfile-fix}/bin/npm-lockfile-fix";
};
```

The hook runs `npm-lockfile-fix` automatically on staged `package-lock.json` files, ensuring all lockfiles are normalized before commit.

### Just Recipe

The `jackpkgs.just` module provides a `fix-npm-lock` recipe (auto-enabled when `jackpkgs.nodejs.enable = true`):

```bash
just fix-npm-lock
```

This recipe:

1. Runs `npm install` to update the lockfile
2. Runs `npm-lockfile-fix ./package-lock.json` to normalize it
3. Displays instructions for reviewing and committing changes

### Workflow

#### Bootstrap (First-Time Fix)

If enabling the nodejs module on a repository with an existing incompatible lockfile, the devshell will fail to build. Bootstrap the fix using the flake app:

```bash
# From repository root (before devshell works)
nix run github:jmmaloney4/jackpkgs#npm-lockfile-fix ./package-lock.json
git add package-lock.json && git commit -m "chore: normalize lockfile for Nix compatibility"

# Now devshell will work
nix develop
```

#### Normal Workflow

For developers using jackpkgs with nodejs module enabled:

1. **Update dependencies**: `npm install <package>` or edit `package.json` and run `npm install`
2. **Fix lockfile**: Happens automatically via pre-commit hook, or run `just fix-npm-lock` manually
3. **Review changes**: `git diff package-lock.json`
4. **Commit**: `git add package-lock.json && git commit`

The pre-commit hook ensures all committed lockfiles are Nix-compatible without manual intervention.

## References

- ADR-019: `docs/internal/designs/019-migrate-from-pnpm-to-npm.md`
- ADR-020: `docs/internal/designs/020-migrate-to-buildnpmpackage.md`
- Tool: `npm-lockfile-fix` v0.1.1 (https://github.com/jeslie0/npm-lockfile-fix)
- nixpkgs `importNpmLock`: https://github.com/NixOS/nixpkgs/blob/master/pkgs/build-support/node/import-npm-lock/

______________________________________________________________________

Author: jackpkgs maintainers
Date: 2026-01-31
PR: (TBD)
