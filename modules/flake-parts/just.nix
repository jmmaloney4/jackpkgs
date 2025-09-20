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
    in {
      just-flake = {
        features = {
          treefmt.enable = true;
          direnv = {
            enable = true;
            justfile = ''
              # Run direnv
              reload:
                  ${lib.getExe pcfg.direnvPackage} reload
              # alias for reload
              r:
                  @just reload
            '';
          };
          infra = {
            enable = cfg.pulumi.enable; # && cfg.pulumi.backendUrl != null && cfg.pulumi.secretsProvider != null;
            justfile =
              # lib.throwIf (cfg.pulumi.enable && (cfg.pulumi.backendUrl == null || cfg.pulumi.secretsProvider == null))
              # "jackpkgs.pulumi.backendUrl and jackpkgs.pulumi.secretsProvider must be set when jackpkgs.pulumi.enable is true"
              ''
                # Authenticate with GCP and refresh ADC
                auth:
                    gcloud auth login --update-adc
                    gcloud auth application-default login

                # Create a new Pulumi stack (usage: just new-stack <project-path> <stack-name>)
                new-stack project_path stack_name:
                    ${lib.getExe pcfg.pulumiPackage} -C {{project_path}} login "${cfg.pulumi.backendUrl}"
                    ${lib.getExe pcfg.pulumiPackage} -C {{project_path}} stack init {{stack_name}} --secrets-provider "${cfg.pulumi.secretsProvider}"
                    ${lib.getExe pcfg.pulumiPackage} -C {{project_path}} stack select {{stack_name}}
              '';
          };
          python = {
            enable = true;
            justfile = ''
              # Strip output from Jupyter notebooks
              nbstrip notebook="":
                  @if [ -z "{{notebook}}" ]; then \
                      ${lib.getExe pcfg.fdPackage} -e ipynb -x ${lib.getExe pcfg.nbstripoutPackage}; \
                  else \
                      ${lib.getExe pcfg.nbstripoutPackage} "{{notebook}}"; \
                  fi
            '';
          };
          git = {
            enable = true;
            justfile = ''
              # Run pre-commit hooks
              pre-commit:
                ${lib.getExe pcfg.preCommitPackage}
              # alias for pre-commit
              pre:
                @just pre-commit
              # Run pre-commit hooks on all files
              pre-all:
                ${lib.getExe pcfg.preCommitPackage} run --all-files
            '';
          };
          release = {
            enable = true;
            justfile = ''
              # New minor release
              release:
                #!/usr/bin/env bash
                set -euo pipefail

                # Source shared utilities
                source ${lib.getExe pcfg.releaseUtils}

                echo "🏷️  Creating new semver minor release..." >&2

                # Always operate on origin/main, regardless of current checkout
                main_remote="origin"
                main_branch="main"

                # Use shared functions
                fetch_latest "$main_remote" "$main_branch"
                latest_tag=$(get_latest_tag)

                echo "📋 Latest tag: $latest_tag" >&2

                # Extract version numbers (remove 'v' prefix)
                version=''${latest_tag#v}
                major=''${version%%.*}
                minor=''${version#*.}
                minor=''${minor%%.*}
                patch=''${version##*.}

                # Increment minor version and reset patch to 0
                new_minor=$((minor + 1))
                new_version="$major.$new_minor.0"
                new_tag="v$new_version"

                echo "🆕 New tag: $new_tag" >&2

                # Use shared function to create and push tag
                create_and_push_tag "$new_tag" "$main_remote" "$main_branch"
              # Bump patch version
              bump:
                #!/usr/bin/env bash
                set -euo pipefail

                # Source shared utilities
                source ${lib.getExe pcfg.releaseUtils}

                echo "🏷️  Creating new semver patch release..." >&2

                # Always operate on origin/main, regardless of current checkout
                main_remote="origin"
                main_branch="main"

                # Use shared functions
                fetch_latest "$main_remote" "$main_branch"
                latest_tag=$(get_latest_tag)

                echo "📋 Latest tag: $latest_tag" >&2

                # Extract version numbers (remove 'v' prefix)
                version=''${latest_tag#v}
                major=''${version%%.*}
                minor=''${version#*.}
                minor=''${minor%%.*}
                patch=''${version##*.}

                # Increment patch version
                new_patch=$((patch + 1))
                new_version="$major.$minor.$new_patch"
                new_tag="v$new_version"

                echo "🆕 New tag: $new_tag" >&2

                # Use shared function to create and push tag
                create_and_push_tag "$new_tag" "$main_remote" "$main_branch"
            '';
          };
          nix = {
            enable = true;
            justfile = ''
              # Build all flake outputs using flake-iter
              build-all:
                ${lib.getExe pcfg.flakeIterPackage} build

              # Build all flake outputs with verbose output
              build-all-verbose:
                ${lib.getExe pcfg.flakeIterPackage} build --verbose
            '';
          };
          quarto = {
            enable = cfg.quarto.enable && cfg.quarto.sites != [];
            justfile = lib.concatStrings (
              [
                ''
                  # Build all quarto sites
                  build-sites:
                  ${lib.concatStringsSep "\n" (map (site: "    ${lib.getExe pcfgQuarto.quartoPackage} build ${site}") cfg.quarto.sites)}
                ''
              ]
              ++ map (site: ''
                # Build ${site}
                build-${site}:
                    ${lib.getExe pcfgQuarto.quartoPackage} build ${site}
                # preview ${site}
                ${site}:
                    ${lib.getExe pcfgQuarto.quartoPackage} preview ${site}
              '')
              cfg.quarto.sites
            );
          };
        };
      };
    };
  };
}
