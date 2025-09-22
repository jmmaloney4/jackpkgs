{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs;
in {
  imports = [
    jackpkgsInputs.just-flake.flakeModule
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.just = {
      enable = mkEnableOption "jackpkgs-just-flake" // {default = true;};
    };

    perSystem = mkDeferredModuleOption ({
      inputs',
      lib,
      pkgs,
      system,
      ...
    }: {
      options.jackpkgs.just = {
        direnvPackage = mkOption {
          type = types.package;
          default = pkgs.direnv;
          defaultText = "pkgs.direnv";
          description = "direnv package to use.";
        };
        fdPackage = mkOption {
          type = types.package;
          default = pkgs.fd;
          defaultText = "pkgs.fd";
          description = "fd package to use for finding files.";
        };
        flakeIterPackage = mkOption {
          type = types.package;
          default = jackpkgsInputs.flake-iter.packages.${system}.default;
          defaultText = "flake-iter.packages.default";
          description = "flake-iter package to use.";
        };
        googleCloudSdkPackage = mkOption {
          type = types.package;
          default = pkgs.google-cloud-sdk;
          defaultText = "pkgs.google-cloud-sdk";
          description = "google-cloud-sdk package to use.";
        };
        jqPackage = mkOption {
          type = types.package;
          default = pkgs.jq;
          defaultText = "pkgs.jq";
          description = "jq package to use.";
        };
        nbstripoutPackage = mkOption {
          type = types.package;
          default = pkgs.nbstripout;
          defaultText = "pkgs.nbstripout";
          description = "nbstripout package to use.";
        };
        preCommitPackage = mkOption {
          type = types.package;
          default = pkgs.pre-commit;
          defaultText = "pkgs.pre-commit";
          description = "pre-commit package to use.";
        };
        pulumiPackage = mkOption {
          type = types.package;
          default = pkgs.pulumi;
          defaultText = "pkgs.pulumi";
          description = "pulumi package to use.";
        };

        # Shared release script utilities
        releaseUtils = mkOption {
          type = types.package;
          default = pkgs.writeShellScriptBin "release-utils" (builtins.readFile ./release-utils.sh);
          defaultText = "pkgs.writeShellScriptBin \"release-utils\" (builtins.readFile ./release-utils.sh)";
          description = "Shared utilities for release scripts.";
        };
      };
    });
  };

  config = mkIf cfg.just.enable {
    # Contribute per-system config as a function (this is the correct place for a function)
    perSystem = {
      pkgs,
      lib,
      config,
      ...
    }: let
      pcfg = config.jackpkgs.just; # per-system config scope
      pcfgQuarto = config.jackpkgs.quarto;
    in let
      # Utility function to construct a single justfile recipe
      # Handles indentation and various recipe patterns
      constructRecipe = {
        name,
        body,
        parameters ? null,
        description ? null,
        dependencies ? null,
        quiet ? false,
      }: let
        # Convert body to list of lines if it's a string
        bodyLines =
          if builtins.isString body
          then lib.splitString "\n" body
          else body;

        # Indent body lines (skip empty lines and comments for indentation)
        indentedBody = builtins.concatStringsSep "\n" (
          map (
            line: let
              trimmed = lib.strings.trim line;
            in
              if trimmed == "" || lib.strings.hasPrefix "#" trimmed
              then line # Don't indent empty lines or comments
              else "    ${line}" # Indent executable lines
          )
          bodyLines
        );

        # Build recipe signature
        signature =
          if parameters != null
          then "${name} ${parameters}:"
          else "${name}:";

        # Build dependencies line
        depsLine =
          if dependencies != null
          then "    ${dependencies}"
          else "";

        # Build quiet indicator
        quietIndicator =
          if quiet
          then "@"
          else "";

        # Build description comment
        descComment =
          if description != null
          then "# ${description}\n"
          else "";
      in ''
        ${descComment}${quietIndicator}${signature}
        ${indentedBody}${depsLine}'';

      # Utility function to concatenate multiple recipes
      concatRecipes = recipes: builtins.concatStringsSep "\n\n" recipes;
    in {
      just-flake = {
        features = {
          treefmt.enable = true;
          direnv = {
            enable = true;
            justfile = concatRecipes [
              (constructRecipe {
                name = "reload";
                body = "${lib.getExe pcfg.direnvPackage} reload";
                description = "Run direnv";
              })
              (constructRecipe {
                name = "r";
                body = "just reload";
                description = "alias for reload";
                quiet = true;
              })
            ];
          };
          infra = {
            enable = cfg.pulumi.enable; # && cfg.pulumi.backendUrl != null && cfg.pulumi.secretsProvider != null;
            justfile = concatRecipes [
              (constructRecipe {
                name = "auth";
                body = [
                  "gcloud auth login --update-adc"
                  "gcloud auth application-default login"
                ];
                description = "Authenticate with GCP and refresh ADC";
              })
              (constructRecipe {
                name = "new-stack";
                parameters = "project_path stack_name";
                body = [
                  "${lib.getExe pcfg.pulumiPackage} -C {{project_path}} login \"${cfg.pulumi.backendUrl}\""
                  "${lib.getExe pcfg.pulumiPackage} -C {{project_path}} stack init {{stack_name}} --secrets-provider \"${cfg.pulumi.secretsProvider}\""
                  "${lib.getExe pcfg.pulumiPackage} -C {{project_path}} stack select {{stack_name}}"
                ];
                description = "Create a new Pulumi stack (usage: just new-stack <project-path> <stack-name>)";
              })
            ];
          };
          python = {
            enable = true;
            justfile = constructRecipe {
              name = "nbstrip";
              parameters = "notebook=\"\"";
              body = [
                "@if [ -z \"{{notebook}}\" ]; then \\"
                "    ${lib.getExe pcfg.fdPackage} -e ipynb -x ${lib.getExe pcfg.nbstripoutPackage}; \\"
                "else \\"
                "    ${lib.getExe pcfg.nbstripoutPackage} \"{{notebook}}\"; \\"
                "fi"
              ];
              description = "Strip output from Jupyter notebooks";
            };
          };
          git = {
            enable = true;
            justfile = concatRecipes [
              (constructRecipe {
                name = "pre-commit";
                body = "${lib.getExe pcfg.preCommitPackage}";
                description = "Run pre-commit hooks";
              })
              (constructRecipe {
                name = "pre";
                body = "just pre-commit";
                description = "alias for pre-commit";
                quiet = true;
              })
              (constructRecipe {
                name = "pre-all";
                body = "${lib.getExe pcfg.preCommitPackage} run --all-files";
                description = "Run pre-commit hooks on all files";
              })
            ];
          };
          release = {
            enable = true;
            justfile = concatRecipes [
              (constructRecipe {
                name = "release";
                body = [
                  "#!/usr/bin/env bash"
                  "set -euo pipefail"
                  ""
                  "# Source shared utilities"
                  "source ${lib.getExe pcfg.releaseUtils}"
                  ""
                  "echo \"🏷️  Creating new semver minor release...\" >&2"
                  ""
                  "# TODO: Implement version extraction and tagging"
                  "echo \"Release functionality coming soon...\" >&2"
                ];
                description = "New minor release";
              })
              (constructRecipe {
                name = "bump";
                body = [
                  "#!/usr/bin/env bash"
                  "set -euo pipefail"
                  ""
                  "# Source shared utilities"
                  "source ${lib.getExe pcfg.releaseUtils}"
                  ""
                  "echo \"🏷️  Creating new semver patch release...\" >&2"
                  ""
                  "# TODO: Implement version bump functionality"
                  "echo \"Bump functionality coming soon...\" >&2"
                ];
                description = "Bump patch version";
              })
            ];
          };
          nix = {
            enable = true;
            justfile = concatRecipes [
              (constructRecipe {
                name = "build-all";
                body = "${lib.getExe pcfg.flakeIterPackage} build";
                description = "Build all flake outputs using flake-iter";
              })
              (constructRecipe {
                name = "build-all-verbose";
                body = "${lib.getExe pcfg.flakeIterPackage} build --verbose";
                description = "Build all flake outputs with verbose output";
              })
            ];
          };
          quarto = {
            enable = false; # Temporarily disabled due to syntax issues
            justfile = "";
          };
        };
      };
    };
  };
}
