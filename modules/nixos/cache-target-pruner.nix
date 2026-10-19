# jackpkgs.cache-target-pruner — reactive pruner for CACHEDIR.TAG-marked build
# caches (Cargo target/, uv, ...) under the operator's ~/.cache, triggered by
# low disk space rather than by age or a calendar.
#
# Promoted from garden `nixfiles/modules/{common,nixos}/cache-target-pruner.nix`
# (garden#2008/#1835; the itachi DiskPressure incident of 2026-09-28/29;
# garden#2074 Part B). NixOS only (systemd): garden's launchd backend for
# hermione stays in garden with the rest of its darwin tree (ADR-051
# Decision 5, amended 2026-09-25).
#
# Why free-space and not age: a dev box's caches regenerate same-day from an
# active session, and concurrent worktree churn grows them faster than any
# age threshold can bound (each worktree's workspace-local crates fingerprint
# by absolute path, so they never dedupe). On an RKE2 node that growth ends as
# kubelet DiskPressure; the floor below sits above kubelet's
# `nodefs.available<10%` eviction threshold with margin.
#
# Interface: `enable` and `user`. `user` names the account whose ~/.cache is
# scanned AND the identity the service runs as, so a prune can only delete what
# that user could already delete. It has no default (identity, ADR-051
# Decision 4) and must be a declared user (asserted).
#
# The thresholds (prune below 15% free, stop at 20%, skip any directory written
# to within 15 minutes, scan 4 levels deep, check every 15 minutes) are fixed,
# not options: every garden host ran the defaults, so exposing them would be a
# choice no caller has a basis to make (ADR-051 Decision 4). The
# `targetPercent > floorPercent` invariant garden asserted is unreachable for
# the same reason. A host that genuinely needs different numbers is the
# trigger to reintroduce an option, with that host as the second value.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.jackpkgs.cache-target-pruner;

  floorPercent = 15;
  targetPercent = 20;
  minAgeMinutes = 15;
  maxScanDepth = 4;
  checkIntervalSec = 900;
  filesystem = "/";

  pruneScript = pkgs.writeShellApplication {
    name = "cache-target-pruner";
    runtimeInputs = [pkgs.coreutils pkgs.findutils pkgs.gnugrep];
    text = builtins.readFile ./cache-target-pruner.sh;
  };

  userDeclared = config.users.users ? ${cfg.user};
  # Only read once the assertion below has had a chance to fire: an undeclared
  # user would otherwise surface as an opaque missing-attribute error.
  cacheDir =
    if userDeclared
    then "${config.users.users.${cfg.user}.home}/.cache"
    else "/nonexistent";
in {
  options.jackpkgs.cache-target-pruner = {
    enable = lib.mkEnableOption "reactive pruner for CACHEDIR.TAG-marked cache directories under a user's ~/.cache, triggered by low disk space";

    user = lib.mkOption {
      type = lib.types.str;
      example = "alice";
      description = ''
        User whose ~/.cache is scanned, and the identity the prune service runs
        as. Must be declared in `users.users`. Required when `enable` is set
        (no default — this is identity).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = userDeclared;
        message = "jackpkgs.cache-target-pruner.user = \"${cfg.user}\" is not declared in users.users; the pruner needs its home directory.";
      }
    ];

    systemd.services.cache-target-pruner = {
      description = "Prune stale build-cache directories when disk space runs low";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        # Default 90s is too short for du+rm across many-GB target dirs; a
        # SIGTERM mid-rm -rf would leave an untagged remnant the tag-based
        # scan can never select again.
        TimeoutStartSec = "30m";
        ExecStart = "${lib.getExe pruneScript} ${lib.escapeShellArg cacheDir} ${lib.escapeShellArg filesystem} ${toString floorPercent} ${toString targetPercent} ${toString minAgeMinutes} ${toString maxScanDepth}";
      };
    };

    systemd.timers.cache-target-pruner = {
      description = "Periodic disk-space check for cache-target-pruner";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = "${toString checkIntervalSec}s";
        RandomizedDelaySec = "1m";
      };
    };
  };
}
