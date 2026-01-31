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

- Pros: No extra tooling.
- Cons: Breaks for real-world npm workspace lockfiles; failures occur deep in `npm ci` with `ENOTCACHED`.
- Why not chosen: Does not satisfy the requirement that `nix develop`/`nix flake check` work for monorepos.

### Alternative B — Disable offline installs in `buildNpmPackage`

- Pros: Would let npm fetch missing packages.
- Cons: Requires network during builds; violates Nix hermeticity and breaks in sandboxed CI.
- Why not chosen: Conflicts with the core purpose of this architecture.

### Alternative C — Patch nixpkgs to support omitted `resolved`/`integrity`

- Pros: Best long-term fix; no consumer workflow changes.
- Cons: Non-trivial (would require reconstructing tarball URLs and integrity hashes or implementing a registry metadata fetch step, which itself conflicts with offline cache generation).
- Why not chosen (for now): Higher effort and slower path to unblocking consumers; we can revisit once we have a minimal reproducible upstream issue.

### Alternative D — Use dream2nix/node2nix/different builder

- Pros: May handle workspaces differently.
- Cons: Adds external dependencies and/or generated Nix code; increases maintenance burden; conflicts with ADR-020 direction.
- Why not chosen: `buildNpmPackage` is still the desired base; this ADR addresses the remaining workspace lockfile impedance.

## Implementation Plan

1. Add `npm-lockfile-fix` to the `jackpkgs.nodejs` devshell packages.
2. Add an opt-in `pre-commit` hook (via `jackpkgs.pre-commit`) that runs `npm-lockfile-fix package-lock.json` when the lockfile changes.
3. Add a CI/checks assertion that fails fast when the lockfile is not cacheable, with an actionable message.
4. Document the workflow for monorepos (including Pulumi stacks run via `pulumi -C <dir> up`).
5. (Optional follow-up) Open an upstream nixpkgs issue with a minimal reproduction and reference it here.

## Related

- `docs/internal/designs/019-migrate-from-pnpm-to-npm.md`
- `docs/internal/designs/020-migrate-to-buildnpmpackage.md`
- Tool: `npm-lockfile-fix` (jeslie0/npm-lockfile-fix)

---

Author: jackpkgs maintainers
Date: 2026-01-31
PR: (TBD)
