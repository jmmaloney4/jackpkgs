# NixOS half of jackpkgs.profile (ADR-051). The option surface and the
# cross-platform baseline live in ../common/profile.nix; this adds what only
# NixOS has:
#
#   * the Home Manager NixOS module (`home-manager.users.*`), which the account
#     modules (`jackpkgs.{operator,build-user}`) write to -- so a NixOS consumer
#     importing `nixosModules.profile` needs no separate Home Manager import;
#   * the locale baseline (en_US.UTF-8, `mkDefault`), promoted from garden
#     `nixfiles/profiles/i18n.nix`.
#
# A function of the flake `inputs` (applied in ./modules.nix) for the Home
# Manager module. Importing is inert: both the baseline and the locale are
# gated on `jackpkgs.profile.enable`.
inputs: {
  config,
  lib,
  ...
}: let
  inherit (lib) mkDefault mkIf;
  locale = "en_US.UTF-8";
in {
  # A key makes the module dedupe when a consumer imports `default` and
  # `profile` together (same reason as ./agenix.nix).
  key = "jackpkgs/nixos/profile";

  imports = [
    ../common/profile.nix
    inputs.home-manager.nixosModules.home-manager
  ];

  config = mkIf config.jackpkgs.profile.enable {
    i18n.defaultLocale = mkDefault locale;
    i18n.extraLocaleSettings = mkDefault (lib.genAttrs [
        "LC_ADDRESS"
        "LC_IDENTIFICATION"
        "LC_MEASUREMENT"
        "LC_MONETARY"
        "LC_NAME"
        "LC_NUMERIC"
        "LC_PAPER"
        "LC_TELEPHONE"
        "LC_TIME"
      ]
      (_: locale));
  };
}
