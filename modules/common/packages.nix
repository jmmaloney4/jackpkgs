# jackpkgs.packages — the fleet's base system package set (ADR-050 fleet
# glue; taste, so the list itself is not an option).
#
# Promoted from garden `nixfiles/modules/common/packages.nix` (garden#2074
# Part B PR 2), minus `inputs.deploy…deploy-rs`. ADR-050 Decision 3 planned a
# consumer-side `nullOr package` option for it; that option would be exactly
# as wide as `environment.systemPackages` and hide nothing, so it is not
# minted. A consumer that wants deploy-rs on PATH adds it to
# `environment.systemPackages` from its own `deploy` input.
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.jackpkgs.packages.enable = lib.mkEnableOption "jackpkgs' base system package set";

  config = lib.mkIf config.jackpkgs.packages.enable {
    environment.systemPackages = with pkgs; [
      anki-bin
      git
      git-annex
      python3
      speedtest-rs
      vim
      wezterm
    ];
  };
}
