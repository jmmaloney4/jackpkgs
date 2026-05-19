# ADR-040: Converge Node Workspace Runtime Setup Across `checks` and `pre-commit`

## Status

Proposed

## Context

- `jackpkgs` currently has three separate ways to prepare a Node workspace for quality gates:
  - `modules/flake-parts/checks.nix`
  - `modules/flake-parts/pre-commit.nix`
  - `modules/flake-parts/just.nix`
- All three need the same underlying contract: take a captured `nodeModules` derivation, recreate a writable workspace-shaped runtime in a sandbox or repo checkout, expose `.bin` tools on `PATH`, and preserve pnpm workspace resolution semantics.
- That contract was never made explicit. Instead, each module grew its own shell fragments and local assumptions.
- ADR-023 returned the repo to pnpm. ADR-028 expanded the `nodeModules` output contract so workspace-local `node_modules` directories can exist under `$out/<workspace>/node_modules/`.
- Recent failures in `garden` exposed the architectural gap:
  - `pre-commit.nix` linked root `node_modules` as a single symlink into the read-only store.
  - `checks.nix` had already evolved a writable symlink-forest strategy plus package-local `node_modules` linking.
  - As a result, `checks` passed while `pre-commit` failed on the same workspace with `Permission denied` creating `node_modules/<workspace>` symlinks and later with missing package-local dependencies such as `@pulumi/cloudflare`.
- The immediate bug can be patched in each consumer, but that leaves the real problem in place: duplicated runtime setup logic with divergent behavior.
- The repo already has a broader preference for generated shell helpers over ad hoc repeated shell fragments. ADR-038 is the current example of taking a repeated pattern and giving it one canonical interface.

## Decision

- `jackpkgs` MUST define a single reusable helper for the "captured pnpm workspace runtime" contract in `lib/nodejs-helpers.nix`.
- `checks.nix` and `pre-commit.nix` MUST consume that helper instead of maintaining separate shell implementations for:
  - writable root `node_modules` population
  - package-local `node_modules` linking
  - workspace package symlink creation
  - `.bin` PATH setup
- The shared helper MUST preserve the output contract established by ADR-028:
  - root dependencies come from `$out/node_modules`
  - package-local dependencies may come from `$out/<workspace>/node_modules`
- The first convergence phase is limited to `checks.nix` and `pre-commit.nix`. `just.nix` is intentionally deferred because it runs in the devshell against a live checkout rather than against a captured `nodeModules` derivation.
- `just.nix` SHOULD converge on the same conceptual runtime contract later, but this ADR does not require forcing it through the same helper before that contract is designed cleanly.
- New Node quality-gate features MUST extend the shared helper or an adjacent shared abstraction rather than copying shell setup into another module.

## Consequences

### Benefits

- One runtime contract instead of parallel shell snippets that drift silently.
- `checks` and `pre-commit` now fail or succeed for the same reasons on the same workspace topology.
- Fixes to pnpm sandbox semantics land once and propagate to all consumers.
- Test coverage can assert the shared behavior instead of freezing two slightly different implementations.
- The codebase is easier to reason about because the architectural boundary is explicit: "captured nodeModules output" vs "consumer-specific command execution."

### Trade-offs

- The shared helper increases coupling between `checks.nix` and `pre-commit.nix`, but that coupling already exists in reality; the ADR makes it explicit.
- We are not fully unifying `just.nix` in the first pass, so some architectural asymmetry remains.
- The helper still emits shell, so this is a bounded refactor, not a total redesign of Node tool execution.

### Risks & Mitigations

- Risk: The helper may accidentally encode assumptions that only hold for one consumer.
  - Mitigation: Keep the helper scoped to runtime preparation only. Leave command invocation, error messaging, and check-specific policy in the caller.
- Risk: Future work reintroduces local shell snippets in a hurry.
  - Mitigation: Treat this ADR as the design guardrail; new Node sandbox setup belongs in the shared helper.
- Risk: `just.nix` remains a third execution model and drifts further.
  - Mitigation: Track a follow-up to decide whether `just.nix` should consume a parallel helper, stay intentionally separate, or move to generated shell applications.

## Alternatives Considered

### Alternative A — Keep patching each module independently

- Pros: Fastest path for the immediate bug.
- Cons: Guarantees future drift, duplicates fixes, and makes failures harder to reason about.
- Why not chosen: This is the architecture that produced the current regression.

### Alternative B — Force all consumers through one giant Node execution framework now

- Pros: Maximum unification in theory.
- Cons: Higher blast radius, slower review, mixes runtime setup with unrelated command-generation policy, and would pull `just.nix` into the refactor before its constraints are cleanly modeled.
- Why not chosen: Too much change for the current bug class. The bounded helper gets most of the architectural win with lower risk.

### Alternative C — Reconstruct pnpm links dynamically in each caller

- Pros: Keeps the helper layer thin or nonexistent.
- Cons: Repeats pnpm runtime assumptions in multiple places and recreates the same divergence problem under a different name.
- Why not chosen: We already have the captured derivation contract from ADR-028. Consumers should use it consistently, not reinterpret it independently.

## Implementation Plan

1. Add a shared `mkWorkspaceRuntime` helper to `lib/nodejs-helpers.nix`.
2. Port `checks.nix` to use the helper for root and package-local `node_modules` setup.
3. Port `pre-commit.nix` to use the same helper for biome, `tsc`, and vitest hooks.
4. Update nix-unit tests so they assert the converged runtime contract instead of stale implementation details.
5. Keep `just.nix` unchanged in this phase, but record the remaining design choice explicitly in the plan document and any follow-up PR notes.
6. In a later phase, decide whether `pre-commit` hook wrappers should move to `writeShellApplication`-backed generation consistent with ADR-038-style shell encapsulation.

## Related

- `docs/internal/plans/2026-05-19-node-tooling-sandbox-convergence.md`
- ADR-023: `docs/internal/designs/023-return-to-pnpm.md`
- ADR-028: `docs/internal/designs/028-pnpm-workspace-node-modules-capture.md`
- ADR-029: `docs/internal/designs/029-unified-quality-gate-controls.md`
- ADR-038: `docs/internal/designs/038-mk-helm-chart-from-github.md`
- `lib/nodejs-helpers.nix`
- `modules/flake-parts/checks.nix`
- `modules/flake-parts/pre-commit.nix`
- `modules/flake-parts/just.nix`

______________________________________________________________________

Author: Jack Maloney
Date: 2026-05-19
PR: <pending>
