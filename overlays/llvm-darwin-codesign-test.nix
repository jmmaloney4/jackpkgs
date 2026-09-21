# Drop LLVM 23's `dsymutil/codesign.test` on darwin.
#
# The test runs `dsymutil --codesign=-`, which shells out to `codesign`. A nix
# builder's PATH is assembled from its inputs and never includes /usr/bin, so
# the tool is absent regardless of sandboxing and the test fails:
#
#     error: codesign not found: No such file or directory
#
# The usual nixpkgs remedy -- adding `darwin.sigtool`, which ships a `codesign`
# shim -- does NOT work here. Upstream states why: the test signs a *bundle*,
# and sigtool cannot sign bundles.
#
# Rationale and the rules this file follows: ADR 050.
#
# Upstream fix: NixOS/nixpkgs#552246 (reckenrode), open since 2026-08-13 with
# one approval and green CI, still unmerged. Hydra hits the same failure
# (build 344126987), which is why llvm 23 for aarch64-darwin is absent from
# cache.nixos.org -- the missing cache and the build failure are one bug, and
# it is why a consumer faces "N derivations to build, 0 to fetch".
#
# REMOVAL CONDITION: delete this file, its flake.nix export, and the consumer's
# overlay entry once the pinned nixpkgs contains #552246. Detect with:
#     nix eval --raw <nixpkgs>#legacyPackages.aarch64-darwin.llvmPackages_23.libllvm.drvPath
# and confirm the derivation builds without this overlay.
#
# Two deliberate constraints:
#
#   * DARWIN ONLY, conditioned on a VALUE not an attribute NAME. `postPatch` is
#     part of the derivation, so applying this unconditionally would change
#     llvm 23's drv hash on Linux too and invalidate every cached path
#     downstream of it -- to fix a test that only fails on darwin. Upstream can
#     afford to be unconditional because Hydra rebuilds everything; we cannot.
#     On non-darwin this returns `prev.libllvm` unchanged, so the hash is
#     untouched by construction rather than by luck.
#
#   * NO name-level platform filtering. `llvmPackages_23` and `libllvm` are
#     always defined; only the value varies. Choosing which attribute *names*
#     an overlay exports based on package values is what caused the infinite
#     recursion in jackpkgs#384 -- see the note in overlay.nix.
#
# Scope: one test of 77,248. `checkPhase` stays enabled. Note that
# `llvmPackages_23` is NOT the darwin stdenv's llvm (that is llvmPackages 21),
# so this does not perturb the stdenv.
final: prev: {
  # `overrideScope`, not `extend`: llvmPackages is built by mkLLVMPackages and
  # exposes overrideScope/override/callPackage, but no `extend`.
  llvmPackages_23 = prev.llvmPackages_23.overrideScope (
    _llvmFinal: llvmPrev: {
      libllvm =
        if prev.stdenv.hostPlatform.isDarwin
        then
          llvmPrev.libllvm.overrideAttrs (old: {
            postPatch =
              (old.postPatch or "")
              + ''
                rm -f test/tools/dsymutil/codesign.test
              '';
          })
        else llvmPrev.libllvm;
    }
  );
}
