# jackpkgs.ssh — sshd enablement plus authorized-key fan-out (ADR-050 fleet glue).
#
# Promoted from garden `nixfiles/modules/common/ssh.nix` (garden#2074 Part B
# PR 2), with the two defects ADR-050 Decision 4 names fixed:
#
#   * The operator's literal public key is no longer hardcoded: it is the
#     required option `authorizedKeys` (no default — identity).
#   * The fan-out is now gated on `enable`. In garden it ran unconditionally.
#
# And one the inventory missed: garden wrote
#   services.openssh = mkIf cond {enable = true;} // {settings = …;};
# `//` binds looser than function application, so `settings` was merged
# into the *mkIf wrapper* attrset, where the module system ignores it. The
# hardening below (PasswordAuthentication off, root by key only) was
# therefore never applied on any garden host. It is applied here, which is
# a behaviour change for adopters — see the jackpkgs PR body.
#
# Platform-agnostic: the `options ?` guards keep it importable from
# nix-darwin, whose openssh option surface differs.
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  inherit (lib) genAttrs mkDefault mkEnableOption mkIf mkMerge mkOption optionalAttrs types;
  cfg = config.jackpkgs.ssh;
in {
  options.jackpkgs.ssh = {
    enable = mkEnableOption "sshd with key-only authentication, and the operator-key fan-out below";

    authorizedKeys = mkOption {
      # nonEmptyListOf, not listOf: an undefined `listOf` option silently
      # evaluates to `[]` (the type's emptyValue), so "no default" alone would
      # fan out zero keys instead of failing. nonEmptyListOf has no emptyValue,
      # so an unwired key list is an eval error, and `[]` is refused.
      type = types.nonEmptyListOf types.str;
      example = ["ssh-ed25519 AAAAC3Nza… alice@laptop"];
      description = ''
        Public keys installed as authorized keys for every account listed in
        `authorizedKeysUsers`. No default: an SSH key is identity (ADR-050
        Decision 4). Required as soon as `authorizedKeysUsers` is non-empty.
      '';
    };

    authorizedKeysUsers = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["root" "alice"];
      description = ''
        Accounts that receive `authorizedKeys`. Merges across modules, so a
        profile can add its own account without knowing about the others.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      users.users = genAttrs cfg.authorizedKeysUsers (_: {
        openssh.authorizedKeys.keys = cfg.authorizedKeys;
      });
    }

    (optionalAttrs (options ? services.openssh.enable) {
      services.openssh.enable = true;
    })

    (optionalAttrs (options ? services.openssh.settings) {
      services.openssh.settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = mkDefault false;
        AllowAgentForwarding = true;
      };
    })

    # nix-darwin's openssh settings don't reliably reach macOS's system sshd,
    # so write the drop-in directly.
    (mkIf pkgs.stdenv.hostPlatform.isDarwin {
      environment.etc."ssh/sshd_config.d/100-nix-darwin.conf".text = ''
        AllowAgentForwarding yes
      '';
    })
  ]);
}
