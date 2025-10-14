{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.vscode;

  typedSettingsToSettings = typed:
    let
      get = path: default: lib.attrByPath path default typed;
      editorFormatOnSave = get ["editor" "formatOnSave"] null;
      editorTabSize = get ["editor" "tabSize"] null;
      editorDefaultFormatter = get ["editor" "defaultFormatter"] null;
      filesExclude = get ["files" "exclude"] {};
      rustEnable = get ["rust" "enable"] false;
      rustCargoAllFeatures = get ["rust" "cargo" "allFeatures"] true;
      rustCheckCommand = get ["rust" "check" "command"] "clippy";
    in
      lib.optionalAttrs (editorFormatOnSave != null) {
        "editor.formatOnSave" = editorFormatOnSave;
      }
      // lib.optionalAttrs (editorTabSize != null) {
        "editor.tabSize" = editorTabSize;
      }
      // lib.optionalAttrs (editorDefaultFormatter != null) {
        "editor.defaultFormatter" = editorDefaultFormatter;
      }
      // lib.optionalAttrs (filesExclude != {}) {
        "files.exclude" = filesExclude;
      }
      // (lib.optionalAttrs rustEnable {
        "rust-analyzer.cargo.allFeatures" = rustCargoAllFeatures;
        "rust-analyzer.check.command" = rustCheckCommand;
      });

