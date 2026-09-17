# Verifies that jackpkgs' two non-flake registration points are usable as
# ordinary nixpkgs overlays:
#
#   * `overlay.nix`          (exported as `flake.overlays.default`)
#   * `overlays/default.nix` (consumed as `(import ./overlays).default`)
#
# Why this exists: `flake.nix` builds `packages.<system>` from its own
# `allPackages` binding and never applies either overlay, so a package
# registered wrongly in one of these two files was evaluated by nothing at all.
# #384 was exactly that failure -- both overlays infinite-recursed for every
# package while `nix build .#<pkg>` stayed green, and a second defect
# (`gemini-proxy` resolving `callPackage` against a scope with no `bun2nix`)
# was hiding behind it.
#
# Shape of the assertion. An infinite recursion is NOT catchable by
# `builtins.tryEval` -- it propagates -- so this cannot be written as "assert
# that evaluating the overlay succeeds". Instead the forced values are
# interpolated into the check derivation, which makes the failure mode *be* a
# failed evaluation of `checks`: `nix flake check` goes red with the recursion
# trace rather than quietly passing.
#
# It is deliberately a total assertion over every attribute each overlay
# defines, not a hand-picked sample. A sample is a denylist by omission: the
# next wrongly-registered package is precisely the one nobody thought to add.
{
  inputs,
  lib,
  pkgs,
  system,
}: let
  base = import inputs.nixpkgs {inherit system;};

  # Sentinels guard against the inverse failure -- an overlay that exports
  # nothing, or from which a package was silently dropped, would otherwise
  # satisfy a "force everything you export" check vacuously. These three are
  # registered in both overlay files and carry
  # `meta.platforms = linux ++ darwin`, so the list needs no per-system
  # special-casing.
  sentinels = ["tod" "mcp-ynab" "tauceti-progress"];

  checkOverlay = drvName: label: overlay: let
    overlaid = import inputs.nixpkgs {
      inherit system;
      overlays = [overlay];
    };

    # Exactly the attribute names this overlay defines. Applying the overlay
    # function directly is what makes the set total: a set-difference against
    # plain nixpkgs would silently skip every attribute that *shadows* an
    # existing nixpkgs package (csharpier, biome, docfx).
    definedNames = builtins.attrNames (overlay overlaid base);

    missingSentinels = lib.subtractLists definedNames sentinels;

    # Forcing `.name` runs each package's `callPackage` application to
    # completion, which is what catches a wrong registration -- an unresolvable
    # argument aborts right here. It stops deliberately short of `.drvPath`:
    # now that the overlays no longer platform-filter, an attribute whose
    # `meta.platforms` excludes the evaluating system is expected to be
    # present-but-unbuildable (nixpkgs' `checkMeta` reports that at build
    # time), and demanding buildability would make this check system-dependent.
    forced =
      map (
        n: let
          v = overlaid.${n};
        in
          if lib.isDerivation v
          then "${n} = ${v.name}"
          else "${n} = <not a derivation>"
      )
      definedNames;
  in
    assert lib.assertMsg (missingSentinels == [])
    "overlay ${label} does not export ${toString missingSentinels}; every package must be registered in all three of flake.nix, overlay.nix and overlays/default.nix";
      pkgs.runCommand drvName {} ''
        echo 'every attribute defined by ${label} resolved:'
        cat <<'RESOLVED'
        ${lib.concatStringsSep "\n" forced}
        RESOLVED
        touch "$out"
      '';
in {
  overlay-nix = checkOverlay "overlay-nix-resolves" "overlay.nix" (import ../overlay.nix inputs);
  overlays-default-nix = checkOverlay "overlays-default-nix-resolves" "overlays/default.nix" (import ../overlays).default;
}
