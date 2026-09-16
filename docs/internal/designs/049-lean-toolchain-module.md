# ADR-049: `jackpkgs.lean` — Nix-built Lean 4 environments for multiple checkouts

## Status

Proposed — **revised 2026-09-16** after a HARDEN pass (jmmaloney4/jackpkgs#388)
falsified the original Decision 5. Corrections are recorded inline rather than
silently applied; see Decision 5 and Constraints 5–6.

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

As of 2026-09-14 its newest manifest is **`v4.33.1`, cut 2026-08-27** — 28
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

### Constraint 5 — lean4-nix is broken on aarch64-darwin

Measured 2026-09-14 on macOS 26.6.2, Lean v4.33.1.

An earlier revision of this ADR claimed `readToolchain` ignores its documented
`binary ? true` default. **That was wrong** — corrected on review. `readToolchain`
does default `binary = true` for the *string* form, and `readToolchainFile` for
the *path* form; only the attrset form requires it explicitly, which is the shape
that produced the original `attribute 'binary' missing`. The real bug is:

1. With `binary = true`, `fixupPhase` dies:
   `install_name_tool: ... can't be redone for ... libleanshared_1.dylib ... because larger updated load commands do not fit`.

Removing `fixDarwinDylibNames` alone makes it *worse*: the build succeeds and
dyld then refuses a **different** library at run time
(`libInit_shared.dylib ... load commands do not fit in __TEXT segment filesize`), which reads like an unrelated fault.

Root cause, established with a control rather than inferred: the raw upstream
tarball, unpacked and run untouched, works perfectly. Upstream's arm64 binaries
are already signed and already use `@rpath`; any rewrite — `install_name_tool`
from `fixDarwinDylibNames`, or `strip` — both invalidates the signature and
overflows the Mach-O header pad. nixpkgs' darwin `fixupPhase` is the corruptor,
not Lean.

### Constraint 6 — `lake exe cache get` is Mathlib-only

`cache` is an executable **Mathlib itself ships**, hash-rooted at `Mathlib`. A
project without Mathlib in its `lake-manifest.json` fails with
`error: unknown executable cache` — measured on a `batteries`-only project, which
also fetched **zero** prebuilt artifacts. Every Reservoir build-cache probe for a
non-Mathlib package returned 404 on 2026-09-15.

Verso, one of the projects motivating this work, has no Mathlib: its dependencies
are `Cli`, `illuminate`, `plausible`, `MD4Lean`, `subverso`. Dependency
acquisition therefore has two genuine regimes, and a design assuming one is
Mathlib-only while claiming to be general.

### Constraint 7 — the Garnix cache will miss (minor)

lean4-nix publishes to `cache.garnix.io`, but its README requires the downstream
project's `flake.lock` nixpkgs to match, and only the newest version is cached.
jackpkgs pins its own nixpkgs and will not match.

Recorded for completeness rather than as a driver. It mattered while a from-source
Mathlib build was the plan; under Decision 5 that build is the fallback, so a
missed third-party cache costs little.

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
   is absent rather than generating one. Generating it here would be an unpinned
   network fetch wearing a pinned interface — and inside a fixed-output
   derivation it would freeze whatever the CDN happened to serve into an artifact
   that then reproduces faithfully forever.

5. **Mathlib MUST arrive via a fixed-output derivation, not a source build —
   and that FOD MUST be keyed on content and pruned of everything
   nondeterministic.**

   `lake exe cache get` fetches Mathlib CI's prebuilt artifacts for a pinned
   revision — immutable blobs, not a fresh computation — which is what an FOD is
   for. Roughly a minute instead of hours.

   **A naive FOD over `.lake/packages` does not work.** Measured 2026-09-15: two
   cold builds produced *different* hashes, because `cp -R` copies each
   dependency's `.git`, whose reflogs embed wall-clock time and committer
   identity and whose pack filenames differ per clone. Across the whole tree, 104
   files differed, 42 under `.git/`.

   An earlier revision asserted the opposite, on evidence that failed twice over;
   the correction is recorded rather than quietly dropped. The measurement was
   **scoped to `packages/mathlib/.lake/build`**, a subset of what the derivation
   captures. And it varied **imports**, which provably cannot affect the result,
   since bare `lake exe cache get` always roots at `Mathlib` and ignores the
   calling project's imports. The variable that matters — a fresh clone — was
   never varied.

   The `installPhase` MUST prune by **rule**, not enumeration: `.git`, `*.trace`,
   `*.setup.json`, `*.rsp`, and each package's `build/bin`. The enumeration it
   replaces came from one diff and missed `bin/cache` (~104 MB),
   `bin/cache.hash`, and a `batteries` trace. The fragment MUST let the shell
   expand `$out`: `lib.escapeShellArg` single-quotes it, yielding
   `rm -rf -- '$out/…'`, which removes nothing and exits 0 — silently disabling
   the only mechanism keeping the hash stable.

   Re-measured with that prune, two independent cold builds agree:
   `sha256-sxi8QdloT+Zvv3HSD4rd8D0m03k47625d6sR9VDdXpY=`.

   **The derivation name MUST carry a digest of `lake-manifest.json`.** A
   fixed-output path is `f(name, hash)` — independent of `src` and of the
   manifest — so bumping a dependency while keeping `artifactHash` silently
   reuses the previous closure, and a stale Mathlib produces *successful* builds
   against the wrong library. The digest also makes Decision 1's sharing claim
   true rather than aspirational.

   **Projects without Mathlib MUST take the source-build path**
   (`lake2nix.buildDeps`), per Constraint 6. That path is cheap — those
   dependency sets are small.

6. **The module exposes two things per project:**

   - `devShells.<name>` — `lean`, `lake`, and `LEAN_PATH` set to the Nix-built
     dependency tree. This fills the `lake`-on-PATH hole `pkgs/tauceti`
     documents. It MUST set the environment rather than print an instruction to
     symlink a store path into `.lake/packages`: that errors on a fresh checkout
     and silently creates `.lake/packages/packages` on a used one, after which
     lake re-resolves over the network — the exact outcome this module exists to
     prevent, reported as success.
   - `packages.<name>-lean-deps` — the dependency closure as a pure derivation.

   A project's own Lake target is **not** exposed. `lake2nix.mkPackage` builds
   one derivation per dependency while the FOD produces a single opaque tree;
   those models were never reconciled, and a declared-but-dead option is worse
   than an absent one.

7. **A missing `artifactHash` MUST fail at build, not at instantiation.**
   Reaching that refusal through `shellHook` breaks `nix flake show`/`check` for
   an entire consuming repo over one unset hash, and makes the bootstrap circular
   — the shell needed to mint a hash cannot be entered without one.

8. **`pkgs/lean` MUST be deleted.** It is unused and broken, so removal beats
   renaming: a rename relocates the hazard and keeps a dead derivation alive,
   whereas deletion leaves no `lean` attribute for either overlay to contend
   over. This is hygiene, **not** a prerequisite: `mkLeanEnv` instantiates its
   own nixpkgs carrying only lean4-nix's overlay, so jackpkgs' overlay and
   lean4-nix's never meet.

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
  error with a fix in the message, rather than something discovered hours in.
- Mathlib arrives in about a minute per `(toolchain, rev, system)`, pure at the
  Nix level.
- `pkgs.lean` stops being ambiguous — there is no such attribute to contend over.

### Trade-offs

- **One FOD hash per `(revision, system)`**, recorded by hand. `.olean` files are
  compiled, so a hash minted on darwin does not serve linux.
- Vendored manifests are a maintenance surface. Small and generated, but ours to
  regenerate.
- Each environment instantiates its own nixpkgs, so eval cost scales with the
  number of distinct toolchains in a flake — not with the number of projects,
  but memoising on the tag is an available optimisation if it ever bites.
- Two dependency-acquisition regimes to maintain instead of one. This reflects a
  real asymmetry in the ecosystem (Constraint 6) rather than a design choice.

### Risks & Mitigations

- **Cross-machine reproducibility is unproven.** Both reproducibility runs were
  on one aarch64-darwin host, where `sandbox = false` — so a build can read host
  state. The prune removes the identified carriers of hostname and timestamp, but
  sufficiency across hosts is inferred, not measured. *Mitigation:* treat recorded
  hashes as machine-attested until a linux build confirms one; `export HOME="$TMPDIR"`
  in the builder is load-bearing, since without it the build consumes
  `~/.cache/mathlib` and mints a hash nobody else can reproduce.
- **Mathlib CDN retention.** With no binary cache of our own, an FOD pinned to an
  old revision becomes unbuildable if Mathlib CI rotates its artifacts away.
  *Mitigation:* none taken deliberately — the risk is unquantified, and hedging it
  would cost ~6.8 GB per `(rev, system)`. Revisit if a `cache get` is ever
  observed failing on an old revision.
- **`cadical`.** lean4-nix's manifests carry a pinned `cadical` in the manifest's
  own `overlay`, which upstream's `readBinaryToolchain` applies and a hand-rolled
  overlay can silently drop; the symptom is
  `could not execute external process 'cadical'` inside a `bv_decide` proof, far
  from the cause. *Mitigation:* the module applies `manifest.overlay`; verify on
  the TauCeti seed.
- **Release-candidate churn.** TauCeti's `v4.34.0-rc2` will move. *Mitigation:*
  `just lean-toolchain-fetch` makes regeneration a one-liner, and the eval-time
  refusal makes a stale manifest loud.

### Accepted risks

- **`lib.fakeHash` + a partial first fetch.** The fixed output hash is a total
  completeness check only *after* a hash exists. The first time one is minted, a
  partial fetch would bake in a wrong hash that then reproduces faithfully; the
  eventual mismatch reads as nondeterminism rather than as a bad recorded hash.
  Accepted deliberately: a separate assertion would restate a mechanism the
  system already enforces.
- **Upstream `v4.20.1.nix` has no `toolchain` attribute**, so "a manifest file
  exists" does not imply "a binary toolchain is available", and the raw failure is
  not `tryEval`-catchable. Refused explicitly by `loadManifest`, but it falsifies
  the invariant Decision 2 rests on. One of 28.

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

Nix supplies `elan`/`lean`/`lake`; Mathlib comes from Mathlib's own CI cache,
run by hand inside the shell.

- Pros: minutes instead of hours; byte-identical to what upstream and Prove2me's
  server build; nothing to vendor.
- Cons: impure; nothing Nix can cache or substitute; unusable for CI gating;
  leaves `~/.cache/mathlib` as mutable state.
- Why not chosen: **superseded rather than rejected.** Decision 5's FOD keeps
  every one of this alternative's benefits — it runs the same `cache get` — while
  making the result a pure derivation. Framing the choice as "fast and impure"
  versus "slow and pure" was the error; it is not a trade-off. Note the
  reproducibility that makes it work had to be *engineered* (the prune), not
  merely observed — the first measurement claiming it came for free was wrong.

### Alternative E — build Mathlib from source with `lake2nix.buildDeps`

The originally chosen path: `lake build` every dependency inside a derivation.

- Pros: no FOD hash to maintain; works for revisions with no upstream cache;
  no dependency on Mathlib CI's artifact retention.
- Cons: multi-hour per `(toolchain, rev)` pair, re-paid on every bump; large
  disk footprint; a second implementation of a build that Prove2me verifies
  against server-side, free to diverge.
- Why not chosen: the FOD is ~100× faster for an identical result. Retained as
  the fallback for revisions the upstream cache does not cover.

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

The executable plan lives on **jmmaloney4/jackpkgs#388**, with one spec sub-issue
per PR and an `implementation-plan v1` block. It is the single source of
sequencing truth; this section deliberately does not restate it.

Summary only: delete `pkgs/lean` (#389, merged as #386) · this ADR (#390) · the
module (#391) · a Mathlib-free CI fixture (#392) · garden pin bump (#393) ·
TauCeti seed (#394) · Prove2me as a consumer (#395).

Two nodes from the original sketch are gone. A **`mkVersoSite` genre builder** is
deferred until garden#1997 — *is verso-blueprint the project model?* — closes;
Verso remains usable as an ordinary lake dependency in the devShell, and the
lattice map (garden#1988) records verso-blueprint as single-author and
per-commit unstable, pinned by SHA not version string. **attic seeding on
itachi** is dropped: its justification was amortising a multi-hour source build,
and Decision 5 removed that cost.

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
