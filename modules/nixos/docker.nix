# jackpkgs.docker — docker with auto-prune, the CLI and compose on PATH, and
# the operator account (jackpkgs.user) in the `docker` group.
# Promoted from garden `nixfiles/modules/nixos/docker.nix`.
{
  config,
  lib,
  pkgs,
  ...
}: let
  userCfg = config.jackpkgs.user;
in {
  imports = [../common/user.nix];

  options.jackpkgs.docker.enable = lib.mkEnableOption "docker (auto-pruned) with the jackpkgs operator account in the docker group";

  config = lib.mkIf config.jackpkgs.docker.enable {
    virtualisation.docker = {
      enable = true;
      autoPrune.enable = true;
    };

    users.groups.docker.members = lib.mkIf userCfg.enable [userCfg.username];

    environment.systemPackages = [pkgs.docker pkgs.docker-compose];
  };
}
