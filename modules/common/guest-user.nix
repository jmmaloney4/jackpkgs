# jackpkgs.guest-user — a shell-access guest account with its own SSH keys
# (ADR-051 fleet glue). Promoted from garden `nixfiles/profiles/charles.nix`
# (`jmmaloney4.charles`), generalised from one named person to "a guest".
#
# Account only -- deliberately no `home-manager.users.<name>`. The guest
# manages their own $HOME with *standalone* Home Manager from their own flake;
# wiring a config through the NixOS Home Manager module as well would fight
# standalone Home Manager over the same generation symlinks.
#
# Name, uid and keys are all identity/topology, so none has a default
# (ADR-051 Decision 4). The uid is pinned so it matches on every host that
# enables the account (an auto-allocated uid drifts between hosts, which
# breaks anything keyed on it such as NFS or file ownership).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.jackpkgs.guest-user;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
in {
  imports = [./zsh.nix];

  options.jackpkgs.guest-user = {
    enable = mkEnableOption "a guest account with shell access (no sudo) and its own SSH keys";

    username = mkOption {
      type = types.str;
      example = "carol";
      description = "Name of the guest account. Required when enabled: no default (ADR-051 Decision 4).";
    };

    uid = mkOption {
      # 500 floor: macOS accounts start at 501. On Linux, NixOS itself refuses
      # an isNormalUser account below 1000, so no second check lives here.
      type = types.ints.between 500 65533;
      example = 1002;
      description = ''
        Pinned uid, identical on every host that enables the account. Required:
        no default, because the right value depends on which uids the rest of
        the fleet already uses.
      '';
    };

    authorizedKeys = mkOption {
      # nonEmptyListOf, not listOf: an undefined `listOf` option silently
      # evaluates to `[]`, leaving a guest who cannot log in (ADR-051 Decision 3).
      type = types.nonEmptyListOf types.str;
      example = ["ssh-ed25519 AAAAC3Nza… carol"];
      description = "SSH public keys granting access to the guest account. Required: no default, a key is identity.";
    };
  };

  config = mkIf cfg.enable {
    # Login shell is zsh; NixOS refuses that unless system zsh is enabled.
    jackpkgs.zsh.enable = lib.mkDefault true;

    users.users.${cfg.username} =
      {
        description = "Guest account (${cfg.username})";
        shell = pkgs.zsh;
        inherit (cfg) uid;
        # Keys go directly on the account. Do NOT add this user to
        # jackpkgs.ssh.authorizedKeysUsers -- that option authorizes the
        # operator's keys on every listed account.
        openssh.authorizedKeys.keys = cfg.authorizedKeys;
      }
      // (
        if isLinux
        then {
          isNormalUser = true;
          # No wheel: shell access, not sudo.
          extraGroups = [];
        }
        else {}
      );
  };
}
