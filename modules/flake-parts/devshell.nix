{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.shell;
  gcpProfile = config.jackpkgs.gcp.profile;
in {
  imports = [
    jackpkgsInputs.flake-root.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.shell = {
      enable = mkEnableOption "jackpkgs-devshell" // {default = true;};

      welcome = {
        enable = mkEnableOption "welcome message on shell entry" // {default = true;};
        showJustHint = mkEnableOption "hint about just --list" // {default = true;};
        message = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "Welcome to my project!";
          description = ''
            Custom welcome message to display on shell entry.
            If null, only the just hint is shown (if enabled).
          '';
        };
      };

      direnv = {
        hideEnvDiff = mkEnableOption "hiding direnv environment variable diff output" // {default = true;};
      };
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.shell = {
        inputsFrom = mkOption {
          type = types.listOf types.package;
          default = [];
          description = "Additional devShell fragments to include via inputsFrom.";
        };
        packages = mkOption {
          type = types.listOf types.package;
          default = [];
          description = "Additional packages to include in the composed devShell.";
        };
      };
      options.jackpkgs.outputs.devShell = mkOption {
        type = types.package;
        readOnly = true;
        description = "Output devShell to include in `inputsFrom`.";
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
      sysCfg = config.jackpkgs.shell;

      # Build shellHook segments as a list and join with newlines for safe concatenation
      shellHookParts =
        lib.optional (gcpProfile != null) ''
          export CLOUDSDK_CONFIG="$HOME/.config/gcloud-profiles/"${lib.escapeShellArg gcpProfile}
          mkdir -p "$CLOUDSDK_CONFIG"
        ''
        ++ lib.optionals cfg.welcome.enable (
          lib.optional (cfg.welcome.message != null) ''echo ${lib.escapeShellArg cfg.welcome.message}''
          ++ lib.optional cfg.welcome.showJustHint ''echo "Run 'just --list' to see available commands"''
        );
    in {
      jackpkgs.outputs.devShell = pkgs.mkShell (
        {
          inputsFrom =
            [
              config.just-flake.outputs.devShell
              config.flake-root.devShell
              config.pre-commit.devShell
              config.treefmt.build.devShell
            ]
            ++ sysCfg.inputsFrom;
          packages = sysCfg.packages;

          shellHook = lib.concatStringsSep "\n" shellHookParts;
        }
        # Hide direnv environment variable diff output by passing DIRENV_LOG_FORMAT=""
        # directly into mkShell's argument set rather than merging onto its output.
        // lib.optionalAttrs cfg.direnv.hideEnvDiff {DIRENV_LOG_FORMAT = "";}
      );
    };
  };
}
