# jackpkgs.user — the fleet's primary operator account (ADR-050 fleet glue).
#
# Declares WHICH account the other jackpkgs modules attach to (nix
# trusted-users, docker group membership). It does not create the account;
# that is the consumer's (or a later profile's) job.
#
# Promoted from garden `nixfiles/modules/common/user.nix` (garden#2074 Part B
# PR 2). The garden default (`"jack"`) is identity, so per ADR-050 Decision 4
# `username` has no default: enabling the module without naming the account
# fails at eval with "option … used but not defined" wherever it is read.
{lib, ...}: let
  inherit (lib) mkEnableOption mkOption types;
in {
  options.jackpkgs.user = {
    enable = mkEnableOption "the jackpkgs primary operator account (attached to by nix trusted-users and docker group membership)";

    username = mkOption {
      type = types.str;
      example = "alice";
      description = ''
        Name of the primary operator account. Required when
        `jackpkgs.user.enable` is set — there is deliberately no default, since
        an account name is identity (ADR-050 Decision 4).

        This module only names the account; create it yourself with
        `users.users.<name>`.
      '';
    };
  };
}
