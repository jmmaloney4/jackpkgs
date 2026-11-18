# Per-package `nix flake check` derivations for `packages.<system>`.
#
# Each check reuses the same derivation as `packages.<system>.<name>` so the Nix
# store deduplicates work with `nix build .#<name>` and any other check that
# references the package (e.g. `checks.gawkbot`).
{
  lib,
  pkgs,
  packages,
}: let
  hostPlatform = pkgs.stdenv.hostPlatform;

  # Packages intentionally omitted from merge-gate package builds.
  packagesBuildCheckExclusions = [
    # Parked: jackpkgs#427 (nautilus-trader 2.0 maturin/uv; not in `packages.*` today).
    "nautilus-trader"
  ];

  shouldBuildPackage = name: drv:
    !(builtins.elem name packagesBuildCheckExclusions)
    && lib.isDerivation drv
    && lib.meta.availableOn hostPlatform drv
    && !(drv.meta.broken or false)
    # jackpkgs convention: meta.unsupported mirrors broken for platform-specific skips.
    && !(drv.meta.unsupported or false);

  buildable = lib.filterAttrs shouldBuildPackage packages;
in
  lib.mapAttrs' (name: drv: lib.nameValuePair "pkg-${name}" drv) buildable
