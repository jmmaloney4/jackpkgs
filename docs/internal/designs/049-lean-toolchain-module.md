# ADR-049: `jackpkgs.lean` — Nix-built Lean 4 environments for multiple checkouts

## Status

Proposed

## Context

### The problem

Several Lean 4 projects are now in scope at once — the Tau Ceti library, Verso
documents, the Prove2me workspace, and scratch Mathlib experiments. Each is a
`lake` project that pins its own Lean toolchain and its own Mathlib revision.
Getting any of them to build today means `elan`, an imperative version manager
that owns `~/.elan`, mutates it at run time, and is installed by piping a shell
script from the network.

`pkgs/tauceti/default.nix` already states the gap explicitly:

> What is deliberately NOT pinned: `claude`, `codex`, `kiro-cli` and `lake`.
> The agent CLIs carry the operator's credentials and subscription, and `lake`
> belongs to whichever Lean toolchain the checkout nominates through elan. All
> four are left to the caller's PATH.

That is a correct decision for the `tauceti` package and a hole at the
package-set level: something must put the *right* `lake` on PATH for a given
checkout. This ADR is that something.

### Constraint 1 — the pins do not agree, so there is little to share

Measured 2026-09-14:

| Project            | `lean-toolchain`               | Mathlib rev                |
| ------------------ | ------------------------------ | -------------------------- |
| TauCeti            | `leanprover/lean4:v4.34.0-rc2` | `30a58f79` (+ 8 more deps) |
| Verso              | `leanprover/lean4:v4.34.0`     | n/a                        |
| Prove2me (default) | `leanprover/lean4:v4.33.1`     | `0df444a3`                 |
| Prove2me (older)   | `leanprover/lean4:v4.30.0`     | `c5ea0035`                 |

Four projects, four toolchains, zero overlap. Lean projects track head closely
and TauCeti tracks *release candidates*. Any design premised on "build Mathlib
once and share it across projects" is optimising a case that does not occur in
practice. Sharing should therefore be a free side effect when revisions happen
to coincide, never a mechanism callers must operate.

### Constraint 2 — upstream `lean4-nix` lags, and the lag is structural

