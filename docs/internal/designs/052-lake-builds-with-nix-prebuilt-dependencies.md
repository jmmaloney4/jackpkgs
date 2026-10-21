# ADR-052: Lake Builds with Nix-Provided Precompiled Dependencies

## Status

Proposed (2026-10-21). The intended architecture is selected for evaluation;
compatibility of the current Mathlib artifact closure with Lake's build-state
tracking has **not** been demonstrated. No implementation is authorized by the
existence of this ADR alone.

## Context

ADR-049 introduced `jackpkgs.lean`. For each checkout it derives the Lean
toolchain from `lean-toolchain` and dependencies from the committed
`lake-manifest.json`, then exposes a devShell and a dependency derivation.
Mathlib projects fetch upstream compiled artifacts with `lake exe cache get` in a
fixed-output derivation (FOD); projects without Mathlib use
`lake2nix.buildDeps`. The module does not build the checkout's own Lake targets.

This is fast and provides the Lean compiler with valid imported `.olean` files
through `LEAN_PATH`. It is not equivalent to a Lake-managed project workspace:
Lake must also locate its declared packages and establish whether each target
is up to date. A path to `.olean` files alone does not establish that state.

ADR-049 deliberately removes `.git`, `*.trace`, `*.setup.json`, `*.rsp`, and
dependency `.lake/build/bin` trees from the captured Mathlib closure.
That removal was introduced after independent cold fetches of the unpruned
tree produced different Nix hashes. Consequently the retained compiled
artifacts do not carry the full build-state metadata Lake ordinarily uses.

The concrete consumer is `garden/lean/kolmogorov` (garden ADR-197). Its
`build.py` finds and topologically sorts local Lean modules and calls the Lean
compiler directly against the Nix-provided `LEAN_PATH`, with
`-DwarningAsError=true`. The `garden/nix/lean.nix` flake check runs that
script so all local modules are checked in CI, including `#guard_msgs`
assertions. This avoids asking Lake to rebuild the immutable, trace-pruned
dependencies, but duplicates project build orchestration, bypasses normal Lake
incremental builds, and is not a reusable contract for other Lean checkouts.

### Requirements

- Preserve ADR-049's project-owned toolchain and manifest pins, binary Lean
  toolchains, Mathlib's precompiled artifacts, and no unexpected compiler or
  Mathlib source builds.
- Preserve the reproducible FOD boundary. A change making the Mathlib FOD
  nondeterministic merely to please Lake is not acceptable.
- Support two distinct consumers: a reproducible Nix build/check of the
  project's own targets **and** ordinary `lake build` in the devShell.
- Neither workflow may mutate the Nix store or silently resolve manifest
  dependencies from the network during a build.
- Preserve fail-closed Lean verification: no accepted `sorry`,
  `warningAsError` on local modules, and existing `#guard_msgs`/axiom audits.
- Do not regress non-Mathlib projects, or make `elan` a requirement.
- Keep the project definition (`lakefile.toml` or `lakefile.lean` and
  `lake-manifest.json`) authoritative; do not maintain a second hand-written
  dependency graph.

## Decision

**Integrate cached Mathlib dependencies with `lake2nix` for Nix builds
(Approach C), and provide a complementary Lake workspace adapter for
interactive builds (Approach B).** Both capabilities belong in `jackpkgs.lean`,
rather than in each consuming repository.

The decision is conditional on the validation gates below: the mechanisms for
Lake-compatible dependency metadata have not yet been established. The spike
MUST establish that the proposed architecture can reuse precompiled Mathlib
without rebuilding it before implementation is declared complete.

### 1. Nix project builds — Approach C (primary)

`jackpkgs.lean` SHOULD expose a project build derivation, e.g.
`packages.kolmogorov-lean`, in addition to the existing
`packages.kolmogorov-lean-deps` and `devShells.kolmogorov` outputs.

- The project builder MUST use Lake for the project's own targets. Prefer
  `lean4-nix`'s existing `lake2nix.mkPackage` and its `lakeDeps` interface,
  adapting it upstream or locally only where necessary.
- It MUST consume the precompiled Mathlib package closure already fetched by
  the FOD, not build Mathlib from source as the normal path.
- The adapter MUST bridge the current single-tree FOD to the dependency
  representation expected by `lake2nix`, retaining correct transitive package
  relationships, sources, artifacts and matching toolchain versions.
  `lake2nix.buildDeps` already exposes `depOverrideDeriv`; whether it can
  safely take the current FOD's package views requires a real build test.
- Any mutable package shadows or build metadata MUST be created outside the
  FOD, in disposable writable build directories. Trace files MUST NOT simply
  be restored into the reproducible FOD without proving a new reproducibility
  invariant. A synthetic "up-to-date" marker unsupported by Lake's actual
  checks MUST NOT be treated as a correctness proof.
- Builds MUST fail if a prebuilt artifact does not match the pinned sources,
  manifest, toolchain or expected package layout; they MUST NOT silently fall
  back to rebuilding a large dependency closure.
- For projects without Mathlib, the existing `lake2nix.buildDeps` path MUST
  remain available.

