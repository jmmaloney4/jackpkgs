# ADR-040: Converge the Node workspace execution contract across `checks`, `pre-commit`, and `just`

## Status

Proposed

## Context

- `jackpkgs` has three Node quality-gate surfaces:
  - `modules/flake-parts/checks.nix`
  - `modules/flake-parts/pre-commit.nix`
  - `modules/flake-parts/just.nix`
- All three need the same conceptual contract:
  - choose the workspace package set
  - reconstruct or use a workspace-shaped dependency runtime
  - expose trusted tool binaries
  - run the tool over the chosen project set with consistent semantics
- That contract was never made explicit. Instead, each module grew its own shell fragments, fallback rules, and tool-specific assumptions.
- ADR-023 returned the repo to pnpm. ADR-028 expanded the `nodeModules` output contract so workspace-local `node_modules` directories can exist under `$out/<workspace>/node_modules/`.
- The first convergence pass has already landed in code:
  - `lib/nodejs-helpers.nix` now defines `jackpkgsLib.nodejs.mkWorkspaceRuntime`.
  - `checks.nix` and the Node hooks in `pre-commit.nix` use that helper for writable root `node_modules`, package-local `node_modules`, workspace symlinks, and `.bin` PATH setup.
  - `pre-commit.nix` now uses `writeShellApplication` wrappers instead of large inline hook bodies.
- That first pass fixed the immediate runtime-shape regression exposed in `garden`, where `checks` passed but `pre-commit` failed because it reconstructed a different `node_modules` layout.
- But the broader execution contract still has real drift:
  - package resolution is still duplicated between `checks.nix` and `pre-commit.nix`
  - `pre-commit.nix` still has an extra fallback layer through its own option surface before consulting `checks`
  - `just.nix` still consumes `checks.typescript.tsc.packages` directly and does not share the same resolution helper or execution model
  - TypeScript invocation semantics still differ: `checks.nix` runs root `tsc --noEmit`, while `pre-commit.nix` and `just.nix` iterate per project when packages are known
- So the repo now has one converged runtime-preparation layer, but not one converged Node execution contract.
- The repo already prefers shared helpers and generated shell applications over repeated ad hoc shell snippets. ADR-038 is the nearby example of turning a repeated pattern into one canonical interface.

## Decision

- This ADR covers the full Node workspace execution contract, not only runtime setup.
- `jackpkgs` MUST keep a single reusable helper in `lib/nodejs-helpers.nix` for the captured pnpm workspace runtime contract.
- `checks.nix` and `pre-commit.nix` MUST continue consuming that shared runtime helper instead of maintaining local implementations for:
  - writable root `node_modules` population
  - package-local `node_modules` linking
  - workspace package symlink creation
  - `.bin` PATH setup
- `jackpkgs` MUST also define shared helpers for package-set resolution so that `checks.nix`, `pre-commit.nix`, and `just.nix` do not each reimplement fallback rules around explicit package lists vs pnpm workspace discovery.
- `just.nix` does NOT need to use `mkWorkspaceRuntime`, because it runs in a live devshell checkout rather than against a captured `nodeModules` derivation. But it MUST consume the same package-resolution contract and the same tool-invocation policy as the other surfaces unless an intentional divergence is documented.
- Tool invocation policy is a first-class part of the contract. For each Node quality gate, the repo MUST define one canonical execution model and reuse it across surfaces.
- For TypeScript specifically, the canonical policy SHOULD be:
  - when a package list is known explicitly or by pnpm workspace discovery, run per-project checks using each package's own `tsconfig.json`
  - reserve root-only `tsc --noEmit` for true single-project repos or an explicitly documented fallback path
- The shared runtime helper MUST preserve the output contract established by ADR-028:
  - root dependencies come from `$out/node_modules`
  - package-local dependencies may come from `$out/<workspace>/node_modules`
- New Node quality-gate features MUST extend the shared helpers or adjacent shared abstractions rather than copying package-resolution logic, runtime setup, or tool-invocation policy into another module.

## Proper convergence

The correct end state has three layers, each with one owner:

1. Runtime preparation for captured `nodeModules`
   - Owner: `lib/nodejs-helpers.nix`
   - Used by: `checks.nix`, `pre-commit.nix`
   - Responsibility: materialize writable root `node_modules`, link package-local `node_modules`, create workspace import symlinks, expose trusted `.bin` tools on `PATH`

2. Package-set resolution
   - Owner: `lib/nodejs-helpers.nix`
   - Used by: `checks.nix`, `pre-commit.nix`, `just.nix`
   - Responsibility: resolve the project set from explicit config or pnpm workspace discovery with one canonical fallback order
   - Requirement: the same config should resolve to the same package list in all three surfaces

3. Tool-invocation policy
   - Owner: shared helper(s) or one clearly documented policy surface per tool
   - Used by: `checks.nix`, `pre-commit.nix`, `just.nix`
   - Responsibility: define whether a tool runs once at root, once per package, what config file is authoritative, and what fallback behavior is allowed
   - Requirement: differences must be intentional and documented, not accidental products of separate implementations

In practice, that means:

