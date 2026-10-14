# jackpkgs.cargo — Cargo environment caps for Home Manager (ADR-051).
# Promoted from garden `nixfiles/home/programs/cargo.nix` (`jmmaloney4.cargo`).
{
  config,
  lib,
  ...
}: let
  cfg = config.jackpkgs.cargo;
in {
  options.jackpkgs.cargo = {
    enable = lib.mkEnableOption "jackpkgs' Cargo environment settings";

    buildJobs = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      # null is a spelled, intended state ("leave Cargo's default alone"), not
      # an unwired required option, so it keeps an explicit default.
      default = null;
      description = ''
        Caps Cargo's per-invocation parallelism via the CARGO_BUILD_JOBS
        environment variable.

        This is an environment variable, not a PATH-shadowing wrapper, so it
        reaches whichever `cargo` binary actually runs a build -- including
        one a project's own Nix devShell puts ahead of anything Home Manager
        installs on PATH.

        Set this on hosts where several concurrent builds (e.g. multiple
        agents each running `cargo build`, which defaults to `-j nproc`) can
        sum past available RAM and trigger an OOM kill. `null` leaves Cargo's
        own default in place.

        Exported through both `home.sessionVariables` and
        `systemd.user.sessionVariables`, so a build launched by a systemd user
        unit still sees the cap. Neither reaches a session that was already
        running before the switch.
      '';
      example = 4;
    };
  };

  config = lib.mkIf (cfg.enable && cfg.buildJobs != null) {
    home.sessionVariables.CARGO_BUILD_JOBS = toString cfg.buildJobs;
    systemd.user.sessionVariables.CARGO_BUILD_JOBS = toString cfg.buildJobs;
  };
}