The intended Nix outputs are illustrative, not a final API specification:

| Output | Responsibility |
| --- | --- |
| `devShells.<project>` | Developer toolchain and Lake-compatible workspace |
| `packages.<project>-lean-deps` | Reproducible precompiled dependency closure |
| `packages.<project>-lean` | Lake-built project targets for CI and consumers |

### 2. Interactive workspace — Approach B (companion)

The same project SHOULD support, from a clean checkout:

`nix develop .#kolmogorov`, then `cd lean/kolmogorov` and `lake build`.

- The devShell or an explicit, idempotent setup helper MUST make Lake's
  package graph resolve to the Nix-pinned dependencies without an impure
  dependency download.
- Prefer `lake2nix`'s existing surrogate path-manifest and writable shadow
  directory approach. The pinned implementation of
  `lean4-nix/lib/lake.nix` already creates package shadows and
  `.lake/package-overrides.json`; reuse or extract that mechanism rather than
  write a second Lake package resolver.
- It MUST make relevant package metadata writable where Lake needs to update
  it, while keeping the Nix sources and compiled artifacts immutable.
- It MUST establish, by an actual `lake build`, how missing or invalid
  `*.trace` data are handled; symlinking `.olean` files into
  `.lake/packages` is not by itself sufficient.
- Setup MUST be safe to repeat, must not create nested
  `.lake/packages/packages` directories, and must not overwrite unrelated
  developer changes. Local project artifacts MUST remain incremental.
- The devShell MUST NOT eagerly copy the whole multi-gigabyte dependency
  closure when links, overlays, or narrowly copied metadata will suffice.

A successful Nix derivation alone is **not** evidence that the interactive
`lake build` use case works: C and B have separate acceptance gates.

### 3. Verification, source of truth, and migration

- Project pinning stays in `lean-toolchain` and
  `lake-manifest.json`, per ADR-049. Reproducibility remains sensitive to
  platform: `.olean` artifacts cannot be assumed interchangeable across
  supported systems.
- Garden's `build.py` MUST stay as the CI gate until a Lake-based check proves
  at least equivalent coverage and failure behavior. It MUST NOT be removed
  merely because Lake can compile one imported smoke-test module.
- The replacement check MUST reject an intentionally inserted `sorry`,
  exercise existing `#guard_msgs` assertions, and compile every declared local
  module, including modules not transitively imported by the default target
  (either by explicit Lake targets or a checked complete module inventory).
- The project build and devShell MUST each work offline with an already
  realized dependency closure, on the supported platforms used by the
  consumer. No implicit `lake update` or Git network access during builds.
- The existing same-content Mathlib FOD duplication between garden's
  `prove2me` and `kolmogorov` SHOULD be addressed separately by keying the
  dependency artifact on normalized toolchain/manifest identity rather than
  the consuming project name. This is a useful follow-on optimization, not a
  prerequisite for correct Lake integration.

### Out of scope

- Replacing Lake with a custom long-term Lean compiler orchestrator.
- Patching Lean or Lake upstream before trying existing interfaces.
- Running an independent Mathlib binary artifact service.
- Changing garden's mathematical definitions, theorems, or proof contracts.
- Assuming Lake has a supported "trust arbitrary prebuilt artifacts" flag;
  that capability has to be demonstrated rather than inferred.

## Consequences

### Benefits

- The normal Lean/Lake build graph becomes authoritative for local targets,
  avoiding bespoke module ordering and improving incremental builds.
- The Nix check can depend on a reusable, cached project derivation, not a
  garden-specific Python script.
- Interactive Lean/Lake and CI use the same pinned toolchain and dependencies,
  narrowing differences in proof-checking environments.
- Other Lean projects in garden or elsewhere can reuse the integration.

### Trade-offs

- Two environments still need integration: immutable Nix derivations and
  mutable interactive workspaces.
- Lake trace semantics and package configuration recompilation must be
  understood well enough to avoid spurious dependency rebuilds.
- A derived adapter layer is added to jackpkgs and possibly lean4-nix;
  changes to Lake's package/trace format can require updates.
- Exposing extra project build derivations can increase evaluation and build
  complexity, even when caches keep compilation costs low.

### Risks & Mitigations

- **Lake rebuilds Mathlib despite visible oleans.** Treat that as a failed
  acceptance gate; investigate the trace and package configuration semantics,
  rather than disabling checks or falling back silently.
- **FOD hashes become unstable.** Preserve the current pruned FOD; generate
  mutable metadata downstream. Repeat independent cold-fetch hash tests if
  the FOD representation changes.
- **False-positive green proof builds.** Retain compiler warning-as-error,
  `sorry` negative controls, complete-module coverage, and `#guard_msgs`
  tests before switching the CI gate.
- **Hidden network dependencies.** Test with sandboxed/offline builds and a
  pre-realized dependency closure. Dependency changes require deliberate pin
  changes, not on-demand resolution.
- **Platform-specific failures.** Exercise the existing darwin/Linux pins
  independently; never infer binary compatibility or FOD hash equality.
