# jackpkgs.attic — an Attic binary cache as a pull-only Nix substituter
# (ADR-050 fleet glue).
#
# Promoted from garden `nixfiles/modules/common/attic.nix` (garden#2074 Part B
# PR 2). Per ADR-050 Decision 4 the endpoint and the cache/key map are
# topology, so both are required options with no default: garden and seven
# each name their own cache.
#
# Garden's dormant `watchStore` push daemon (enabled on no host, inventory
# 2026-09-17) is NOT promoted: it is ~100 lines of secret-handling service
# code with zero consumers. It remains in garden's history if push is ever
# wanted; add it back here alongside its first real consumer.
#
# Platform-agnostic. NixOS reads `nix.settings`; darwin hosts running
# Determinate Nix read `determinateNix.customSettings`. A `mkIf false`
# definition for an undeclared option still raises "option does not exist",
# so the darwin branch is dropped structurally with `optionalAttrs
# (options ? determinateNix)` — `options ?` is safe here because option
# declarations resolve independently of config values (gating on `pkgs` at
# the structural level would infinitely recurse).
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  inherit (lib) attrValues mapAttrsToList mkAfter mkEnableOption mkIf mkMerge mkOption optionalAttrs optionalString types;
  cfg = config.jackpkgs.attic;

  # `attrsOf` has an emptyValue: left undefined it silently evaluates to `{}`,
  # which would enable the module with zero caches instead of failing. Like
  # nixpkgs' own `nonEmptyListOf`, drop the emptyValue (so an unwired map is
  # an eval error) and refuse `{}` outright. "Drop" means `emptyValue = {}`
  # with no `value` attribute: that is exactly what `nonEmptyListOf` sets, and
  # the module system then raises "used but not defined" (pinned by
  # testAtticPullCachesRequired in tests/nixos-modules.nix).
  nonEmptyAttrsOf = elemType: let
    attrs = types.addCheck (types.attrsOf elemType) (a: a != {});
  in
    attrs
    // {
      description = "non-empty ${attrs.description}";
      emptyValue = {};
    };

  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  # List order does not set substituter priority; `?priority=<n>` does
  # (lower = preferred; cache.nixos.org advertises 40).
  prioritySuffix = optionalString (cfg.priority != null) "?priority=${toString cfg.priority}";
  substituterUrls = mapAttrsToList (name: _key: "${cfg.endpoint}/${name}${prioritySuffix}") cfg.pullCaches;
  trustedKeys = attrValues cfg.pullCaches;

  # mkAfter: additive to any other substituter lists (jackpkgs.nix's public
  # set, consumer extras), appended after them.
  settings = {
    substituters = mkAfter substituterUrls;
    trusted-substituters = mkAfter substituterUrls;
    trusted-public-keys = mkAfter trustedKeys;
  };
in {
  options.jackpkgs.attic = {
    enable = mkEnableOption "an Attic binary cache as a pull-only Nix substituter";

    endpoint = mkOption {
      type = types.strMatching "^https?://[^/]+.*[^/]$";
      example = "https://attic.example.ts.net";
      description = ''
        Attic server base URL, without a trailing slash. Required when
        `jackpkgs.attic.enable` is set (no default — this is deployment
        topology, ADR-050 Decision 4).
      '';
    };

    pullCaches = mkOption {
      type = nonEmptyAttrsOf types.str;
      example = {
        mycache = "mycache:AAAA…=";
      };
      description = ''
        Map of Attic cache name to its NAR signing public key. Each entry
        becomes a substituter at `''${endpoint}/''${name}` plus a
        trusted-public-keys entry. Required when `jackpkgs.attic.enable` is set
        (no default — cache names and keys are deployment topology).
      '';
    };

    priority = mkOption {
      type = types.nullOr types.int;
      default = null;
      example = 10;
      description = ''
        Optional substituter priority for the Attic caches (lower =
        preferred). Below `cache.nixos.org`'s 40 makes Attic win over the
        public caches on this host — useful on in-cluster CI nodes so
        warm-store probes hit Attic first. `null` leaves it unset, so Attic is
        queried after the public caches.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf (!isDarwin) {nix.settings = settings;})
    (mkIf isDarwin (optionalAttrs (options ? determinateNix) {
      determinateNix.customSettings = settings;
    }))
  ]);
}
