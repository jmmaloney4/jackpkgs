# jackpkgs.build-user — a remote-build account (ADR-051 fleet glue).
# Promoted from garden `nixfiles/profiles/plato.nix` (`jmmaloney4.buildUser`).
#
# Creates the account, gives it the minimal Home Manager profile
# (`homeModules.build-user`) and authorizes the operator's SSH keys on it (and
# on root, as in garden). The account name is identity, so `username` has no
# default (ADR-051 Decision 4); garden's `plato` is its consumer's value.
#
# Requires the Home Manager NixOS / nix-darwin module: `nixosModules.build-user`
# imports the NixOS one itself; a nix-darwin consumer imports home-manager's
# darwin module (jackpkgs has no nix-darwin input).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.jackpkgs.build-user;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
in {
  imports = [./ssh.nix];

  options.jackpkgs.build-user = {
    enable = mkEnableOption "the remote-build account with a minimal Home Manager profile";

    username = mkOption {
      type = types.str;
      example = "builder";
      description = "Name of the build account. Required when `jackpkgs.build-user.enable` is set: no default, an account name is identity (ADR-051 Decision 4).";
    };
  };

  config = mkIf cfg.enable {
    users.users.${cfg.username} =
      {
        description = "Build Machine User";
        shell = pkgs.bash;
      }
      // (
        if isLinux
        then {
          isNormalUser = true;
          extraGroups = ["wheel"];
        }
        else {}
      );

    home-manager.users.${cfg.username} = {
      imports = [../home-manager/build-user.nix];
      jackpkgs.build-user.enable = true;
    };

    # Allow SSH access for the build user and root.
    jackpkgs.ssh.authorizedKeysUsers = ["root" cfg.username];
  };
}