- **Workspace contamination or full-tree copying.** Validate repeated setup,
  clean-checkout startup, isolated worktrees, and no writes to Nix store
  paths; measure the resulting disk usage.

## Alternatives Considered

### A — Plain mutable Lake workspace (`lake exe cache get; lake build`)

- Pros: straightforward, upstream workflow; uses Mathlib's binary cache.
- Cons: downloads and owns mutable dependencies outside Nix; duplicates
  closure and weakens reproducible/offline CI.
- Why not chosen: useful debugging baseline, not our package-management
  contract.

### B alone — Writable package shadows with the existing Nix devShell

- Pros: potentially fixes the immediate interactive `lake build` problem.
- Cons: leaves CI relying on `build.py` and does not provide a reusable Nix
  derivation for the project's own targets.
- Why not chosen alone: accepted only as the companion to C.

### D — `lake2nix.buildDeps` for Mathlib from source

- Pros: follows the existing source-build dependency representation, avoids
  adapting the Mathlib artifact FOD.
- Cons: forfeits the principal performance benefit established in ADR-049,
  especially across toolchain/revision bumps.
- Why not chosen: keep only as an explicit fallback when no compatible
  upstream compiled artifacts exist.

### E — Extend upstream Lake with native external-prebuilt-package semantics

- Pros: potentially the most principled general solution: Lake recognizes
  Nix-provided artifacts as immutable external dependencies.
- Cons: upstream implementation and version adoption costs; no demonstrated
  API meeting these requirements in our pinned Lean.
- Why not chosen now: prefer testing and improving existing `lake2nix`
  integration; revisit if the adapter cannot safely handle build state.

### Keep `build.py` indefinitely

- Pros: already works, minimal, and independently enforces warning failures.
- Cons: permanently duplicates Lake's dependency ordering and build behavior,
  recompiles every local module on each run, does not provide Lake's usual
  target/incremental workflows.
- Why not chosen: retain temporarily as a trusted regression baseline only.

## Implementation Plan

1. **Mechanism spike (jackpkgs; no production migration):** On pinned Lean
   v4.33.1 + Mathlib `0df444a3`, inspect exactly how `lake2nix.mkPackage`
   treats the current Nix-provided packages and traces. Build a minimal
   project and record which target Lake rebuilds, and why. Prove the result
   uses no network and does not write the Nix store. If this fails, revisit
   the decision before designing a custom trace generator.
2. **Dependency adapter (jackpkgs):** Expose prebuilt FOD dependency packages
   through `lakeDeps` (or a narrow lean4-nix extension). Add a regression
   fixture with transitive imports, no unintended Mathlib compilation, and
   explicit pin-mismatch failure.
3. **Nix project target (jackpkgs):** Export a Lake-built project derivation,
   exercise a non-Mathlib fixture, and wire a `kolmogorov` consumer check.
4. **Interactive adapter (jackpkgs):** Reuse the package shadows and path
   overrides in the devShell; test fresh setup, repeated setup, real
   `lake build`, incremental rebuilds, and no network or Nix-store writes.
5. **Consumer migration (garden):** Change the CI gate only after the
   `sorry`/`#guard_msgs` negative controls and complete-module inventory
   pass; then delete `lean/kolmogorov/build.py` and its custom check plumbing.
6. **Follow-on optimization:** Deduplicate identical Mathlib dependency
   closures across garden projects without weakening FOD content identity.

**Acceptance:** A clean checkout with pre-realized Nix dependencies builds
`kolmogorov` through the new Nix package and through interactive
`lake build`; neither path downloads or recompiles Mathlib, both reject the
negative proof controls, and a one-file edit triggers only necessary local
recompilation. Until those tests exist and pass, this ADR remains Proposed.

**Rollback:** Keep `build.py` and the existing check active throughout the
migration. If either new path fails, stop routing consumers to it; no changes
to mathematical proof sources or pinned dependencies are required for rollback.

## Related

- [ADR-049: Nix-built Lean 4 environments](049-lean-toolchain-module.md)
  — retained as the record of artifact acquisition and reproducibility.
  This ADR extends its project-build and devShell contract; it does not
  supersede its dependency-pinning decisions.
- [jackpkgs `lib/lean.nix`](../../../lib/lean.nix) and
  [`modules/flake-parts/lean.nix`](../../../modules/flake-parts/lean.nix)
- [jackpkgs ADR-049 implementation issue](https://github.com/jmmaloney4/jackpkgs/issues/388)
- [garden Kolmogorov builder](https://github.com/jmmaloney4/garden/blob/main/lean/kolmogorov/build.py)
  and [Nix check](https://github.com/jmmaloney4/garden/blob/main/nix/lean.nix)
- [garden ADR-197](https://github.com/jmmaloney4/garden/blob/main/docs/internal/decisions/197-kolmogorov-complexity-interface-for-effective-dimension.md)
- [lean4-nix `lib/lake.nix`](https://github.com/lenianiva/lean4-nix/blob/master/lib/lake.nix)

______________________________________________________________________

Author: ChatGPT (draft for operator review)
Date: 2026-10-21
PR: pending
