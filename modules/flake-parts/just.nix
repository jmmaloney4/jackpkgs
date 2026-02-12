{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs;

  # Import justfile generation helpers from shared lib
  justfileHelpers = import ../../lib/justfile-helpers.nix {inherit lib;};
  inherit (justfileHelpers) mkRecipe mkRecipeWithParams optionalLines;
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
      config,
      inputs',
      lib,
      pkgs,
      system,
      ...
    }: {
      options.jackpkgs.just = {
        direnvPackage = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.direnv;
          defaultText = "config.jackpkgs.pkgs.direnv";
          description = "direnv package to use.";
        };
        fdPackage = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.fd;
          defaultText = "config.jackpkgs.pkgs.fd";
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
          default = config.jackpkgs.pkgs.google-cloud-sdk;
          defaultText = "config.jackpkgs.pkgs.google-cloud-sdk";
          description = "google-cloud-sdk package to use.";
        };
        jqPackage = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.jq;
          defaultText = "config.jackpkgs.pkgs.jq";
          description = "jq package to use.";
        };
        nbstripoutPackage = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.nbstripout;
          defaultText = "config.jackpkgs.pkgs.nbstripout";
          description = "nbstripout package to use.";
        };
        npmLockfileFixPackage = mkOption {
          type = types.package;
          default = let
            npmLockfileFix =
              lib.attrByPath ["jackpkgs" "outputs" "npmLockfileFix"] null config;
          in
            if npmLockfileFix != null
            then npmLockfileFix
            else config.jackpkgs.pkgs.callPackage ../../pkgs/npm-lockfile-fix {};
          defaultText = "npm-lockfile-fix package from nodejs module or standalone";
          description = "npm-lockfile-fix package to use for fixing workspace lockfiles.";
        };
        preCommitPackage = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.pre-commit;
          defaultText = "config.jackpkgs.pkgs.pre-commit";
          description = "pre-commit package to use.";
        };
        pulumiPackage = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.pulumi-bin;
          defaultText = "config.jackpkgs.pkgs.pulumi-bin";
          description = "pulumi package to use.";
        };

        # Shared release script utilities
        releaseUtils = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.writeShellScriptBin "release-utils" (builtins.readFile ./release-utils.sh);
          defaultText = "config.jackpkgs.pkgs.writeShellScriptBin \"release-utils\" (builtins.readFile ./release-utils.sh)";
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
                ]
                false)
              (mkRecipe "r" "alias for reload" [
                  "@just reload"
                ]
                false)
            ];
          };
          infra = {
            enable = cfg.pulumi.enable; # && cfg.pulumi.backendUrl != null && cfg.pulumi.secretsProvider != null;
            justfile = let
              # Construct auth recipe commands based on configuration
              authCommands =
                (optionalLines (cfg.gcp.iamOrg != null) [
                  "GCP_ACCOUNT_USER=\"\${GCP_ACCOUNT_USER:-$USER}\""
                ])
                ++ [
                  "${lib.getExe sysCfg.googleCloudSdkPackage} auth login --update-adc${lib.optionalString (cfg.gcp.iamOrg != null) " --account=$GCP_ACCOUNT_USER@${cfg.gcp.iamOrg}"}"
                ]
                ++ optionalLines (cfg.gcp.quotaProject != null) [
                  "${lib.getExe sysCfg.googleCloudSdkPackage} auth application-default set-quota-project ${cfg.gcp.quotaProject}"
                ]
                ++ optionalLines (cfg.pulumi.enable && cfg.pulumi.backendUrl != null) [
                  "${lib.getExe sysCfg.pulumiPackage} login \"${cfg.pulumi.backendUrl}\""
                ];

              # Determine if we need a shebang (when iamOrg is set, we need multi-line bash)
              needsShebang = cfg.gcp.iamOrg != null;

              # Build the complete auth recipe using mkRecipe helper
              authRecipe =
                mkRecipe "auth"
                "Authenticate with GCP/Pulumi and refresh ADC (set GCP_ACCOUNT_USER to override username)"
                (
                  if needsShebang
                  then ["#!/usr/bin/env bash"] ++ authCommands
                  else authCommands
                )
                true; # echoCommands = true to inject "set -x" for bash recipes
            in
              lib.concatStringsSep "\n" [
                authRecipe
                # new-stack recipe
                "# Create a new Pulumi stack (usage: just new-stack <project-path> <stack-name>)"
                "new-stack project_path stack_name:"
                "    ${lib.getExe sysCfg.pulumiPackage} -C {{project_path}} login \"${cfg.pulumi.backendUrl}\""
                "    ${lib.getExe sysCfg.pulumiPackage} -C {{project_path}} stack init {{stack_name}} --secrets-provider \"${cfg.pulumi.secretsProvider}\""
                "    ${lib.getExe sysCfg.pulumiPackage} -C {{project_path}} stack select {{stack_name}}"
              ];
          };
          python = {
            enable = true;
            justfile =
              mkRecipeWithParams "nbstrip" [''notebook=""''] "Strip output from Jupyter notebooks" [
                "#!/usr/bin/env bash"
                "set -euo pipefail"
                ''if [ -z "{{notebook}}" ]; then''
                "    ${lib.getExe sysCfg.fdPackage} -e ipynb -x ${lib.getExe sysCfg.nbstripoutPackage}"
                "else"
                "    ${lib.getExe sysCfg.nbstripoutPackage} \"{{notebook}}\""
                "fi"
              ]
              true;
          };
          nodejs = {
            enable = lib.attrByPath ["jackpkgs" "nodejs" "enable"] false config;
            justfile =
              mkRecipe "fix-npm-lock" "Update and fix package-lock.json for Nix workspace caching" [
                "#!/usr/bin/env bash"
                "set -euo pipefail"
                ""
                "echo \"🔧 Updating package-lock.json...\""
                "npm install"
                ""
                "echo \"🔨 Fixing lockfile for Nix compatibility...\""
                "${lib.getExe sysCfg.npmLockfileFixPackage} ./package-lock.json"
                ""
                "echo \"✅ Done! Review changes with: git diff package-lock.json\""
                "echo \"Then commit: git add package-lock.json && git commit -m 'chore: normalize lockfile via npm-lockfile-fix'\""
              ]
              true;
          };
          git = {
            enable = true;
            justfile = lib.concatStringsSep "\n" [
              (mkRecipe "pre-commit" "Run pre-commit hooks" [
                  "${lib.getExe sysCfg.preCommitPackage}"
                ]
                false)
              (mkRecipe "pre" "alias for pre-commit" [
                  "@just pre-commit"
                ]
                false)
              (mkRecipe "pre-all" "Run pre-commit hooks on all files" [
                  "${lib.getExe sysCfg.preCommitPackage} run --all-files"
                ]
                false)
            ];
          };
          release = {
            enable = true;
            justfile = lib.concatStringsSep "\n" [
              "# New minor release"
              "release:"
              "    #!/usr/bin/env bash"
              "    set -euo pipefail"
              "    set -x"
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
              "    set -x"
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
                  "${lib.getExe' sysCfg.flakeIterPackage "flake-iter"} build"
                ]
                false)
              ""
              (mkRecipe "build-all-verbose" "Build all flake outputs with verbose output" [
                  "${lib.getExe' sysCfg.flakeIterPackage "flake-iter"} build --verbose"
                ]
                false)
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
                  ]
                  false)
                (mkRecipe "${site}" "preview ${site}" [
                    "${lib.getExe sysCfgQuarto.quartoPackage} preview ${site}"
                  ]
                  false)
              ])
              cfg.quarto.sites
            );
          };
        };
      };
    };
  };
}
