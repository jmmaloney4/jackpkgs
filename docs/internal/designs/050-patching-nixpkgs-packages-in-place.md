---
id: ADR-050
title: Patching Nixpkgs Packages In Place
status: accepted
date: 2026-09-20
---

# ADR 050: Patching Nixpkgs Packages In Place

## Status

Accepted

## Context

ADR 044 covers one half of "nixpkgs is wrong for us": a package is **too old**,
so jackpkgs ships a newer standalone derivation under `pkgs/<name>/`. It says
nothing about the other half — a package at the **right version** that is
**broken for us**, where the correct fix already exists upstream but has not
merged.

### Triggering case

`llvmPackages_23.libllvm` cannot build on aarch64-darwin. One test of 77,248
fails, after 51 minutes of testing:

```
FAIL: LLVM :: tools/dsymutil/codesign.test
# | error: codesign not found: No such file or directory
```

The test runs `dsymutil --codesign=-`, which shells out to `codesign`. A nix
builder's `PATH` is assembled from its inputs and never includes `/usr/bin`, so
the tool is absent **regardless of sandboxing** — confirmed on a host with
`sandbox = false` and `/usr/bin/codesign` present.

The reflexive nixpkgs remedy, adding `darwin.sigtool` (which ships a `codesign`
shim), does **not** work. Upstream states why: the test signs a *bundle*, and
sigtool cannot sign bundles.

### The fix exists upstream and is stuck

