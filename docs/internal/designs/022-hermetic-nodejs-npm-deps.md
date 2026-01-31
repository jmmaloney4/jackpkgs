# ADR-022: Make `jackpkgs.nodejs` npm dependency builds hermetic (and fail fast)

## Status

Proposed

## Context

`jackpkgs.nodejs` provides a `nodeModules` derivation intended to work in a pure Nix sandbox (no network) so that:

- `nix develop`, `direnv reload`, and `nix flake check` are reliable and reproducible
- TypeScript/Vitest checks can run using Nix-built `node_modules`

Today, consumers can hit build failures like:

- `npm error code ENOTCACHED`
- `request to https://registry.npmjs.org/<pkg> failed: cache mode is 'only-if-cached' but no cached response is available`

This indicates npm is running in offline/cache-only mode, but the prefetched dependency cache is incomplete. The resulting error is late (during `npm ci`) and is not actionable without deep knowledge of `importNpmLock`/npm caching behavior.

### Constraints

- Must work in a pure Nix sandbox (no network access during the build that runs `npm ci`)
- Must support npm workspaces (hoisting to the root `node_modules`)
- Must keep the `jackpkgs.outputs.nodeModules` API stable (used by the checks module)
- Must keep the `node_modules/.bin` UX for devshells and checks
- Must not require external inputs (e.g. dream2nix) for standard npm usage

## Decision

We will standardize `jackpkgs.nodejs` on a hermetic dependency build pipeline and make failures actionable by validating assumptions up front.

1. **Hermetic dependency source of truth**
   - `nodeModules` MUST be built with `pkgs.buildNpmPackage` using `npmDeps = pkgs.importNpmLock { ... }`.
   - The derivation MUST run npm in offline/cache-only mode (via the nixpkgs npm config hook) so that the build is hermetic.

2. **Stable output shape for consumers**
   - `nodeModules` MUST continue to expose a flat `$out/node_modules` (via a custom `installPhase`) to preserve the checks/devshell integration and avoid nested-path handling.

3. **Fail fast with clear diagnostics**
   - We will add a preflight check that detects common causes of `ENOTCACHED` (e.g., dependencies not representable by `importNpmLock`, missing `resolved`/`integrity`, unsupported specifiers like `git+...`, `file:...`, or private registry URLs without fetch configuration).
   - When preflight fails, we MUST emit an error explaining:
     - which dependency entries are problematic
     - what the consumer should change (e.g., regenerate lockfile, replace git deps, configure fetch options)

4. **Escape hatch for non-registry dependencies**
   - We will add an option to pass through `importNpmLock.fetcherOpts` (and/or equivalent configuration) so that consumers can support private registries in a hermetic way.
   - We will document that certain dependency forms may still be unsupported hermetically and may require refactoring.

### In scope

- Improve `jackpkgs.nodejs` documentation to explicitly state hermetic assumptions and supported dependency forms
- Add preflight validation and better error messages for the npm dependency cache path
- Add a configuration surface for private registries via `importNpmLock` fetch options

### Out of scope

- Supporting pnpm/yarn (npm-only per ADR-019)
- Per-workspace-member `node_modules` derivations (a single derivation remains preferred per ADR-020)
- Allowing network access during `npm ci` in the sandbox

## Consequences

### Benefits

- `nix develop` / `direnv` failures become actionable (fail fast, clear remediation)
- Reproducible and hermetic Node dependency builds by default
- Keeps `checks.nix` and devshell behavior stable (`$out/node_modules` + `.bin` on PATH)

### Trade-offs

- Some dependency forms (git/file/path/implicit registries) may be disallowed or may require extra config
- Adds a small amount of validation logic/maintenance to keep the diagnostics accurate

### Risks & Mitigations

- **Risk:** false positives in the validation block valid projects  
  **Mitigation:** keep the validation narrowly scoped to known hermetic-breakers; provide override knobs where it is safe.
- **Risk:** private registry support becomes a footgun (secrets, auth headers)  
  **Mitigation:** document secure patterns; avoid encouraging embedding tokens in the Nix store.

## Alternatives Considered

### Alternative A — Allow network during `npm ci`
- Pros: “just works” for any dependency type
- Cons: breaks hermeticity; unreliable; not acceptable for `nix flake check`/CI parity
- Why not chosen: violates the core constraint (pure sandbox)

### Alternative B — Reintroduce dream2nix for node_modules
- Pros: prior art; different fetch pipeline
- Cons: external dependency; API instability; more complexity
- Why not chosen: ADR-020 decision stands; nixpkgs-native approach is preferred

### Alternative C — Use node2nix/napalm
- Pros: potentially more granular caching/representation
- Cons: more moving parts; higher maintenance; different workflow expectations
- Why not chosen: unnecessary complexity for the jackpkgs primary “devshell + checks” use case

## Implementation Plan

1. Update `modules/flake-parts/nodejs.nix`:
   - Add explicit docs for the supported dependency forms and hermetic constraints
   - Add preflight validation + targeted error messages for `ENOTCACHED`-class failures
   - Add options for private registry fetch configuration (via `importNpmLock`)

2. Update relevant documentation:
   - Document constraints and troubleshooting in `README.md` (flake-only)
   - Cross-link from ADR-020 to this ADR as operational hardening

3. Add tests:
   - Minimal fixture lockfile that succeeds hermetically
   - Fixture(s) that trigger validation (git dep, file dep, missing resolved/integrity) and assert helpful errors

## Related

- ADR-020: Migrate from dream2nix to buildNpmPackage
- ADR-019: Migrate from pnpm to npm
- ADR-016: CI Checks Module

---

Author: <your name>
Date: 2026-01-31
PR: #<number> (when applicable)
