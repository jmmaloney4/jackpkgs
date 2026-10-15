# jackpkgs.operator — the fleet's primary operator account, created and wired
# to Home Manager (ADR-051 fleet glue).
#
# Promoted from garden `nixfiles/profiles/jack.nix`. WHICH account is named by
# `jackpkgs.user.username` (modules/common/user.nix); this module creates it.
# The two are separate because `jackpkgs.user` is also read by modules that do
# not want an account created (nix trusted-users, docker group).
#
# Interface a consumer must know:
#   * `jackpkgs.user.username` -- the account name (identity, no default).
#   * `jackpkgs.operator.home.modules` -- the Home Manager modules for the
#     account (required, non-empty: an operator account with no Home Manager
#     configuration is not a state this module supports).
#   * `jackpkgs.operator.home.extraSpecialArgs` -- anything those modules take
#     as module arguments beyond the standard ones (garden passes `inputs`).
#     `hostname` is always supplied by this module, from `networking.hostName`.
#
# jackpkgs' own Home Manager modules (`homeModules.*`) are imported into the
# account automatically; they are inert until enabled.
#
# Not here (stays with the consumer): any host-specific Home Manager wiring
# (garden's `gardenSkillsHosts` skills-sync invariant moved to garden).
#
# Platform-agnostic: the Linux-only account attributes are guarded, uid
# differs per platform. Requires the Home Manager NixOS / nix-darwin module:
# `nixosModules.operator` imports the NixOS one itself; a nix-darwin consumer
# imports home-manager's darwin module (jackpkgs has no nix-darwin input).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkDefault mkEnableOption mkIf mkOption types;
  cfg = config.jackpkgs.operator;
  username = config.jackpkgs.user.username;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
in {
  imports = [./ssh.nix ./user.nix ./zsh.nix];

  options.jackpkgs.operator = {
    enable = mkEnableOption "creating the jackpkgs primary operator account (jackpkgs.user.username) with zsh, wheel access and Home Manager wiring";

    home = {
      modules = mkOption {
        # nonEmptyListOf, not listOf: an undefined `listOf` option silently
        # evaluates to `[]`, which would create an account with no Home Manager
        # configuration instead of failing (ADR-051 Decision 3).
        type = types.nonEmptyListOf types.deferredModule;
        example = lib.literalExpression "[ ./home/alice.nix ]";
        description = ''
          Home Manager modules for the operator account. Required when
          `jackpkgs.operator.enable` is set: no default, since what an account's
          home looks like is the consumer's. Must define `home.stateVersion`.
        '';
      };

      extraSpecialArgs = mkOption {
        type = types.attrs;
        default = {};
        example = lib.literalExpression "{ inherit inputs; }";
        description = ''
          Extra module arguments for the Home Manager modules, applied to
          `home-manager.extraSpecialArgs` (which is shared by every Home
          Manager user on the host, not just the operator). May be empty: a
          consumer whose modules need nothing extra passes nothing. May not
          contain `hostname`, which this module always provides.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        # nix-darwin's networking.hostName is nullOr str defaulting to null; a
        # null `hostname` specialArg would only fail far away, wherever a
        # consumer module interpolates it.
        assertion = config.networking.hostName != null;
        message = "jackpkgs.operator requires networking.hostName to be set: it is the source of the `hostname` specialArg for the operator's Home Manager modules (nix-darwin defaults it to null).";
      }
      {
        assertion = !(cfg.home.extraSpecialArgs ? hostname);
        message = "jackpkgs.operator.home.extraSpecialArgs must not define `hostname`: jackpkgs.operator supplies it from networking.hostName, and a second definition would silently win.";
      }
    ];

    users.users.${username} =
      {
        shell = pkgs.zsh;
        # mkDefault: a host whose operator account has another uid (a WSL
        # `nixos` user, say) just sets `users.users.<n>.uid`.
        uid = mkDefault (
          if isLinux
          then 1000
          else 501
        );
      }
      // (
        if isLinux
        then {
          isNormalUser = true;
          extraGroups = ["networkmanager" "wheel"];
        }
        else {
          # nix-darwin's `users.users.<n>.home` defaults to null, and Home
          # Manager's nix-darwin glue derives `home.homeDirectory` from it, so
          # without this the operator has no home directory on darwin. (The
          # NixOS default, /home/<n>, is derived by NixOS itself.)
          home = mkDefault "/Users/${username}";
        }
      );

    home-manager = {
      useGlobalPkgs = mkDefault true;
      useUserPackages = mkDefault true;
      extraSpecialArgs = cfg.home.extraSpecialArgs // {hostname = config.networking.hostName;};
      users.${username}.imports = [../home-manager] ++ cfg.home.modules;
    };

    # The account's login shell is zsh; NixOS refuses a zsh login shell
    # unless system zsh is enabled (it lacks the nix PATH entries otherwise).
    jackpkgs.zsh.enable = mkDefault true;

    jackpkgs.ssh.authorizedKeysUsers = [username];
  };
}
