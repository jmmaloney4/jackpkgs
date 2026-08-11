# ADR-047: Strip workspace symlinks from the captured `node_modules` tree

## Status

Proposed

## Context

- `jackpkgs.nodejs` captures a pnpm workspace's dependency tree into a Nix
  derivation (`nodeModules`, ADR-028 output contract): root dependencies at
  `$out/node_modules`, package-local trees at `$out/<workspace>/node_modules`.
- pnpm materializes workspace packages as **relative symlinks**:
  - root `node_modules/<name> -> ../<pkg-path>`
  - `.pnpm/node_modules/<name> -> ../../../<pkg-path>` (peer-resolution links)
  - per-package `<pkg>/node_modules/<name> -> ../../<sibling-path>` for
    `workspace:*` dependencies
- The capture copies **only `node_modules` subtrees**, never workspace package
  sources. Inside `$out`, those relative links therefore either dangle or —
  worse — resolve to a *skeleton* directory that exists only because it hosts a
  nested `node_modules` copy (e.g. `$out/deploy/lib` containing nothing but
  `node_modules/`).
- Issue #160 reported the build-time symptom: `noBrokenSymlinks` failed the
  fixup phase on the dangling `.pnpm/node_modules/<name>` links. The mitigation
  that landed was `dontCheckForBrokenSymlinks = true` — Option A from that
  issue. It silenced the check without fixing the links.
- That moved the failure to runtime. In `jmmaloney4/garden`
  (2026-08-10): `mkWorkspaceRuntime`, run against a live checkout by a
  pre-commit/check invocation, linked each package's `node_modules` at the
  captured store tree. Node's ESM resolver then found
  `deploy/www/theoreticaledge.com/node_modules/garden-deploy-lib` — the
  captured link, resolving to a skeleton with no `index.ts` — *before* ever
  walking up to the correct root-level link that `mkWorkspaceSymlinks` creates
  against the live tree. `pulumi up` failed with `ERR_MODULE_NOT_FOUND`, and
  `pnpm install` / `pnpm install --force` silently no-op'd against the
  corrupted state, making recovery non-obvious.
- Key observation: **no consumer depends on the workspace symlinks baked into
  the captured tree.** Both `checks.nix` and `pre-commit.nix` consume the
  capture through `jackpkgsLib.nodejs.mkWorkspaceRuntime`, whose final step
  (`mkWorkspaceSymlinks`) re-links every configured workspace package against
  the live source tree. The captured links are pure liability.
