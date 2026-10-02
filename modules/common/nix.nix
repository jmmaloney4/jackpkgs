# jackpkgs.nix — opinionated nix daemon settings (ADR-050 fleet glue).
#
# Promoted from garden `nixfiles/modules/common/nix.nix` (garden#2074 Part B
# PR 2). Platform-agnostic: nothing here is NixOS-only. NixOS-only daemon
# housekeeping (gc, optimise, build users) lives in ../nixos/nix.nix, which
# imports this file.
#
# The substituter list is baked, not an option: these are public caches
# nobody varies (ADR-050 Decision 4). Private caches belong in
# `jackpkgs.attic`.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf optional optionalAttrs;
  cfg = config.jackpkgs.nix;
  userCfg = config.jackpkgs.user;

  substituters = [
    "https://cache.nixos.org"
    "https://nix-community.cachix.org"
    "https://install.determinate.systems"
  ];

  trusted-public-keys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM="
  ];
in {
  # trusted-users reads the operator account, so declare its options here
  # rather than making every consumer of nixosModules.nix know to import it.
  imports = [./user.nix];

  options.jackpkgs.nix = {
    enable = mkEnableOption "jackpkgs' nix daemon settings (flakes, lazy-trees, trusted-users)";
    substituters.enable = mkEnableOption "jackpkgs' public substituter set (cache.nixos.org, nix-community, FlakeHub)";
  };

  config = mkIf cfg.enable {
    nix.settings =
      {
        experimental-features = ["nix-command" "flakes"];
        max-jobs = "auto";
        # Determinate Nix setting; upstream Nix warns about it and moves on.
        lazy-trees = true;
        trusted-users = ["root"] ++ optional userCfg.enable userCfg.username;
      }
      // optionalAttrs cfg.substituters.enable {
        inherit substituters trusted-public-keys;
        trusted-substituters = substituters;
      };
  };
}
