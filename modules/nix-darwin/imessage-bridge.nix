{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.imessage-bridge;

  bridgeArgs =
    [(lib.getExe cfg.package)]
    ++ ["--port" (toString cfg.port)]
    ++ lib.optionals (cfg.bonjourName != null) ["--name" cfg.bonjourName]
    ++ lib.optional cfg.noBonjour "--no-bonjour";

  bridgeCmd = "exec " + lib.escapeShellArgs bridgeArgs;

  # Effective log directory: explicit cfg.logDir, or /var/log/imessage-bridge
  # for daemon mode. Null means no log capture (user agent default).
  effectiveLogDir =
    if cfg.logDir != null
    then cfg.logDir
    else if cfg.user != null
    then "/var/log/imessage-bridge"
    else null;

  # State setup for system daemon mode: create log directory.
  # Runs inside daemon script rather than system.activationScripts because
  # nix-darwin did not reliably include custom activation scripts in the
  # generated system activation profile for some configurations.
  # install -d is fully idempotent.
  stateSetup = lib.optionalString (effectiveLogDir != null) ''
    install -d -o root -g wheel ${escapeShellArg (toString effectiveLogDir)}
  '';

  logPaths =
    lib.optionalAttrs (effectiveLogDir != null) {
      StandardOutPath = "${effectiveLogDir}/imessage-bridge.log";
      StandardErrorPath = "${effectiveLogDir}/imessage-bridge.err.log";
    };
in {
  options.services.imessage-bridge = {
    enable = mkEnableOption "iMessage Bridge HTTP server";

    package = mkOption {
      type = types.package;
      default = pkgs.imessage-bridge;
      defaultText = literalExpression "pkgs.imessage-bridge";
      description = "imessage-bridge package to use.";
    };

    port = mkOption {
      type = types.port;
      default = 8432;
      description = "Port to listen on.";
    };

    bonjourName = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Bonjour service name. Defaults to hostname.";
    };

    noBonjour = mkOption {
      type = types.bool;
      default = false;
      description = "Disable Bonjour/mDNS service registration.";
    };

    user = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        System user to run the bridge as. When set, the module creates a
        system LaunchDaemon instead of a user LaunchAgent. The daemon runs
        as root for directory setup, then drops to this user via su.
        The user must have an active macOS GUI session with Messages.app
        signed in, and Full Disk Access granted to the nix-wrapped python
        binary.
      '';
    };

    logDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      defaultText = literalExpression "null (no log capture in user agent mode; /var/log/imessage-bridge in daemon mode)";
      description = ''
        Directory for StandardOutPath and StandardErrorPath logs.
        When null in user agent mode, launchd captures no log output.
        When user is set (daemon mode), defaults to /var/log/imessage-bridge.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # System LaunchDaemon mode (PR 513 pattern).
    # Runs as root for state setup, drops to cfg.user for bridge execution.
    # Uses `script` (not `command`) so nix-darwin generates a wait4path
    # guard for the Nix store volume.
    (mkIf (cfg.user != null) {
      launchd.daemons.imessage-bridge = {
        script = ''
          ${stateSetup}
          exec su -l ${escapeShellArg cfg.user} -c ${escapeShellArg bridgeCmd}
        '';
        serviceConfig =
          {
            RunAtLoad = true;
            KeepAlive = true;
          }
          // logPaths;
      };
    })

    # User LaunchAgent mode (original behavior).
    # Uses `script` (not `command`) for wait4path /nix/store guard,
    # which prevents silent failures if the Nix volume is not yet
    # mounted when launchd loads the agent at boot.
    (mkIf (cfg.user == null) {
      launchd.user.agents.imessage-bridge = {
        script = bridgeCmd;
        serviceConfig =
          {
            RunAtLoad = true;
            KeepAlive = true;
          }
          // logPaths;
      };
    })
  ]);
}