- The capture script is also duplicated: `flake.nix`'s
  `pnpm-nonhoisted-output-layout` fixture check carries a copy of the
  `installPhase` with a "keep in sync" comment (issue #162).

## Decision

- The `nodeModules` capture MUST strip, at build time, every symlink in `$out`
  that does not resolve to a real path inside a `node_modules` subtree of
  `$out`. This removes:

  - dangling workspace links (the #160 `noBrokenSymlinks` trigger),
  - workspace links that resolve to skeleton directories (the garden runtime
    failure),
  - any link escaping `$out` entirely.

  Dependency-store links (`node_modules/<name> -> .pnpm/...`, `.bin` entries,
  per-package links into the root `.pnpm` store) all resolve inside a
  `node_modules` subtree and MUST be preserved.

- The capture script (copy + strip) MUST live in `lib/nodejs-helpers.nix`
  (`nodejs.captureNodeModules`) and be consumed by both
  `modules/flake-parts/nodejs.nix` and the fixture checks in `flake.nix` —
  closing the duplication tracked by #162 for this script.

- With no broken links left in `$out`, `dontCheckForBrokenSymlinks = true`
  MUST be removed so `noBrokenSymlinks` acts as the regression guard: any
  future change that reintroduces a dangling link fails the build again
  instead of surfacing as a runtime mystery in a consumer repo.

- Workspace-package resolution against a captured tree is therefore always
  root-level and always live: Node's resolver misses the (absent)
  package-local entry, walks up, and hits the root `node_modules/<name>` link
  that `mkWorkspaceSymlinks` points at the checkout. This is the same result a
  real `pnpm install` produces, in both the check sandbox (full source copy)
  and a live checkout.

- Hardening (SHOULD): the `nodejs` devshell hook detects a checkout whose
  `node_modules/.pnpm` is a symlink into the store — the state a
  check/pre-commit run of `mkWorkspaceRuntime` leaves behind — and prints the
  recovery command, because `pnpm install` silently no-ops against that state.

Out of scope:

- Changing `mkWorkspaceRuntime`'s intentional clobbering of a live checkout's
  `node_modules` (documented in `linkHelpers`; the runtime state is functional
  after this ADR, and the devshell warning covers the pnpm-recovery gap).
- Making the captured tree self-contained for consumers that have no live
  source tree (e.g. container images); none exist today.

## Consequences

### Benefits

- The captured tree contains no symlink that can dangle or resolve to an
  incomplete directory — the entire bug class from #160 and the garden
  incident is removed at the source.
- `noBrokenSymlinks` is re-enabled, converting regressions back into loud
  jackpkgs build failures.
- Workspace deps always resolve to **live** source through the root links, so
  edits to a shared library are seen immediately by dependents — no stale
  captured copies.
- One capture script, shared by the module and its fixture tests (#162).

### Trade-offs

- Resolution is slightly less strict than pnpm's isolated layout: with only
  root-level workspace links, a package can resolve a sibling workspace
  package it never declared in `dependencies`. jackpkgs already accepted this
  by hoisting workspace links to root in `mkWorkspaceSymlinks`.
- The strip pass adds a `find` walk over `$out` to the capture build (small
  relative to the copy it follows).

### Risks & Mitigations

- Risk: the strip deletes a link some future consumer needed.
  - Mitigation: the rule is conservative — only links that dangle, escape
    `$out`, or resolve outside every `node_modules` subtree are removed; all
    dependency-store links survive. Fixture checks pin the kept/stripped sets.
- Risk: a pnpm layout change introduces a link shape the rule misjudges.
  - Mitigation: `noBrokenSymlinks` (re-enabled) catches dangles at build time;
    the captured-runtime fixture check catches resolution regressions.

## Alternatives Considered

### Alternative A — Materialize workspace sources into `$out`

- Pros: captured tree becomes self-contained; relative links resolve to
  complete packages.
- Cons: tools resolving through the capture see a frozen copy of sibling
  packages until the derivation rebuilds — wrong semantics for a devshell
  session editing a shared library.
- Why not chosen: correctness for the dev loop matters more than
  self-containment nothing currently needs.

### Alternative B — Shadow-dir overlay in `mkWorkspaceRuntime`

- Pros: preserves pnpm's strict per-package resolution exactly; `$out`
  untouched.
- Cons: package-local `node_modules` becomes a materialized directory of
  per-entry links with workspace overrides — significantly more shell, more
  states to test, and the strictness preserved is one jackpkgs already gave up
  at the root level.
- Why not chosen: cost without a consumer that needs it; can complement this
  ADR later if strictness starts mattering.

### Alternative C — `dependenciesMeta.injected` in consumer repos

- Pros: pnpm's own mechanism for copy-instead-of-link workspace deps.
- Cons: per-dependency annotations in every consumer repo; same staleness
  problem as Alternative A.
- Why not chosen: pushes the fix out of jackpkgs into every consumer.

## Implementation Plan

1. Add `nodejs.captureNodeModules` to `lib/nodejs-helpers.nix` (copy
   `node_modules` trees to `$out`, then strip foreign symlinks).
2. `modules/flake-parts/nodejs.nix`: `installPhase` consumes the helper;
   remove `dontCheckForBrokenSymlinks = true`.
3. `flake.nix`: `pnpm-node-modules-output-layout` and
   `pnpm-nonhoisted-output-layout` consume the helper and assert the new
   invariants (workspace links stripped, dependency links kept, zero dangling
   links); drop their `dontCheckForBrokenSymlinks` attrs.
4. Add `pnpm-workspace-glob-captured-runtime`: end-to-end regression test that
   captures the glob fixture, links it into a live copy via
   `mkWorkspaceRuntime`, and asserts Node resolves the `workspace:*` import —
   the exact garden failure mode.
5. Devshell hook warning for store-linked `node_modules/.pnpm` with the
   recovery command.

## Related

- Issue #160 — workspace symlinks in node-modules output fail
  `noBrokenSymlinks` (fixed by this ADR)
- Issue #162 — extract workspace node_modules copy script to shared helper
  (closed for the capture script by this ADR)
- Issue #358 — `ln -sfn` nesting bug in `mkWorkspaceRuntime` (prior fix in the
  same subsystem)
- ADR-028: `docs/internal/designs/028-pnpm-workspace-node-modules-capture.md`
  (output contract preserved)
- ADR-040: `docs/internal/designs/040-node-workspace-runtime-convergence.md`
  (shared-helper direction this follows)
- `lib/nodejs-helpers.nix`, `modules/flake-parts/nodejs.nix`, `flake.nix`

______________________________________________________________________

Author: Jack Maloney
Date: 2026-08-10
PR: <pending>
