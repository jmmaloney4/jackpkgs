{ config, lib, pkgs, ... }:
with lib;

let
  cfg = config.programs.tod;
  configToml = pkgs.writeText "tod-config.toml" (generators.toTOML {} cfg.settings);
  launcher = pkgs.writeShellScriptBin "tod" ''
    ${optionalString (cfg.apiTokenFile != null) "export TODOIST_API_TOKEN=$(cat ${cfg.apiTokenFile})"}
    exec ${lib.getExe cfg.package} "$@"
  '';

in {
  options.programs.tod = {
    enable = mkEnableOption "Tod CLI";
    package = mkOption {
      type = types.package;
      default = pkgs.tod;
      description = "Tod package to use.";
    };
    settings = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      description = "Settings written to config.toml.";
    };
    apiTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File containing Todoist API token.";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ launcher ];
    xdg.configFile."tod/config.toml".source = configToml;
  };
}