[NixOS/nixpkgs#552246](https://github.com/NixOS/nixpkgs/pull/552246) by
reckenrode, a nixpkgs darwin maintainer — opened 2026-08-13, one approval, CI
green, **still unmerged 5+ weeks later**, and not on master as of
`1ede3c6f9` (2026-09-20). It deletes the test for `release_version >= 23`.

Bumping our pin does not help: our nixpkgs is `c7def046b` (2026-09-14) and the
fix is in neither that nor master.

### This also explains missing cache coverage

A comment on that PR (2026-09-09) reports the test still failing in **Hydra**
([build 344126987](https://hydra.nixos.org/build/344126987)). Hydra cannot build
llvm 23 on aarch64-darwin either, so nothing lands in `cache.nixos.org`. A
consumer therefore sees `510 derivations will be built, 0 fetched` — the absent
cache and the build failure are **one bug**, not two. Any attempt to "just
substitute around it" is chasing an artefact of the same defect.

### The constraint that shapes the decision

`postPatch` is part of the derivation. Applying upstream's hunk verbatim —
gated on version only, as upstream has it — changes llvm 23's derivation hash
on **Linux too**, invalidating every cached path downstream of it, to fix a test
that only fails on darwin. Upstream can afford to be unconditional because Hydra
rebuilds the world; jackpkgs consumers cannot.

### Delivery is not automatic, contrary to ADR 044

ADR 044 asserts overrides reach consumers "simultaneously through the overlay".
That does not hold today. The principal consumer, `garden`, applies **no**
jackpkgs overlay at all — verified: no match for `jackpkgs.overlays` anywhere in
its tree, and its overlay list (`nixfiles/default.nix`) does not include one. It
consumes jackpkgs by explicit package reference
(`inputs.jackpkgs.packages.${system}.<name>`), which delivers *packages* but can
never replace an attribute like `pkgs.llvmPackages_23` in the consumer's own
package set.

So for an in-place patch there are exactly two delivery mechanisms: the consumer
applies an overlay, or jackpkgs patches the nixpkgs **input** every consumer
already follows (`nixpkgs.follows = "jackpkgs/nixpkgs"`).

## Decision

jackpkgs MAY patch an existing nixpkgs package in place. When it does:

1. The patch MUST live in its own file under `overlays/` and be exported as a
   **separately named** flake overlay — NOT folded into `overlays.default`.
   `default` is the NUR-style package overlay; mutating third-party attributes
   is a different hazard class and consumers must opt in knowingly.
2. The patch MUST be conditioned on a **value**, never on an attribute **name**.
   Selecting which names an overlay exports from package values is what caused
   the infinite recursion in jackpkgs#384; and a name-level condition would make
   the attribute vanish on other platforms rather than pass through unchanged.
3. The patch MUST be platform-scoped so that unaffected platforms keep
   byte-identical derivation hashes, and this MUST be demonstrated by evaluating
   `drvPath` on both an affected and an unaffected system.
4. The file MUST document the upstream fix (PR/issue), why the idiomatic remedy
   does not apply, and an explicit **removal condition**.
5. jackpkgs MUST NOT fork its `nixpkgs` input to carry the patch. See
   Alternative A.

### Scope

In scope: correcting a package jackpkgs' pinned nixpkgs gets wrong, where a fix
exists upstream but is unmerged.

Out of scope: version bumps (ADR 044); carrying features nixpkgs has rejected;
anything intended to be permanent.

## Consequences

### Benefits

- The fix is written once and available to every consumer on one opt-in line.
- Unaffected platforms are untouched **by construction** — the non-darwin branch
  returns `prev.libllvm`, the same value, so the hash cannot drift by accident.
- `overrideScope` propagates through the scope, so dependents (`lld`, `clang`,
  the bintools wrappers) pick up the patched `libllvm` rather than a second
  divergent llvm appearing alongside the first.
- Self-limiting: a named overlay with a removal condition is trivially greppable
  at bump time, unlike a patched input.

### Trade-offs

- Opt-in, not automatic. Each consumer adds a line, and a consumer that does not
  will still fail. Accepted deliberately: the alternative that *is* automatic is
  strictly worse (Alternative A).
- The override duplicates upstream's intent in our own idiom rather than being a
  literal cherry-pick, so it must be re-read — not merely rebased — if upstream's
  approach changes.

### Risks & Mitigations

- **Risk:** the overlay outlives the upstream fix and silently diverges.
  - **Mitigation:** removal condition names the exact command that decides it.
- **Risk:** patching a scope forks it, yielding two llvms and a doubled closure.
  - **Mitigation:** `overrideScope` (not `//`, not a bare `overrideAttrs` on the
    leaf) — verified by observing `lld`'s `drvPath` move with `libllvm`'s.
- **Risk:** skipping a test hides a real defect.
  - **Mitigation:** exactly one test of 77,248 is removed; `checkPhase` stays
    enabled. What it exercises is `dsymutil`'s ability to sign a *bundle*, which
    nothing in our closure does.

## Alternatives Considered

### Alternative A — Point `jackpkgs.inputs.nixpkgs` at a patched fork

- Pros: genuinely automatic. Every consumer already does
  `nixpkgs.follows = "jackpkgs/nixpkgs"`, so a fork branch carrying the
  cherry-pick would reach all of them with zero consumer changes. This is the
  most literal reading of "fix it at the jackpkgs level".
- Cons: a nixpkgs fork branch to rebase on every unstable bump, forever, for a
  fix whose entire purpose is to disappear. It still needs the darwin gate, so
  it is not even simpler. A mis-rebase silently changes the package set for every
  consumer at once, with no greppable marker in any consumer repo.
- Why not chosen: highest reach, worst failure mode, and unbounded maintenance
  for a temporary defect.

### Alternative B — Fold into `overlays.default`

- Pros: consumers already applying `overlays.default` would get it free.
- Cons: `overlays.default` is a package-export overlay; adding third-party
  attribute mutation to it makes applying jackpkgs' packages silently mutate
  unrelated parts of the consumer's package set. Also does not help garden,
  which applies no jackpkgs overlay at all.
- Why not chosen: conflates two hazard classes in one attribute.

### Alternative C — Standalone derivation under `pkgs/`, per ADR 044

- Pros: matches existing precedent.
- Cons: ADR 044's pattern replaces a package *by name* (`pkgs.biome`). llvm is
  consumed through a scope whose internal references must also update; a
  standalone `pkgs/llvm` would not be what `llvmPackages_23.lld` builds against.
- Why not chosen: wrong shape for a scoped package set, and copying llvm's
  derivation to change one `rm` is grossly disproportionate.

### Alternative D — Wait for #552246

- Pros: zero work.
- Cons: open 5+ weeks with an approval and green CI; no merge signal. Meanwhile
  darwin hosts cannot complete any `darwin-rebuild`.
- Why not chosen: indefinite, and it blocks unrelated deploys.

## Implementation Plan

- [x] `overlays/llvm-darwin-codesign-test.nix` — `overrideScope` on
  `llvmPackages_23`, darwin-conditioned by value.
- [x] Export as `overlays.llvm-darwin-codesign-test` in `flake.nix`.
- [x] Verify the derivation actually changes on darwin and **not** on Linux.
- [x] `tests/llvm-darwin-codesign.nix` — assert that invariant as a flake check,
  and confirm it *fails* when the platform condition is removed.
- [x] Build the patched derivation on real aarch64-darwin hardware.
- [x] Use `rm`, not `rm -f`, so the overlay fails loudly once upstream removes
  the test itself — the removal condition enforces itself rather than relying on
  someone noticing. (Raised in review on PR #407.)
- [ ] Consumer side: garden adds the overlay to `nixfiles/default.nix`.
- [ ] Remove when the pinned nixpkgs carries #552246.

### Verification evidence

Evaluated against `nixpkgs c7def046b`, `llvmPackages_23.libllvm.drvPath`:

| System           | Baseline                           | With overlay                       |               |
| ---------------- | ---------------------------------- | ---------------------------------- | ------------- |
| `aarch64-darwin` | `c64rvn1m2vq3w5y15k00hp6vxjv441xr` | `k3jaypfgiw28qbhqq2kzmmw3sbxklgyq` | changed       |
| `x86_64-linux`   | `l2ky695v1a9sm5pnidk5srjcmdl5dasb` | `l2ky695v1a9sm5pnidk5srjcmdl5dasb` | **identical** |

The darwin baseline is the exact derivation observed failing on the affected
host. Scope propagation confirmed separately:
`llvmPackages_23.lld.drvPath` moves `032gfx5a…` → `h91z97kl…`, so dependents
follow the patched `libllvm` instead of a second llvm being introduced.

`llvmPackages_23` is **not** the darwin stdenv's llvm — that is
`llvmPackages` at 21.1.8 — so the stdenv is unperturbed.

**Built on real hardware.** A `drvPath` comparison shows only that the patch is
*applied*; it cannot show that the result builds. The patched derivation was
therefore built on an aarch64-darwin host:

```
PATCHED_BUILD_EXIT=0        21:01:51 -> 21:42:48 (41 min)
codesign.test occurrences:  0
Total Discovered Tests:     77247
```

Baseline discovers 77,248 tests and fails one; patched discovers 77,247 and
fails none. Exactly one test is removed and nothing else is perturbed.

**The check is proven to fail.** Replacing the platform condition with `true`
makes it red with the specific regression it exists to catch:

```
llvm-darwin-codesign-test overlay changed llvm on x86_64-linux
  (l2ky695v... -> s69lwv5v...)
```

One trap worth recording for anyone writing a similar check: interpolating a
`drvPath` into the report carries **string context**, which makes the check
*depend* on that derivation — so a darwin path makes it unbuildable on a Linux
runner (`platform mismatch`). Comparing the strings creates no dependency; only
interpolation does. `builtins.unsafeDiscardStringContext` is load-bearing there,
not cosmetic.

### Rollback

Delete `overlays/llvm-darwin-codesign-test.nix`, its `flake.nix` export, and the
consumer's overlay entry. Nothing else references it.

## Related

- Supersedes ADR 025 (*Overlay Package Patching Pattern*), an abandoned stub
  whose "related PR" link points at an unrelated merged PR.
- Complements ADR 044 (*Nixpkgs Package Override Pattern*): 044 replaces a
  package that is too **old**; 049 patches one that is **broken**. 044's claim
  that overrides reach consumers "simultaneously through the overlay" is
  corrected here — garden applies no jackpkgs overlay.
- Upstream: [NixOS/nixpkgs#552246](https://github.com/NixOS/nixpkgs/pull/552246)
- jackpkgs#384 — the overlay recursion that motivates constraint 2.

______________________________________________________________________

Author: Claude
Date: 2026-09-20
PR: #<pending>