in {
  imports = [
    jackpkgsInputs.flake-root.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.vscode = {
      enable = mkEnableOption "jackpkgs VSCode settings management" // {default = false;};
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: let
      inherit (lib) types mkOption;
    in {
      options.jackpkgs.outputs.vscodeMerge = mkOption {
        type = types.package;
        readOnly = true;
        description = "Merge tool package for VSCode settings.";
      };

      options.jackpkgs.vscode = {
        projectRoot = mkOption {
          type = types.str;
          default = ".";
          description = "Relative directory (from invocation root) containing VSCode workspace files.";
          example = "frontend";
        };

        settingsFile = mkOption {
          type = types.str;
          default = ".vscode/settings.json";
          description = "VSCode settings path relative to projectRoot (or absolute).";
        };

        settings = mkOption {
          type = types.attrsOf types.anything;
          default = {};
          description = "Untyped VSCode settings merged with the existing file.";
        };

        typedSettings = mkOption {
          type = types.submodule ({lib, ...}: let
            inherit (lib) types mkOption;
          in {
            options = {
              editor = mkOption {
                type = types.submodule ({lib, ...}: let inherit (lib) types mkOption; in {
                  options = {
                    formatOnSave = mkOption {
                      type = types.nullOr types.bool;
                      default = null;
                      description = "Set editor.formatOnSave.";
                    };
                    tabSize = mkOption {
                      type = types.nullOr types.int;
                      default = null;
                      description = "Set editor.tabSize.";
                    };
                    defaultFormatter = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = "Set editor.defaultFormatter.";
                    };
                  };
                });
                default = {};
                description = "Common editor.* settings.";
              };

              files = mkOption {
                type = types.submodule ({lib, ...}: let inherit (lib) types mkOption; in {
                  options = {
                    exclude = mkOption {
                      type = types.attrsOf types.bool;
                      default = {};
                      description = "files.exclude overrides.";
                    };
                  };
                });
                default = {};
                description = "Common files.* settings.";
              };

              rust = mkOption {
                type = types.submodule ({lib, ...}: let inherit (lib) types mkOption; in {
                  options = {
                    enable = mkOption {
                      type = types.bool;
                      default = false;
                      description = "Enable typed rust-analyzer settings.";
                    };
                    cargo = mkOption {
                      type = types.submodule ({lib, ...}: let inherit (lib) types mkOption; in {
                        options = {
                          allFeatures = mkOption {
                            type = types.bool;
                            default = true;
                            description = "rust-analyzer.cargo.allFeatures.";
                          };
                        };
                      });
                      default = {};
                    };
                    check = mkOption {
                      type = types.submodule ({lib, ...}: let inherit (lib) types mkOption; in {
                        options = {
                          command = mkOption {
                            type = types.str;
                            default = "clippy";
                            description = "rust-analyzer.check.command.";
                          };
                        };
                      });
                      default = {};
                    };
                  };
                });
                default = {};
                description = "Typed rust-analyzer helpers.";
              };
            };
          });
          default = {};
          description = "Optional typed settings translated into VSCode JSON.";
        };

        ownedKeys = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "JSON keys (dot paths) fully owned by declarations.";
        };

        arrayPolicy = mkOption {
          type = types.submodule ({lib, ...}: let inherit (lib) types mkOption; in {
            options = {
              global = mkOption {
                type = types.enum ["replace" "append" "append-unique"];
                default = "replace";
                description = "Default merge policy for JSON arrays.";
              };
              perKey = mkOption {
                type = types.attrsOf (types.enum ["replace" "append" "append-unique"]);
                default = {};
                description = "Overrides for array merge policy keyed by dot path.";
              };
            };
          });
          default = {};
          description = "Array merge behaviour.";
        };
      };
    });
  };

  config = mkIf cfg.enable {
    perSystem = {
      pkgs,
      lib,
      config,
      ...
    }: let
      sysCfg = config.jackpkgs.vscode;
      typed = typedSettingsToSettings sysCfg.typedSettings;
      combinedSettings = lib.recursiveUpdate sysCfg.settings typed;
      declaredJson = builtins.toJSON combinedSettings;
      declaredSettingsFile = pkgs.writeText "jackpkgs-vscode-declared.json" declaredJson;
      ownedKeysJson = builtins.toJSON sysCfg.ownedKeys;
      policyMapJson = builtins.toJSON sysCfg.arrayPolicy.perKey;
      globalPolicy = sysCfg.arrayPolicy.global;
      mergeScript = pkgs.writeShellApplication {
        name = "jackpkgs-vscode-merge-settings";
        runtimeInputs = [pkgs.jq pkgs.coreutils];
        text = ''
          set -euo pipefail

          ROOT_INPUT='${sysCfg.projectRoot}'
          INVOCATION_ROOT="''${JACKPKGS_VSCODE_ROOT:-$PWD}"

          case "$ROOT_INPUT" in
            "") ROOT="$INVOCATION_ROOT" ;;
            /*) ROOT="$ROOT_INPUT" ;;
            *) ROOT="$INVOCATION_ROOT/$ROOT_INPUT" ;;
          esac

          ROOT="$(realpath -m "$ROOT")"
          if [ ! -d "$ROOT" ]; then
            echo "Project root '$ROOT' does not exist." >&2
            exit 2
          fi

          SETTINGS_INPUT='${sysCfg.settingsFile}'
          case "$SETTINGS_INPUT" in
            "")
              echo "settingsFile option may not be empty." >&2
              exit 2
              ;;
            /*)
              TARGET_PATH="$SETTINGS_INPUT"
              ;;
            *)
              TARGET_PATH="$ROOT/$SETTINGS_INPUT"
              ;;
          esac

          TARGET_DIR="$(dirname "$TARGET_PATH")"
          mkdir -p "$TARGET_DIR"

          existing_json='{}'
          if [ -f "$TARGET_PATH" ]; then
            if jq -e . "$TARGET_PATH" >/dev/null 2>&1; then
              existing_json="$(cat "$TARGET_PATH")"
            else
              echo "Warning: $SETTINGS_INPUT exists but is not valid JSON. Backing up and continuing with {}." >&2
              cp -f "$TARGET_PATH" "$TARGET_PATH.bak.$(date +%s)"
            fi
          fi

          declared_json="$(cat '${declaredSettingsFile}')"

          owned_keys_json='${ownedKeysJson}'
          if [ "$(echo "$owned_keys_json" | jq 'length')" -gt 0 ]; then
            existing_json="$(jq --argjson keys "$owned_keys_json" '
              def parse_path:
                split(".") | map(if test("^[0-9]+$") then (tonumber) else . end);
              delpaths([ $keys[] | parse_path ])
            ' <<<"$existing_json")"
          fi

          merged_json="$(
            jq -n \
              --argjson a "$existing_json" \
              --argjson b "$declared_json" \
              --argjson perKey '${policyMapJson}' \
              --arg globalPolicy '${globalPolicy}' '
              def path_to_dot($p):
                $p | map(tostring) | join(".");
              def policy_for($p):
                $perKey[path_to_dot($p)] // $globalPolicy;

              def deepmerge($x; $y; $p):
                if ( ($x|type) == "object" and ($y|type) == "object" ) then
                  reduce ($y|keys_unsorted[]) as $k
                    ($x;
                      .[$k] =
                        if has($k) then
                          deepmerge( .[$k]; $y[$k]; ($p + [$k]) )
                        else
                          $y[$k]
                        end
                    )
                elif ( ($x|type) == "array" and ($y|type) == "array" ) then
                  (policy_for($p)) as $pol
                  | if $pol == "replace" then $y
                    elif $pol == "append" then ($x + $y)
                    elif $pol == "append-unique" then
                      reduce ($x + $y)[] as $item ([];
                        if index($item) then . else . + [$item] end)
                    else
                      $y
                    end
                else
                  $y
                end;

              deepmerge($a; $b; [])
            '
          )"

          tmp="$(mktemp)"
          echo "$merged_json" | jq '.' > "$tmp"
          mv "$tmp" "$TARGET_PATH"
          echo "Wrote $SETTINGS_INPUT with merged settings."
        '';
      };
    in {
      packages.jackpkgs-vscode-merge-settings = mergeScript;
      apps.jackpkgs-vscode-merge-settings = {
        type = "app";
        program = "${mergeScript}/bin/jackpkgs-vscode-merge-settings";
      };
      jackpkgs.outputs.vscodeMerge = mergeScript;
    };
  };
}