- `checks.nix` should stop being the only place that knows the effective TypeScript check semantics.
- `pre-commit.nix` should stop carrying a bespoke fallback chain for `tscPackages`, `vitestPackages`, and `biomePackages`.
- `just.nix` should stop reading raw `checks.typescript.tsc.packages` as a special case and instead consume the same resolved package set abstraction the other surfaces use.
- If a repo configures one package set for TypeScript, that same set should be checked by `nix flake check`, pre-commit, and `just lint`.
- If one surface intentionally behaves differently because it runs in a live checkout rather than a Nix sandbox, that difference should be limited to runtime preparation, not package selection or core execution semantics.

## Consequences

### Benefits

- One execution contract instead of one shared runtime helper plus duplicated policy around it.
- `checks`, `pre-commit`, and `just` fail or succeed for the same reasons on the same workspace topology.
- Fixes to pnpm workspace discovery, package selection, and TypeScript semantics land once and propagate to every surface.
- Tests can assert behavior at the contract boundary instead of freezing three slightly different interpretations.
- The codebase is easier to reason about because the boundary becomes explicit:
  - captured-runtime setup
  - package selection
  - consumer-specific command wrapping

### Trade-offs

- The shared helper layer grows beyond filesystem setup into package resolution and execution policy, which increases coupling across modules.
- `just.nix` still remains a distinct runtime environment, so complete implementation-level unification is neither possible nor desirable.
- Moving from "shared shell snippet" to "shared execution contract" requires more up-front design discipline than patching individual modules.

### Risks & Mitigations

- Risk: the helper layer becomes a giant Node framework instead of a focused contract boundary.
  - Mitigation: keep the layers narrow. Runtime setup, package resolution, and invocation policy are shared; user-facing messages and per-surface wiring stay local.
- Risk: `just.nix` gets forced through abstractions designed for captured `nodeModules` even though it runs in a live checkout.
  - Mitigation: share package resolution and invocation policy, not the runtime-preparation implementation.
- Risk: TypeScript semantics change in a way that surprises repos currently relying on root-only checks.
  - Mitigation: keep root-only behavior as an explicit fallback for true single-project repos and document the migration path for multi-project workspaces.
- Risk: future work adds another Node surface that copies local fallback logic.
  - Mitigation: treat this ADR as the guardrail. New Node surfaces must consume the shared package-resolution and invocation helpers.

## Alternatives Considered

### Alternative A — Stop at runtime convergence

- Pros: Most of the immediate bug is already fixed.
- Cons: Leaves package resolution and tool semantics duplicated, which means future drift just moves one layer up.
- Why not chosen: This is the current half-converged state, and it is still easy for `checks`, `pre-commit`, and `just` to disagree.

### Alternative B — Force all consumers through one giant Node execution framework now

- Pros: Maximum unification in theory.
- Cons: Higher blast radius, slower review, and conflates runtime setup with unrelated consumer policy.
- Why not chosen: Too much change. The correct move is to share the contract boundaries, not erase every implementation distinction.

### Alternative C — Keep package resolution local and only document the expected behavior

- Pros: Lower refactor cost.
- Cons: Duplicated fallback chains remain a bug source, and docs alone will not stop drift.
- Why not chosen: The current divergence already proves that documentation without shared code is not enough.

## Implementation Plan

1. Keep `mkWorkspaceRuntime` as the canonical captured-runtime helper in `lib/nodejs-helpers.nix`.
2. Add shared package-resolution helpers in `lib/nodejs-helpers.nix` for explicit package lists vs pnpm workspace discovery.
3. Refactor `checks.nix` and `pre-commit.nix` to consume those helpers instead of maintaining local fallback chains.
4. Refactor `just.nix` to consume the same resolved package-set abstraction even though it keeps its live-checkout execution path.
5. Define and implement one canonical TypeScript invocation policy across `checks`, `pre-commit`, and `just`.
6. Audit `vitest` and `biome` for the same class of drift and either converge their invocation policy or document intentional differences.
7. Update nix-unit and fixture-backed tests so they assert:
   - shared package resolution
   - shared workspace import behavior
   - shared package-local dependency behavior
   - consistent TypeScript execution over the same configured package set
8. Keep any remaining `just.nix` asymmetry explicit in the plan document and PR notes.

## Related

- `docs/internal/plans/2026-05-19-node-tooling-sandbox-convergence.md`
- ADR-023: `docs/internal/designs/023-return-to-pnpm.md`
- ADR-028: `docs/internal/designs/028-pnpm-workspace-node-modules-capture.md`
- ADR-029: `docs/internal/designs/029-unified-quality-gate-controls.md`
- ADR-034: `docs/internal/designs/034-multi-project-typescript-lint.md`
- ADR-038: `docs/internal/designs/038-mk-helm-chart-from-github.md`
- `lib/nodejs-helpers.nix`
- `modules/flake-parts/checks.nix`
- `modules/flake-parts/pre-commit.nix`
- `modules/flake-parts/just.nix`

______________________________________________________________________

Author: Jack Maloney
Date: 2026-05-19
PR: <pending>
