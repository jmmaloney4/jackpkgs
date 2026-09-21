# Enforces the invariant that makes `overlays/llvm-darwin-codesign-test.nix`
# safe to ship (ADR 050): it must change llvm 23 on darwin and leave every
# other platform byte-identical.
#
# Why this is not covered by tests/overlays.nix: that harness is for the
# package-export overlays. It forces `.name` on every attribute and asserts a
# set of sentinel packages, which a patch overlay -- defining one non-derivation
# scope and no packages -- cannot satisfy. More to the point, "does it resolve"
# is the wrong question here. The failure worth catching is a *silent* one: an
# edit that drops the platform condition still resolves perfectly, and merely
# invalidates llvm and everything downstream of it on Linux.
#
# Both assertions are evaluated regardless of which system runs the check.
# Computing a `drvPath` for another platform is pure evaluation and needs no
# darwin builder, so the invariant is system-independent rather than only
# being tested on whichever machine happens to run CI.
{
  inputs,
  lib,
  pkgs,
  ...
}: let
  overlay = import ../overlays/llvm-darwin-codesign-test.nix;

  # `unsafeDiscardStringContext` is load-bearing, not a tidy-up. A `drvPath`
  # carries string context, so interpolating one into the report below would
  # make this check *depend* on that derivation -- and a darwin drv cannot be
  # built on a Linux runner ("platform mismatch"), turning a pure evaluation
  # test into an unbuildable one. Comparing the strings creates no dependency;
  # only interpolation does. Discarding context keeps the assertions exact
  # while leaving the check buildable anywhere, which is the entire point of
  # testing a cross-platform invariant.
  drvPathOf = attrPath: system: overlays:
    builtins.unsafeDiscardStringContext (
      lib.getAttrFromPath attrPath (import inputs.nixpkgs {inherit system overlays;})
    );

  libllvm = ["llvmPackages_23" "libllvm" "drvPath"];
  lld = ["llvmPackages_23" "lld" "drvPath"];

  darwin = "aarch64-darwin";
  linux = "x86_64-linux";

  darwinBase = drvPathOf libllvm darwin [];
  darwinPatched = drvPathOf libllvm darwin [overlay];
  linuxBase = drvPathOf libllvm linux [];
  linuxPatched = drvPathOf libllvm linux [overlay];

  # Dependents must follow the patched libllvm through the scope. If this ever
  # stops moving while libllvm does, `overrideScope` has degenerated into a
  # leaf-level override and the closure now carries two divergent llvms.
  lldDarwinBase = drvPathOf lld darwin [];
  lldDarwinPatched = drvPathOf lld darwin [overlay];
in
  assert lib.assertMsg (darwinBase != darwinPatched)
  "llvm-darwin-codesign-test overlay is a no-op on ${darwin}: libllvm is still ${darwinBase}. The patch is not reaching llvmPackages_23.";
  assert lib.assertMsg (linuxBase == linuxPatched)
  "llvm-darwin-codesign-test overlay changed llvm on ${linux} (${linuxBase} -> ${linuxPatched}). postPatch is part of the derivation, so this invalidates every cached path downstream of llvm on a platform the bug does not affect. The patch must stay conditioned on a value, per ADR 050.";
  assert lib.assertMsg (lldDarwinBase != lldDarwinPatched)
  "llvm-darwin-codesign-test patched libllvm but lld did not follow (${lldDarwinBase}). overrideScope must rebuild the scope; a leaf override would leave dependents on the unpatched llvm.";
    pkgs.runCommand "llvm-darwin-codesign-overlay-invariants" {} ''
      cat <<'RESULT'
      aarch64-darwin libllvm: ${darwinBase}
                           -> ${darwinPatched}   (changed, as required)
      x86_64-linux   libllvm: ${linuxBase}       (unchanged, as required)
      aarch64-darwin lld    : ${lldDarwinBase}
                           -> ${lldDarwinPatched} (follows libllvm)
      RESULT
      touch "$out"
    ''
