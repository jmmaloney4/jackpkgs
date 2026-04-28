{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.imessage-bridge;
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

    logDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Directory for StandardOutPath and StandardErrorPath logs. When null, launchd defaults apply.";
    };
  };

  config = mkIf cfg.enable {
    launchd.user.agents.imessage-bridge = {
      command = lib.escapeShellArgs (
        [(lib.getExe cfg.package)]
        ++ ["--port" (toString cfg.port)]
        ++ lib.optionals (cfg.bonjourName != null) ["--name" cfg.bonjourName]
        ++ lib.optional cfg.noBonjour "--no-bonjour"
      );

      serviceConfig =
        {
          RunAtLoad = true;
          KeepAlive = true;
        }
        // lib.optionalAttrs (cfg.logDir != null) {
          StandardOutPath = "${cfg.logDir}/imessage-bridge.log";
          StandardErrorPath = "${cfg.logDir}/imessage-bridge.err.log";
        };
    };
  };
}
