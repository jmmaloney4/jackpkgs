{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  options,
  ...
} @ moduleTop: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs;
  pythonEnvHelpers = import ../../lib/python-env-selection.nix {inherit lib;};

  # Import justfile generation helpers from shared lib
  justfileHelpers = import ../../lib/justfile-helpers.nix {inherit lib;};
  inherit (justfileHelpers) mkRecipe mkRecipeWithParams optionalLines;

  # Access checks config if the checks module is loaded
  checksOptionsDefined = lib.hasAttrByPath ["jackpkgs" "checks"] options;
in {
  imports = [
    jackpkgsInputs.just-flake.flakeModule
    (import ./gcp.nix {inherit jackpkgsInputs;})
  ];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.just = {
      enable = mkEnableOption "jackpkgs-just-flake" // {default = true;};
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
        ruffPackage = mkOption {
          type = types.package;
          defaultText = ''
            Dev-tools Python env (same precedence as `checks.nix` / `pre-commit.nix`):
            1. `jackpkgs.python.environments.dev` if non-editable and `includeGroups = true`
            2. Any non-editable `jackpkgs.python.environments.*` with `includeGroups = true`
            3. Auto-created env with `includeGroups = true` (via `pythonWorkspace`)
            4. `config.jackpkgs.outputs.pythonDefaultEnv` (when defined)
            5. `config.jackpkgs.pkgs.ruff`
          '';
          description = ''
            ruff package (or Python environment containing ruff) to use for the
            `just lint` Python lint step.

            Defaults to the same dev-tools environment selection used by
            `checks.nix` CI checks and pre-commit hooks, preferring a
            non-editable environment with dependency groups enabled.
          '';
        };
        mypyPackage = mkOption {
          type = types.package;
          defaultText = ''
            Dev-tools Python env (same precedence as `checks.nix` / `pre-commit.nix`):
            1. `jackpkgs.python.environments.dev` if non-editable and `includeGroups = true`
            2. Any non-editable `jackpkgs.python.environments.*` with `includeGroups = true`
            3. Auto-created env with `includeGroups = true` (via `pythonWorkspace`)
            4. `config.jackpkgs.outputs.pythonDefaultEnv` (when defined)
            5. `config.jackpkgs.pkgs.mypy`
          '';
          description = ''
            mypy package (or Python environment containing mypy) to use for the
            `just lint` Python type-check step.
          '';
        };
        tyPackage = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.ty;
          defaultText = "config.jackpkgs.pkgs.ty";
          description = ''
            `ty` binary package to use when
            `jackpkgs.checks.python.mypy.typeChecker = "ty"`.
            Defaults to `config.jackpkgs.pkgs.ty` (nixpkgs).
          '';
        };
        biomePackage = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.biome;
          defaultText = "config.jackpkgs.pkgs.biome";
          description = "biome package to use for JS/TS linting.";
        };

        # Shared release script utilities
        releaseUtils = mkOption {
          type = types.package;
          default = config.jackpkgs.pkgs.writeShellScriptBin "release-utils" (builtins.readFile ./release-utils.sh);
          defaultText = "config.jackpkgs.pkgs.writeShellScriptBin \"release-utils\" (builtins.readFile ./release-utils.sh)";
          description = "Shared utilities for release scripts.";
        };

        # Unified cut release recipe
        cut = {
          enable = mkEnableOption "unified cut release recipe" // {default = false;};
          files = mkOption {
            type = types.listOf (types.submodule {
              options = {
                type = mkOption {
                  type = types.enum ["npm"];
                  description = "File type for version bumping.";
                };
                path = mkOption {
                  type = types.str;
                  description = "Repository-relative path to the version file.";
                };
              };
            });
            default = [];
            description = "Version files to bump on release.";
          };
          commitMessage = mkOption {
            type = types.str;
            default = "release: bump to {version}";
            description = "Commit message template. {version} is replaced with the new version.";
          };
          branch = mkOption {
            type = types.str;
            default = "main";
            description = "Branch that releases must be cut from.";
          };
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
      checksCfgForRecipes = lib.attrByPath ["jackpkgs" "checks"] {} moduleTop.config;
      pythonCfgForDevTools = cfg.python or {};
      pythonWorkspaceForDevTools = config._module.args.pythonWorkspace or null;
      pythonEnvOutputsForDevTools = let
        fromFlake = lib.attrByPath ["jackpkgs" "outputs" "pythonEnvironments"] {} moduleTop.config;
        fromSystem = lib.attrByPath ["jackpkgs" "outputs" "pythonEnvironments"] {} config;
      in
        fromFlake // fromSystem;
      pythonDefaultEnvForDevTools = let
        fromSystem = lib.attrByPath ["jackpkgs" "outputs" "pythonDefaultEnv"] null config;
        fromFlake = lib.attrByPath ["jackpkgs" "outputs" "pythonDefaultEnv"] null moduleTop.config;
      in
        if fromSystem != null
        then fromSystem
        else fromFlake;
      justMypyPackageDefault = pythonEnvHelpers.selectDevToolsPackage {
        pythonCfg = pythonCfgForDevTools;
        pythonWorkspace = pythonWorkspaceForDevTools;
        pythonEnvOutputs = pythonEnvOutputsForDevTools;
        pythonDefaultEnv = pythonDefaultEnvForDevTools;
        fallbackPackage = config.jackpkgs.pkgs.mypy;
      };
      justRuffPackageDefault = pythonEnvHelpers.selectDevToolsPackage {
        pythonCfg = pythonCfgForDevTools;
        pythonWorkspace = pythonWorkspaceForDevTools;
        pythonEnvOutputs = pythonEnvOutputsForDevTools;
        pythonDefaultEnv = pythonDefaultEnvForDevTools;
        fallbackPackage = config.jackpkgs.pkgs.ruff;
      };
    in {
      jackpkgs.just.mypyPackage = lib.mkDefault justMypyPackageDefault;
      jackpkgs.just.ruffPackage = lib.mkDefault justRuffPackageDefault;
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
              gcloudExe = lib.getExe sysCfg.googleCloudSdkPackage;

              # Computed display values for auth header
              adcPath =
                if cfg.gcp.profile != null
                then "~/.config/gcloud-profiles/${cfg.gcp.profile}/application_default_credentials.json"
                else "~/.config/gcloud/application_default_credentials.json";
              gcpAccountLabel =
                if cfg.gcp.iamOrg != null
                then "\${GCP_ACCOUNT_USER:-\$USER}@${cfg.gcp.iamOrg}"
                else "(selected in browser)";

              # Construct auth recipe commands based on configuration
              authCommands =
                # Header: show what we're targeting
                [
                  "echo ''"
                  "echo -e \"\\033[1mAuthentication Targets\\033[0m\""
                  "echo \"  GCP Account:   ${gcpAccountLabel}\""
                ]
                ++ optionalLines (cfg.gcp.quotaProject != null) [
                  "echo \"  Billing:       ${cfg.gcp.quotaProject}\""
                ]
                ++ optionalLines (cfg.pulumi.enable && cfg.pulumi.backendUrl != null) [
                  "echo \"  Pulumi:        ${cfg.pulumi.backendUrl}\""
                ]
                ++ [
                  "echo \"  ADC:           ${adcPath}\""
                  "echo ''"
                ]
                # Step 1: GCP login + ADC refresh
                ++ [
                  "echo -e \"\\033[1m→ Refreshing GCP credentials & ADC\\033[0m\""
                ]
                ++ (optionalLines (cfg.gcp.iamOrg != null) [
                  "GCP_ACCOUNT_USER=\"\${GCP_ACCOUNT_USER:-$USER}\""
                ])
                ++ [
                  # Unset GOOGLE_APPLICATION_CREDENTIALS for this call only: when it is set,
                  # gcloud prompts Y/n before overwriting the ADC file even though it would
                  # write to the same location. env -u avoids the interactive prompt.
                  "env -u GOOGLE_APPLICATION_CREDENTIALS ${gcloudExe} auth login --update-adc${lib.optionalString (cfg.gcp.iamOrg != null) " --account=$GCP_ACCOUNT_USER@${cfg.gcp.iamOrg}"}"
                ]
                # Step 2: Set ADC billing project
                ++ optionalLines (cfg.gcp.quotaProject != null) [
                  "echo ''"
                  "echo -e \"\\033[1m→ Setting ADC billing project to ${cfg.gcp.quotaProject}\\033[0m\""
                  "${gcloudExe} auth application-default set-quota-project ${cfg.gcp.quotaProject}"
                ]
                # Step 3: Pulumi backend login
                ++ optionalLines (cfg.pulumi.enable && cfg.pulumi.backendUrl != null) [
                  "echo ''"
                  "echo -e \"\\033[1m→ Logging into Pulumi backend\\033[0m\""
                  "${lib.getExe' sysCfg.pulumiPackage "pulumi"} login \"${cfg.pulumi.backendUrl}\""
                ];

              # Build the complete auth recipe using mkRecipe helper
              authRecipe =
                mkRecipe "auth"
                "Authenticate with GCP/Pulumi and refresh ADC (set GCP_ACCOUNT_USER to override username)"
                (["#!/usr/bin/env bash" "set -euo pipefail"] ++ authCommands)
                false;

              # auth-status recipe - shows current GCP authentication status
              # Available when profile isolation is enabled
              authStatusRecipe =
                mkRecipe "auth-status" "Show current GCP authentication status"
                [
                  "#!/usr/bin/env bash"
                  "echo \"Profile:  \${CLOUDSDK_CONFIG:-~/.config/gcloud (default)}\""
                  "echo \"Account:  $(${gcloudExe} config get-value account 2>/dev/null || echo 'not set')\""
                  "echo \"Project:  $(${gcloudExe} config get-value project 2>/dev/null || echo 'not set')\""
                  "if ${gcloudExe} auth print-access-token --quiet >/dev/null 2>&1; then"
                  "    echo \"Token:    valid\""
                  "else"
                  "    echo \"Token:    EXPIRED — run 'just auth'\""
                  "fi"
                ]
                false;
            in
              lib.concatStringsSep "\n" (
                [authRecipe]
                ++ lib.optional (cfg.gcp.profile != null) authStatusRecipe
                ++ lib.optional (cfg.pulumi.enable && cfg.pulumi.stacks != []) config.jackpkgs.outputs.pulumiJustfile
                ++ lib.optional cfg.kubeconfig.enable config.jackpkgs.outputs.kubeconfigJustfile
                ++ [
                  # new-stack recipe
                  "# Create a new Pulumi stack (usage: just new-stack <project-path> <stack-name>)"
                  "new-stack project_path stack_name:"
                  "    ${lib.getExe' sysCfg.pulumiPackage "pulumi"} -C {{project_path}} login \"${cfg.pulumi.backendUrl}\""
                  "    ${lib.getExe' sysCfg.pulumiPackage "pulumi"} -C {{project_path}} stack init {{stack_name}} --secrets-provider ${lib.escapeShellArg cfg.pulumi.secretsProvider}"
                  "    ${lib.getExe' sysCfg.pulumiPackage "pulumi"} -C {{project_path}} stack select {{stack_name}}"
                ]
              );
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
          release = let
            cutCfg = sysCfg.cut;
            hasFiles = cutCfg.files != [];
            npmFiles = lib.filter (f: f.type == "npm") cutCfg.files;
            allFilePaths = map (f: f.path) cutCfg.files;
            commitMsg = lib.replaceStrings ["{version}"] ["\${new_version}"] cutCfg.commitMessage;

            # Generate npm version bump commands at Nix eval time
            npmBumpCommands =
              map (
                f: "node -e \"const fs = require('fs'); const p = process.argv[1]; const j = JSON.parse(fs.readFileSync(p)); j.version = '\${new_version}'; fs.writeFileSync(p, JSON.stringify(j, null, '\\t') + '\\n');\" \"${f.path}\""
              )
              npmFiles;

            # Commands for the cut recipe when files are configured
            cutWithFilesCommands =
              [
                "#!/usr/bin/env bash"
                "set -euo pipefail"
                ""
                "branch=$(git branch --show-current)"
                "if [ \"$branch\" != ${lib.escapeShellArg cutCfg.branch} ]; then"
                "  echo \"Must be on ${lib.escapeShellArg cutCfg.branch} (currently on \${branch})\" >&2"
                "  exit 1"
                "fi"
                ""
                "if ! git diff --quiet || ! git diff --cached --quiet; then"
                "  echo \"Working tree dirty. Commit or stash first.\" >&2"
                "  exit 1"
                "fi"
                ""
                "git pull --ff-only origin ${lib.escapeShellArg cutCfg.branch}"
                ""
                "source ${lib.getExe sysCfg.releaseUtils}"
                "latest_tag=$(get_latest_tag)"
                ""
                "    version=\${latest_tag#v}"
                "IFS='.' read -r major minor patch <<< \"\$version\""
                ""
                "case \"{{level}}\" in"
                "  patch) new_version=\"\$major.\$minor.\$((patch + 1))\" ;;"
                "  minor) new_version=\"\$major.\$((minor + 1)).0\" ;;"
                "  major) new_version=\"\$((major + 1)).0.0\" ;;"
                "  *)     echo \"Unknown level: {{level}} (use patch, minor, or major)\" >&2; exit 1 ;;"
                "esac"
                ""
                "new_tag=\"v\$new_version\""
                "echo \"\${latest_tag} -> \${new_tag} ({{level}})\""
              ]
              ++ npmBumpCommands
              ++ [
                ""
                "git add ${lib.escapeShellArgs allFilePaths}"
                "git commit -m ${lib.escapeShellArg commitMsg}"
                ""
                "git tag -a \"\$new_tag\" -m \"Release \$new_tag\""
                "git push --atomic origin ${lib.escapeShellArg cutCfg.branch} \"\$new_tag\""
                ""
                "echo \"Cut \${new_tag} and pushed to origin.\""
              ];

            # Commands for the cut recipe when no files configured (tag-only)
            cutTagOnlyCommands = [
              "#!/usr/bin/env bash"
              "set -euo pipefail"
              "set -x"
              ""
              "source ${lib.getExe sysCfg.releaseUtils}"
              ""
              "main_remote=\"origin\""
              "main_branch=${lib.escapeShellArg cutCfg.branch}"
              ""
              "fetch_latest \"\$main_remote\" \"\$main_branch\""
              "latest_tag=$(get_latest_tag)"
              "    # Extract version numbers (remove 'v' prefix)"
              "    version=\${latest_tag#v}"
              "    major=\${version%%.*}"
              "    minor=\${version#*.}"
              "    minor=\${minor%%.*}"
              "    patch=\${version##*.}"
              ""
              "case \"{{level}}\" in"
              "  patch) new_patch=\$((patch + 1)); new_version=\"\$major.\$minor.\$new_patch\" ;;"
              "  minor) new_minor=\$((minor + 1)); new_version=\"\$major.\$new_minor.0\" ;;"
              "  major) new_major=\$((major + 1)); new_version=\"\$new_major.0.0\" ;;"
              "  *)     echo \"Unknown level: {{level}}\" >&2; exit 1 ;;"
              "esac"
              ""
              "new_tag=\"v\$new_version\""
              "target_commit=$(git rev-parse \"\$main_remote/\$main_branch\")"
              "git tag -a \"\$new_tag\" -m \"Release \$new_tag\" \"\$target_commit\""
              "git push \"\$main_remote\" \"\$new_tag\""
            ];

            cutCommands =
              if hasFiles
              then cutWithFilesCommands
              else cutTagOnlyCommands;

            cutJustfile = lib.concatStringsSep "\n" [
              (mkRecipeWithParams "cut" [''level="patch"''] "Cut a release: bump version files, commit, tag, push (patch|minor|major)" cutCommands false)
              ""
              "# Bump patch version"
              "bump:"
              "    @just cut \"patch\""
              ""
              "# New minor release"
              "release:"
              "    @just cut \"minor\""
              ""
            ];
          in {
            enable = true;
            justfile =
              if cutCfg.enable
              then cutJustfile
              else
                lib.concatStringsSep "\n" [
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
              ""
              (mkRecipe "checks" "Run each flake check derivation individually (jj-friendly, no pre-commit)" [
                  "#!/usr/bin/env bash"
                  "set -euo pipefail"
                  "system=$(nix eval --impure --raw --expr builtins.currentSystem)"
                  "checks_json=$(nix eval --json \".#checks.\${system}\")"
                  "printf '%s' \"$checks_json\" | ${lib.getExe sysCfg.jqPackage} -r 'keys[]' | while IFS= read -r check; do"
                  "  echo \"==> running check: $check\""
                  "  nix build -L \".#checks.\${system}.$check\""
                  "done"
                ]
                false)
              ""
              (mkRecipeWithParams "lint" [''dry_run="false"''] "Run lint tools from flake config; fixes in place unless dry_run=true" (
                  [
                    "#!/usr/bin/env bash"
                    "set -euo pipefail"
                    "dry_run='{{dry_run}}'"
                  ]
                  ++ (optionalLines (checksOptionsDefined && checksCfgForRecipes.python.ruff.enable) [
                    ""
                    "# ruff (Python linter)"
                    "if ${lib.getExe sysCfg.fdPackage} -q -e py -e pyi; then"
                    "  printf '%s\\n' \"==> ruff\""
                    "  if [ \"$dry_run\" = \"true\" ]; then"
                    "    ${lib.getExe' sysCfg.ruffPackage "ruff"} check --quiet ."
                    "  else"
                    "    ${lib.getExe' sysCfg.ruffPackage "ruff"} check --fix --quiet ."
                    "  fi"
                    "fi"
                  ])
                  ++ (optionalLines (checksOptionsDefined && checksCfgForRecipes.python.mypy.enable) (
                    let
                      typeChecker = checksCfgForRecipes.python.mypy.typeChecker or "mypy";
                      extraArgs = lib.escapeShellArgs checksCfgForRecipes.python.mypy.extraArgs;
                    in
                      if typeChecker == "ty"
                      then [
                        ""
                        "# ty (Python type checker)"
                        "if ${lib.getExe sysCfg.fdPackage} -q -e py -e pyi; then"
                        "  printf '%s\\n' \"==> ty check\""
                        "  ${lib.getExe sysCfg.tyPackage} check --python ${sysCfg.mypyPackage} ${extraArgs} ."
                        "fi"
                      ]
                      else [
                        ""
                        "# mypy (Python type checker) [deprecated: migrate to ty]"
                        "if ${lib.getExe sysCfg.fdPackage} -q -e py -e pyi; then"
                        "  printf '%s\\n' \"==> mypy\""
                        "  echo 'WARNING: mypy is deprecated. Migrate to ty: jackpkgs.checks.python.mypy.typeChecker = \"ty\"' >&2"
                        ''${lib.getExe' sysCfg.mypyPackage "mypy"} ${extraArgs} .''
                        "fi"
                      ]
                  ))
                  ++ (optionalLines (checksOptionsDefined && lib.attrByPath ["biome" "lint" "enable"] false checksCfgForRecipes) [
                    ""
                    "# biome (JS/TS linter)"
                    "printf '%s\\n' \"==> biome lint\""
                    "if [ \"$dry_run\" = \"true\" ]; then"
                    "  ${lib.getExe sysCfg.biomePackage} lint ."
                    "else"
                    "  ${lib.getExe sysCfg.biomePackage} lint --write ."
                    "fi"
                  ])
                  ++ (optionalLines (checksOptionsDefined && checksCfgForRecipes.typescript.tsc.enable) (
                    let
                      tscPackages = checksCfgForRecipes.typescript.tsc.packages;
                      extraArgs = lib.escapeShellArgs checksCfgForRecipes.typescript.tsc.extraArgs;
                    in
                      if tscPackages != null && tscPackages != []
                      then [
                        ""
                        "# tsc (TypeScript type checker)"
                        "for _tsc_project in ${lib.escapeShellArgs tscPackages}; do"
                        "  if [ -f \"\${_tsc_project}/tsconfig.json\" ]; then"
                        "    printf '%s\\n' \"==> tsc (\${_tsc_project})\""
                        "    tsc --noEmit --project \"\${_tsc_project}/tsconfig.json\" ${extraArgs}"
                        "  fi"
                        "done"
                      ]
                      else [
                        ""
                        "# tsc (TypeScript type checker)"
                        "if [ -f tsconfig.json ]; then"
                        "  printf '%s\\n' \"==> tsc\""
                        "  pnpm exec tsc --noEmit ${extraArgs}"
                        "fi"
                      ]
                  ))
                  ++ [
                    ""
                    "printf '%s\\n' \"All lint checks passed.\""
                  ]
                )
                false)
              (mkRecipe "test" "Run unit and integration tests (pytest, vitest)" (
                  let
                    pytestExtraArgs = lib.escapeShellArgs checksCfgForRecipes.python.pytest.extraArgs;
                    vitestExtraArgs = lib.escapeShellArgs checksCfgForRecipes.vitest.extraArgs;
                    vitestPackages = checksCfgForRecipes.vitest.packages;
                  in
                    [
                      "#!/usr/bin/env bash"
                      "set -euo pipefail"
                    ]
                    ++ (optionalLines (checksOptionsDefined && checksCfgForRecipes.python.pytest.enable) [
                      ""
                      "# pytest (Python tests)"
                      "if ${lib.getExe sysCfg.fdPackage} -q -e py -e pyi; then"
                      "  printf '%s\\n' \"==> pytest\""
                      "  pytest ${pytestExtraArgs}"
                      "fi"
                    ])
                    ++ (optionalLines (checksOptionsDefined && checksCfgForRecipes.vitest.enable) (
                      if vitestPackages != null && vitestPackages != []
                      then [
                        ""
                        "# vitest (JS/TS tests)"
                        "for _vitest_pkg in ${lib.escapeShellArgs vitestPackages}; do"
                        "  if [ -f \"\${_vitest_pkg}/package.json\" ]; then"
                        "    printf '%s\\n' \"==> vitest (\${_vitest_pkg})\""
                        "    (cd \"\${_vitest_pkg}\" && pnpm exec vitest run --passWithNoTests${lib.optionalString (vitestExtraArgs != "") " ${vitestExtraArgs}"})"
                        "  fi"
                        "done"
                      ]
                      else [
                        ""
                        "# vitest (JS/TS tests)"
                        "if [ -f package.json ]; then"
                        "    printf '%s\\n' \"==> vitest\""
                        "    pnpm exec vitest run --passWithNoTests${lib.optionalString (vitestExtraArgs != "") " ${vitestExtraArgs}"}"
                        "fi"
                      ]
                    ))
                    ++ [
                      ""
                      "printf '%s\\n' \"All tests passed.\""
                    ]
                )
                false)
            ];
          };
          nodejs = {
            enable = cfg.nodejs.enable;
            justfile = lib.concatStringsSep "\n" [
              (mkRecipe "update-pnpm-hash" "Refresh pnpm-lock.yaml and update pnpmDepsHash in flake.nix" [
                  "#!/usr/bin/env bash"
                  "set -euo pipefail"
                  ""
                  "flake=\"flake.nix\""
                  "backup=$(mktemp)"
                  "build_log=$(mktemp)"
                  "updated=0"
                  ""
                  "cp \"$flake\" \"$backup\""
                  "trap 'rm -f \"$build_log\"; if [ \"$updated\" -eq 0 ]; then mv \"$backup\" \"$flake\"; else rm -f \"$backup\"; fi' EXIT"
                  ""
                  "echo \"📦 Running pnpm install to refresh pnpm-lock.yaml...\""
                  "pnpm install"
                  ""
                  "system=$(nix eval --raw --impure --expr 'builtins.currentSystem')"
                  "echo \"🔍 Detecting system: $system\""
                  ""
                  "echo \"📝 Setting empty pnpmDepsHash (per ERR_PNPM_NO_OFFLINE_TARBALL guidance) to trigger hash mismatch...\""
                  ''node -e 'const fs = require(\"node:fs\"); const path = process.argv[1]; const contents = fs.readFileSync(path, \"utf8\"); const pattern = /^[ \t]*#?[ \t]*pnpmDepsHash = .*$/m; if (!pattern.test(contents)) { throw new Error(\"Could not locate pnpmDepsHash in flake.nix\"); } fs.writeFileSync(path, contents.replace(pattern, \"        pnpmDepsHash = \\\"\\\";\"));' \"$flake\"''
                  ""
                  "echo \"🔨 Building devshell to fetch new hash...\""
                  "nix build \".#devShells.\${system}.default\" >\"$build_log\" 2>&1 || true"
                  ''new_hash=$(node -e 'const fs = require("node:fs"); const log = fs.readFileSync(process.argv[1], "utf8"); const match = log.match(/got:\s*(sha256-[A-Za-z0-9+/=]+)/); if (match) { process.stdout.write(match[1]); }' "$build_log")''
                  ""
                  "if [ -z \"$new_hash\" ]; then"
                  "    echo \"❌ Could not extract new hash from nix output\""
                  "    echo \"Output was:\""
                  "    cat \"$build_log\""
                  "    exit 1"
                  "fi"
                  ""
                  "echo \"✅ New hash: $new_hash\""
                  "echo \"📝 Updating $flake...\""
                  ''NEW_HASH="$new_hash" node -e 'const fs = require("node:fs"); const path = process.argv[1]; const contents = fs.readFileSync(path, "utf8"); const pattern = /^[ \t]*#?[ \t]*pnpmDepsHash = .*$/m; if (!pattern.test(contents)) { throw new Error("Could not locate pnpmDepsHash in flake.nix"); } fs.writeFileSync(path, contents.replace(pattern, "        pnpmDepsHash = \"" + process.env.NEW_HASH + "\";"));' "$flake"''
                  "updated=1"
                  ""
                  "echo \"✅ Done! pnpmDepsHash updated to $new_hash\""
                ]
                false)
              (mkRecipe "update-pnpm-deps" "alias for update-pnpm-hash" [
                  "@just update-pnpm-hash"
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