[`lenianiva/lean4-nix`](https://github.com/lenianiva/lean4-nix) is the viable
Nix route for Lean 4. Its `manifests/` directory is what supplies **binary**
toolchains: `readToolchainFile` resolves a stable `leanprover/lean4:{tag}` pin
against it, and `binary` defaults to `true`, so the Lean compiler itself is
*not* rebuilt.

As of 2026-09-14 its newest manifest is **`v4.33.1`, cut 2026-08-27** — 31
manifests, stopping three weeks short of current. So of the four projects
above, only Prove2me is covered. For anything else the README directs you to
`readRev`/`readFromGit`, which build **the compiler from source** in addition
to Mathlib.

This is not a transient gap. A project tracking release candidates will always
be ahead of a manifest set that is updated per stable release. Depending on
upstream's cadence makes the most interesting checkout permanently the most
expensive one.

The mitigation is available and cheap: lean4-nix ships
`nix run .#toolchain-fetch $VERSION [$VERSION_TAG]` to generate manifest
hashes, and `readBinaryToolchain <manifest>` consumes a manifest in that same
format. jackpkgs can carry its own.

### Constraint 3 — one `pkgs` instance holds exactly one Lean

lean4-nix delivers toolchains as a **nixpkgs overlay** that replaces
`pkgs.lean`. Two toolchains cannot coexist in one package set. Every Lean
environment therefore requires its own `import nixpkgs { overlays = [...]; }`.
That is a real eval cost and it is precisely the kind of thing callers should
never have to know, which makes it a good reason for the module to own the
instantiation rather than take a `pkgs` argument.

### Constraint 4 — a name already occupies `lean`

`pkgs/lean` in this repo is **QuantConnect LEAN**, the algorithmic trading
engine, `broken = true` and no longer used. lean4-nix delivers toolchains as an
overlay that replaces `pkgs.lean`, so the two cannot coexist.

The exposure is narrower than it first looks, and worth stating precisely.
`flake.nix` filters `meta.broken` out of the `packages` output, so
`packages.<system>.lean` is already absent on every system. But `overlay.nix` —
exposed as `overlays.default` — applies only `filterByPlatforms`, with no
`broken` filter, so `pkgs.lean` *is* live through the overlay path. Any consumer
applying both that overlay and lean4-nix's would get whichever ran last,
silently, at eval time.

README.md compounded it by documenting the attribute as "Lean theorem prover",
which it has never been.

### Constraint 5 — the Garnix cache will miss

lean4-nix publishes to `cache.garnix.io`, but its README requires the
downstream project's `flake.lock` nixpkgs to match, and only the newest version
is cached. jackpkgs pins its own nixpkgs and will not match. Mathlib builds are
therefore genuinely from source, and the only cache that will serve them is our
own attic.

## Decision

Add a `jackpkgs.lean` flake-parts module, following the shape of
`modules/flake-parts/quarto.nix`. Its unit is **a checkout**, and everything is
derived from files the checkout already commits.

1. **`mkLeanEnv { src, ... }` MUST derive the environment from the checkout.**
   It reads `${src}/lean-toolchain` and `${src}/lake-manifest.json`. There is no
   registry of named environments and no place to restate a pin that the
   checkout already declares. Two projects that agree on toolchain and
   revisions share store paths automatically, because Nix keys on inputs.

2. **Toolchains MUST resolve to a binary manifest.** Resolution order: a
   manifest vendored in `pkgs/lean4-toolchains/`, then upstream lean4-nix's
   `manifests/`. A toolchain matching neither MUST fail evaluation with a
   message naming the regeneration recipe. It MUST NOT fall through to
   `readRev` or any other source build of the compiler. A four-hour surprise is
   not an acceptable default, and this makes the state unspellable rather than
   merely discouraged.

3. **jackpkgs MUST vendor the manifests it needs.** `pkgs/lean4-toolchains/`
   holds `toolchain-fetch` output, regenerated by a `just` recipe, in the
   spirit of `_sources/` for nvfetcher. Seed with `v4.34.0` and
   `v4.34.0-rc2`. Vendored manifests take precedence over upstream so a
   locally-fetched version keeps working after upstream adds its own.

4. **`lake-manifest.json` MUST be committed in the checkout.** It is the output
   of `lake update`, which is an impure, network-reaching operation that has no
   place inside a derivation. `mkLeanEnv` MUST fail with a clear message when it
   is absent rather than generating one. Dependencies are then built with
   `lake2nix.buildDeps`, which reads exactly that file.

5. **The module exposes three things per project**, in increasing cost:

   - `devShells.<name>` — `lean`, `lake`, and `LEAN_PATH` preset to the
     Nix-built dependency tree. This is what fills the `lake`-on-PATH hole that
     `pkgs/tauceti` documents.
   - `packages.<name>-env` — the dependency closure as a pure, attic-cacheable
     derivation.
   - `packages.<name>` — the project's own Lake target built via
     `lake2nix.mkPackage`, for CI gating.

6. **`mkVersoSite` builds Verso documents** — manual, textbook, blog, and
   blueprint genres — to HTML and PDF as Nix outputs. Verso is an ordinary Lake
   dependency, so this layers on `mkLeanEnv` with no new toolchain machinery.

7. **`pkgs/lean` MUST be deleted** before the lean4-nix overlay is introduced
   anywhere in this repo. It is unused and broken, so removal is preferable to
   renaming: a rename relocates the hazard and keeps a dead derivation alive,
   whereas deletion means there is no `lean` attribute for either overlay to
   contend over.

### Out of scope

- Building or vendoring Mathlib's own CI cache (`lake exe cache get`). It is an
  impure CDN fetch and cannot run inside a derivation. Callers who want it can
  run it inside the devShell; the module does not wrap it.
- Pinning agent CLIs (`claude`, `codex`, `kiro-cli`). `pkgs/tauceti` already
  settled that question and this ADR does not reopen it.
- `elan`. Nothing here installs or requires it. A caller who wants it can still
  use `pkgs.elan`; the module simply never depends on it.

## Consequences

### Benefits

- A checkout builds with `nix develop` and no imperative toolchain install.
- Toolchain availability stops depending on upstream lean4-nix's release
  cadence, which is the difference between TauCeti being supported and not.
- The expensive failure mode (source-building the compiler) becomes an eval
  error with a fix in the message, rather than something discovered four hours
  in.
- One Mathlib build per `(toolchain, rev)` pair, served from attic to every
  machine and to CI.
- `pkgs.lean` stops being ambiguous — there is no such attribute to contend over.

### Trade-offs

- Mathlib is built from source. With no revision sharing across projects in
  practice, that is roughly one multi-hour build per project, re-paid whenever
  a project bumps its toolchain or Mathlib pin. For a single workstation,
  `lake exe cache get` inside a plain devShell would be faster; this design is
  only ahead once the artifact is shared across machines or CI.
- Vendored manifests are a maintenance surface. They are small and generated,
  but they are ours to regenerate.
- Each environment instantiates its own nixpkgs, so eval cost scales with the
  number of distinct toolchains in a flake.

### Risks & Mitigations

- **Nix-built ≠ upstream-built.** Building Mathlib ourselves is a second
  implementation of a build that Prove2me, in particular, verifies against
  server-side. *Mitigation:* the devShell remains a supported mode, so a
  divergence can always be checked against stock `lake` + `cache get`. Any
  project that verifies against a remote oracle SHOULD use the devShell for
  submission-bound work.
- **`cadical`.** lean4-nix's README warns that source-built overlays pin a
  `cadical` version that must be present as a `nativeBuildInputs`, or
  `bv_decide` fails at run time. *Mitigation:* binary toolchains should avoid
  it; verify explicitly on the Mathlib seed project rather than assuming.
- **Release-candidate churn.** TauCeti's `v4.34.0-rc2` will move.
  *Mitigation:* the `just` recipe makes regeneration a one-liner; the eval-time
  error makes a stale manifest loud.
- **Attic flakiness.** `nix flake check` already needs `--fallback` in this repo
  when attic 504s. A cancelled Mathlib substitution reads as a real failure.
  *Mitigation:* documented in the module's README section.

## Alternatives Considered

### Alternative A — Named environment registry

jackpkgs declares environments (`lean4-33-1`, `tauceti-4-34-rc2`) as
`(toolchain, mathlib rev)` pairs; projects reference one by name.

- Pros: sharing is explicit and legible; one obvious place to see what is built
  and cached; mirrors how Prove2me models its own environments.
- Cons: a name is a second source of truth that can silently disagree with the
  checkout's actual `lean-toolchain`; every new project needs a registry edit.
- Why not chosen: the measured pins show essentially no sharing, so the registry
  would be ceremony around an optimisation that does not fire. Content-addressed
  sharing via Nix gets the same benefit when it does fire, with no names to keep
  in sync.

### Alternative B — devShell only, `lake exe cache get` for Mathlib

Nix supplies `elan`/`lean`/`lake`; Mathlib comes from Mathlib's own CI cache.

- Pros: minutes instead of hours; byte-identical to what upstream and Prove2me's
  server build; nothing to vendor.
- Cons: impure; nothing cacheable in attic; unusable for CI gating; still leaves
  `~/.cache/mathlib` as mutable state.
- Why not chosen: explicitly rejected in favour of the Nix-built path. Retained
  as a supported mode inside the devShell rather than as the design.

### Alternative C — `readRev`/`readFromGit` for unsupported toolchains

Skip vendoring; let lean4-nix build the compiler from source whenever a
manifest is missing.

- Pros: no vendored files; works for nightlies and arbitrary revisions.
- Cons: compiler-from-source *plus* Mathlib-from-source, re-paid on every rc
  bump, for the projects we care most about.
- Why not chosen: it makes the common case the expensive case. Kept available as
  a deliberate escape hatch, never as a fallback.

### Alternative D — support only toolchains upstream already ships

- Pros: nothing to maintain.
- Cons: excludes TauCeti and Verso — both named projects — until upstream cuts
  a manifest.
- Why not chosen: it fails the actual requirement.

## Implementation Plan

1. **Delete `pkgs/lean`.** Separate scoped PR, landed first. Removes the
   package directory and its four references (`flake.nix`, `overlay.nix`, the
   commented line in `overlays/default.nix`, and the incorrect README entry).
   The `packages` output is unchanged by this, since the `meta.broken` filter
   already suppressed it.
2. **Add the `lean4-nix` flake input** and `pkgs/lean4-toolchains/` with a
   `just lean-toolchain-fetch <version>` recipe. Seed `v4.34.0` and
   `v4.34.0-rc2`.
3. **`modules/flake-parts/lean.nix`** implementing `mkLeanEnv` plus the three
   outputs. Register in `modules/flake-parts/default.nix` (`flakeModules`) and
   `modules/flake-parts/all.nix` (`imports`).
4. **Prove it on four checkouts, in this order:** a scratch Mathlib-only project
   (fastest loop, and where `cadical` and the attic story get verified), the
   Prove2me workspace (upstream manifest, happy path), Verso (`v4.34.0`,
   vendored manifest), TauCeti (`v4.34.0-rc2`, vendored manifest, nine deps).
5. **`mkVersoSite`** once the base module is proven.
6. **Bump garden's jackpkgs pin.** Garden is at `d7fb6c39`, which predates the
   tauceti merge at `c8276fe`.

Mathlib builds should run on `itachi` and land in attic before the seed
projects are declared working.

## Related

- `pkgs/tauceti/default.nix` — states the `lake`-on-PATH hole this module fills
- ADR-034 — devshell composition contract (`mkLeanEnv` devShells compose through it)
- `modules/flake-parts/quarto.nix` — the module shape followed here
- [lenianiva/lean4-nix](https://github.com/lenianiva/lean4-nix)
- [Verso](https://verso.lean-lang.org/)

______________________________________________________________________

Author: Jack Maloney
Date: 2026-09-14
PR: #<number>
