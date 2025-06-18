{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkOption mkIf types optionalString concatMapStrings;

  cfg = config.programs.dock;

  # Helper: build one dockutil --add line
  mkAddCmd = item:
    let
      base = ''dockutil --add ${item.path}'';
      folderArgs = if item.type == "folder" then
        let
          viewArg = optionalString (item.view != null) " --view ${item.view}";
          displayArg = optionalString (item.display != null) " --display ${item.display}";
          sortArg = optionalString (item.sort != null) " --sort ${item.sort}";
        in
          "${viewArg}${displayArg}${sortArg}"
      else "";
      spacerArgs = if item.type == "spacer" then " --type spacer" else "";
      posArg     = optionalString (item.position != null) " --position ${toString item.position}";
    in
      ''${base}${folderArgs}${spacerArgs}${posArg} --no-restart\n'';
in
{
  ######  Options  ###########################################################
  options.programs.dock = {
    enable = mkEnableOption "declarative Dock layout via dockutil";

    reset = mkOption {
      type        = types.bool;
      default     = true;
      description = "Remove all existing items before adding the declared list.";
    };

    entries = mkOption {
      type = types.listOf (types.submodule ({ ... }: {
        options = {
          path = mkOption { type = types.str; description = "Absolute path to app or folder."; };
          type = mkOption {
            type        = types.enum [ "app" "folder" "spacer" ];
            default     = "app";
            description = "‘app’ | ‘folder’ | ‘spacer’";
          };
          position = mkOption { type = types.nullOr types.int;  default = null; };
          view     = mkOption { type = types.nullOr (types.enum [ "grid" "fan" "list" "auto" ]); default = null; };
          display  = mkOption { type = types.nullOr (types.enum [ "stack" "folder" ]);           default = null; };
          sort     = mkOption { type = types.nullOr (types.enum [ "name" "dateadded" "datemodified" "datecreated" "kind" ]);
                                default = null; };
        };
      }));
      default     = [];
      description = "Ordered list of Dock items.";
    };
  };

  ######  Implementation  ####################################################
  config = mkIf (cfg.enable && pkgs.stdenv.isDarwin) {
    home.packages = [ pkgs.dockutil ];

    home.activation.configureDock = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      echo "Configuring Dock…"
      ${optionalString cfg.reset "dockutil --remove all --no-restart"}
      ${concatMapStrings mkAddCmd cfg.entries}
      killall Dock || true
    '';
  };
}
