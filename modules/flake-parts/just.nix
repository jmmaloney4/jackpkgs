{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs;

  # Helper to build justfile recipes without indentation issues
  # Usage: mkRecipe "recipe-name" "comment" ["cmd1" "cmd2"]
  mkRecipe = name: comment: commands:
    lib.concatStringsSep "\n" (
      ["# ${comment}" "${name}:"]
      ++ map (cmd: "    ${cmd}") commands
      ++ [""]
    );

  # Helper for conditional recipe lines
  optionalLines = cond: lines:
    if cond
    then lines
    else [];
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

    jackpkgs.gcp = {
      iamOrg = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "example.com";
        description = ''
          GCP IAM organization domain for constructing user accounts.
          When set, the auth recipe will use --account=$GCP_ACCOUNT_USER@$IAM_ORG
          where GCP_ACCOUNT_USER defaults to the current Unix username ($USER).
        '';
      };

      quotaProject = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "my-project-123";
        description = ''
          GCP project ID to use for Application Default Credentials quota/billing.
          When set, the auth recipe will call:
            gcloud auth application-default set-quota-project <quotaProject>
        '';
      };
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
      sysCfg = config.jackpkgs.just; # per-system config scope
      sysCfgQuarto = config.jackpkgs.quarto;
    in {
      just-flake = {
        features = {
          # NOTE: Nix indented strings ('' ... '') strip common leading whitespace
          # based on the position of the closing ''. To generate justfiles with
          # recipes at column 0:
          #   - Align ALL content with the closing '' (e.g., both at 12 spaces)
          #   - Recipe commands need 4 additional spaces (16 total) to produce
          #     the required 4-space indentation in the output justfile
          # Example:
          #   justfile = ''
          #   recipe:        ← 12 spaces (same as closing '')
          #       command    ← 16 spaces (12 + 4)
          #   '';            ← 12 spaces (reference point)
          # Result: recipe at column 0, command indented with 4 spaces

          treefmt.enable = true;
          direnv = {
            enable = true;
            justfile = lib.concatStringsSep "\n" [
              (mkRecipe "reload" "Run direnv" [
                "${lib.getExe sysCfg.direnvPackage} reload"
              ])
              (mkRecipe "r" "alias for reload" [
                "@just reload"
              ])
            ];
          };
          infra = {
            enable = cfg.pulumi.enable; # && cfg.pulumi.backendUrl != null && cfg.pulumi.secretsProvider != null;
            justfile = lib.concatStringsSep "\n" (
              # auth recipe with conditional content
              ["# Authenticate with GCP and refresh ADC"]
              ++ ["# (set GCP_ACCOUNT_USER to override username)"]
              ++ ["auth:"]
              ++ optionalLines (cfg.gcp.iamOrg != null) [
                "    : \${GCP_ACCOUNT_USER:=$USER}"
              ]
              ++ ["    ${lib.getExe sysCfg.googleCloudSdkPackage} auth login --update-adc${lib.optionalString (cfg.gcp.iamOrg != null) " --account=$GCP_ACCOUNT_USER@${cfg.gcp.iamOrg}"}"]
              ++ optionalLines (cfg.gcp.quotaProject != null) [
                "    ${lib.getExe sysCfg.googleCloudSdkPackage} auth application-default set-quota-project ${cfg.gcp.quotaProject}"
              ]
              ++ [""]
              # new-stack recipe
              ++ ["# Create a new Pulumi stack (usage: just new-stack <project-path> <stack-name>)"]
              ++ ["new-stack project_path stack_name:"]
              ++ [
                "    ${lib.getExe sysCfg.pulumiPackage} -C {{project_path}} login \"${cfg.pulumi.backendUrl}\""
                "    ${lib.getExe sysCfg.pulumiPackage} -C {{project_path}} stack init {{stack_name}} --secrets-provider \"${cfg.pulumi.secretsProvider}\""
                "    ${lib.getExe sysCfg.pulumiPackage} -C {{project_path}} stack select {{stack_name}}"
              ]
            );
          };
          python = {
            enable = true;
            justfile = lib.concatStringsSep "\n" [
              "# Strip output from Jupyter notebooks"
              ''nbstrip notebook="":''
              ''@if [ -z "{{notebook}}" ]; then \''
              "        ${lib.getExe sysCfg.fdPackage} -e ipynb -x ${lib.getExe sysCfg.nbstripoutPackage}; \\"
              "    else \\"
              "        ${lib.getExe sysCfg.nbstripoutPackage} \"{{notebook}}\"; \\"
              "    fi"
              ""
            ];
          };
          git = {
            enable = true;
            justfile = lib.concatStringsSep "\n" [
              (mkRecipe "pre-commit" "Run pre-commit hooks" [
                "${lib.getExe sysCfg.preCommitPackage}"
              ])
              (mkRecipe "pre" "alias for pre-commit" [
                "@just pre-commit"
              ])
              (mkRecipe "pre-all" "Run pre-commit hooks on all files" [
                "${lib.getExe sysCfg.preCommitPackage} run --all-files"
              ])
            ];
          };
          release = {
            enable = true;
            justfile = lib.concatStringsSep "\n" [
              "# New minor release"
              "release:"
              "    #!/usr/bin/env bash"
              "    set -euo pipefail"
              ""
              "    # Source shared utilities"
              "    source ${lib.getExe sysCfg.releaseUtils}"
              ""
              "    echo \"🏷️  Creating new semver minor release...\" >&2"
              ""
              "    # Always operate on origin/main, regardless of current checkout"
              "    main_remote=\"origin\""
              "    main_branch=\"main\""
              ""
              "    # Use shared functions"
              "    fetch_latest \"$main_remote\" \"$main_branch\""
              "    latest_tag=$(get_latest_tag)"
              ""
              "    echo \"📋 Latest tag: $latest_tag\" >&2"
              ""
              "    # Extract version numbers (remove 'v' prefix)"
              "    version=\${latest_tag#v}"
              "    major=\${version%%.*}"
              "    minor=\${version#*.}"
              "    minor=\${minor%%.*}"
              "    patch=\${version##*.}"
              ""
              "    # Increment minor version and reset patch to 0"
              "    new_minor=$((minor + 1))"
              "    new_version=\"$major.$new_minor.0\""
              "    new_tag=\"v$new_version\""
              ""
              "    echo \"🆕 New tag: $new_tag\" >&2"
              ""
              "    # Use shared function to create and push tag"
              "    create_and_push_tag \"$new_tag\" \"$main_remote\" \"$main_branch\""
              ""
              "# Bump patch version"
              "bump:"
              "    #!/usr/bin/env bash"
              "    set -euo pipefail"
              ""
              "    # Source shared utilities"
              "    source ${lib.getExe sysCfg.releaseUtils}"
              ""
              "    echo \"🏷️  Creating new semver patch release...\" >&2"
              ""
              "    # Always operate on origin/main, regardless of current checkout"
              "    main_remote=\"origin\""
              "    main_branch=\"main\""
              ""
              "    # Use shared functions"
              "    fetch_latest \"$main_remote\" \"$main_branch\""
              "    latest_tag=$(get_latest_tag)"
              ""
              "    echo \"📋 Latest tag: $latest_tag\" >&2"
              ""
              "    # Extract version numbers (remove 'v' prefix)"
              "    version=\${latest_tag#v}"
              "    major=\${version%%.*}"
              "    minor=\${version#*.}"
              "    minor=\${minor%%.*}"
              "    patch=\${version##*.}"
              ""
              "    # Increment patch version"
              "    new_patch=$((patch + 1))"
              "    new_version=\"$major.$minor.$new_patch\""
              "    new_tag=\"v$new_version\""
              ""
              "    echo \"🆕 New tag: $new_tag\" >&2"
              ""
              "    # Use shared function to create and push tag"
              "    create_and_push_tag \"$new_tag\" \"$main_remote\" \"$main_branch\""
              ""
            ];
          };
          nix = {
            enable = true;
            justfile = lib.concatStringsSep "\n" [
              (mkRecipe "build-all" "Build all flake outputs using flake-iter" [
                "${lib.getExe sysCfg.flakeIterPackage} build"
              ])
              ""
              (mkRecipe "build-all-verbose" "Build all flake outputs with verbose output" [
                "${lib.getExe sysCfg.flakeIterPackage} build --verbose"
              ])
            ];
          };
          quarto = {
            enable = cfg.quarto.enable && cfg.quarto.sites != [];
            justfile = lib.concatStringsSep "\n" (
              # render-all recipe
              ["# Build all quarto sites"]
              ++ ["render-all:"]
              ++ (map (site: "    ${lib.getExe sysCfgQuarto.quartoPackage} render ${site}") cfg.quarto.sites)
              ++ [""]
              # Per-site recipes
              ++ lib.concatMap (site: [
                (mkRecipe "render-${site}" "render ${site}" [
                  "${lib.getExe sysCfgQuarto.quartoPackage} render ${site}"
                ])
                (mkRecipe "${site}" "preview ${site}" [
                  "${lib.getExe sysCfgQuarto.quartoPackage} preview ${site}"
                ])
              ])
              cfg.quarto.sites
            );
          };
        };
      };
    };
  };
}
