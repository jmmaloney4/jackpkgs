# jackpkgs.profile — the fleet baseline: turns on the shared module set for a
# host (ADR-051 fleet glue). Promoted from garden `nixfiles/profiles/default.nix`.
#
# Enabling it `mkDefault`-enables `jackpkgs.{user,fonts,nix,nix.substituters,
# attic,ssh,tailscale}` and authorizes the operator's keys on root. That makes
# their required options (`jackpkgs.user.username`, `jackpkgs.ssh.authorizedKeys`,
# `jackpkgs.attic.{endpoint,pullCaches}`) required of the host too -- this is by
# design: a host on the profile that has not named its operator or cache fails
# at eval instead of coming up half-configured. Every default is `mkDefault`,
# so a host opts one module back out with `jackpkgs.<name>.enable = false`.
#
# NOT here, deliberately: the time zone (a per-host fact), the garden-specific
# Home Manager defaults the original also set (`jmmaloney4.{vscode,gui}`), and
# the account profiles (`jackpkgs.{operator,build-user,guest-user}`), which a
# host enables individually.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkDefault mkEnableOption mkIf;
in {
  imports = [
    ./attic.nix
    ./fonts.nix
    ./nix.nix
    ./ssh.nix
    ./tailscale.nix
    ./user.nix
  ];

  options.jackpkgs.profile.enable = mkEnableOption "the jackpkgs fleet baseline (user, fonts, nix, attic, ssh, tailscale enabled by default)";

  config = mkIf config.jackpkgs.profile.enable {
    jackpkgs = {
      user.enable = mkDefault true;
      fonts.enable = mkDefault true;
      nix.enable = mkDefault true;
      nix.substituters.enable = mkDefault true;
      attic.enable = mkDefault true;
      ssh.enable = mkDefault true;
      ssh.authorizedKeysUsers = ["root"];
      tailscale.enable = mkDefault true;
    };
  };
}
