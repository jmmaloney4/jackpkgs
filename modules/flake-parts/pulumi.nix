{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.pulumi;
  gcpCfg = config.jackpkgs.gcp;

  justfileHelpers = import ../../lib/justfile-helpers.nix {inherit lib;};
  inherit (justfileHelpers) mkRecipe mkRecipeWithParams optionalLines;
in {
  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.pulumi = {
      enable = mkEnableOption "jackpkgs-pulumi" // {default = true;};

      backendUrl = mkOption {
        type = types.str;
        description = "Pulumi backend URL to use for authentication and stack operations. Required when enable is true.";
      };

      secretsProvider = mkOption {
        type = types.str;
        description = "Pulumi secrets provider to use for authentication and stack operations. Required when enable is true.";
      };

      stacks = mkOption {
        type = types.listOf (types.submodule {
          options = {
            path = mkOption {
              type = types.str;
              description = "Path to the Pulumi project directory (relative to repo root).";
            };
            stacks = mkOption {
              type = types.listOf types.str;
              description = "Stack names available for this project (e.g. [\"dev\" \"stage\" \"prod\"]).";
            };
            alwaysDeploy = mkOption {
              type = types.bool;
              default = false;
              description = ''
                When true, this project is always deployed regardless of the selected
                environment stack. The effective stack is determined by matching the
                requested env against the project's stacks list; if no match is found,
                the first entry in stacks is used as a fallback.
              '';
            };
          };
        });
        default = [];
        description = "List of Pulumi projects and their available stacks, deployed in order.";
      };

      defaultStack = mkOption {
        type = types.str;
        default = "dev";
        description = "Default stack name used when not specified in preview/deploy commands.";
      };

      ci.authMode = mkOption {
        type = types.enum ["workload-identity" "application-default-credentials"];
        default = "workload-identity";
        description = ''
          Authentication mode for the ci-pulumi devShell.

          - `"workload-identity"` (default): rely on `GOOGLE_WORKLOAD_IDENTITY_PROVIDER`
            and `GOOGLE_SERVICE_ACCOUNT_EMAIL` injected by the CI runner (e.g. via
            google-github-actions/auth). `GOOGLE_APPLICATION_CREDENTIALS` is NOT set,
            so ADC falls through to ambient WIF credentials. Use this for GitHub
            Actions with Workload Identity Federation.

          - `"application-default-credentials"`: set `GOOGLE_APPLICATION_CREDENTIALS`
            to the per-profile ADC file under `$HOME/.config/gcloud-profiles/<profile>/`.
            Requires `jackpkgs.gcp.profile` to be non-null. Use this for self-hosted
            runners or local testing of the CI shell against a named gcloud profile.
        '';
      };
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.outputs.pulumiDevShell = mkOption {
        type = types.package;
        readOnly = true;
        description = "Pulumi devShell fragment to include in `inputsFrom`.";
      };

      options.jackpkgs.pulumi.ci.packages = mkOption {
        type = with types; listOf package;
        default = with config.jackpkgs.pkgs; [
          pulumi-bin
          nodejs
          jq
          (google-cloud-sdk.withExtraComponents [google-cloud-sdk.components.gke-gcloud-auth-plugin])
        ];
        defaultText = lib.literalExpression ''
          with config.jackpkgs.pkgs; [
            pulumi-bin
            nodejs
            jq
            (google-cloud-sdk.withExtraComponents [google-cloud-sdk.components.gke-gcloud-auth-plugin])
          ]
        '';
        description = "Packages included in the ci-pulumi devshell";
      };

      options.jackpkgs.outputs.pulumiJustfile = mkOption {
        type = types.str;
        readOnly = true;
        description = "Generated justfile fragment for pulumi preview/deploy commands.";
      };
    });
  };

  config =
    mkIf cfg.enable
    {
      perSystem = {
        pkgs,
        lib,
        config,
        ...
      }: let
        pulumiExe = lib.getExe' pkgs.pulumi-bin "pulumi";
        stacks = cfg.stacks;
        defaultStack = cfg.defaultStack;

        # Shared base env vars present in every Pulumi shell.
        pulumiBaseEnv = {
          PULUMI_IGNORE_AMBIENT_PLUGINS = "1";
          PULUMI_BACKEND_URL = cfg.backendUrl;
          PULUMI_SECRETS_PROVIDER = cfg.secretsProvider;
          PULUMI_OPTION_NON_INTERACTIVE = "true";
          PULUMI_OPTION_COLOR = "never";
          PULUMI_OPTION_SUPPRESS_PROGRESS = "true";
        };

        # ADC file path for the active gcp.profile (null-safe: only used when profile != null).
        # Validate that profile is set when authMode requires it.
        profileAdcPath =
          if cfg.ci.authMode == "application-default-credentials" && gcpCfg.profile == null
          then throw "jackpkgs.pulumi.ci.authMode 'application-default-credentials' requires jackpkgs.gcp.profile to be set"
          else
            lib.optionalAttrs (gcpCfg.profile != null) {
              GOOGLE_APPLICATION_CREDENTIALS = "$HOME/.config/gcloud-profiles/${gcpCfg.profile}/application_default_credentials.json";
            };

        ciPulumiEnv =
          pulumiBaseEnv
          // lib.optionalAttrs (cfg.ci.authMode == "application-default-credentials") profileAdcPath;
      in {
        jackpkgs.outputs.pulumiDevShell = pkgs.mkShell {
          packages = with pkgs; [
            pulumi-bin
            nodejs
            jq
            just
            (google-cloud-sdk.withExtraComponents [google-cloud-sdk.components.gke-gcloud-auth-plugin])
            nodePackages.typescript
          ];
          # Dev shell always sets GOOGLE_APPLICATION_CREDENTIALS when a profile is
          # active: Go-based GCP clients (including Pulumi providers) do not honour
          # CLOUDSDK_CONFIG and require this explicit env var (see issue #182 and
          # ADR 027).
          env = pulumiBaseEnv // profileAdcPath;
        };

        devShells.ci-pulumi = pkgs.mkShell {
          packages = config.jackpkgs.pulumi.ci.packages;

          # CI shell auth strategy is controlled by jackpkgs.pulumi.ci.authMode:
          #   "workload-identity" (default) — do not bake GOOGLE_APPLICATION_CREDENTIALS;
          #     WIF credentials are injected by the CI runner (google-github-actions/auth).
          #   "application-default-credentials" — set GOOGLE_APPLICATION_CREDENTIALS to
          #     the profile ADC file; requires jackpkgs.gcp.profile to be non-null.
          env = ciPulumiEnv;
        };

        jackpkgs.shell.inputsFrom = [
          config.jackpkgs.outputs.pulumiDevShell
        ];

        # Verify that the ci-pulumi env block is well-formed and that authMode
        # controls GOOGLE_APPLICATION_CREDENTIALS as expected.
        checks.pulumi-ci-env = pkgs.runCommand "pulumi-ci-env-check" {} ''
          set -euo pipefail
          ciEnv=${lib.escapeShellArg (builtins.toJSON ciPulumiEnv)}
          echo "ci-pulumi env: $ciEnv"

          # PULUMI_IGNORE_AMBIENT_PLUGINS must always be present.
          echo $ciEnv | ${pkgs.jq}/bin/jq -e '.PULUMI_IGNORE_AMBIENT_PLUGINS == "1"' \
            || (echo "FAIL: PULUMI_IGNORE_AMBIENT_PLUGINS missing or wrong"; exit 1)

          authMode='${cfg.ci.authMode}'
          if [ "$authMode" = "workload-identity" ]; then
            # WIF mode: GOOGLE_APPLICATION_CREDENTIALS must NOT be set.
            echo $ciEnv | ${pkgs.jq}/bin/jq -e '.GOOGLE_APPLICATION_CREDENTIALS == null' \
              || (echo "FAIL: GOOGLE_APPLICATION_CREDENTIALS must not be set in workload-identity mode"; exit 1)
          else
            # ADC mode: GOOGLE_APPLICATION_CREDENTIALS must be present.
            echo $ciEnv | ${pkgs.jq}/bin/jq -e '.GOOGLE_APPLICATION_CREDENTIALS != null' \
              || (echo "FAIL: GOOGLE_APPLICATION_CREDENTIALS must be set in application-default-credentials mode"; exit 1)
          fi

          touch $out
        '';

        jackpkgs.outputs.pulumiJustfile = let
          hasStacks = stacks != [];
          projectCount = builtins.length stacks;

          allStackNames = lib.unique (lib.concatMap (s: s.stacks) stacks);
          displayStacks = lib.concatStringsSep ", " allStackNames;

          validationLogic =
            [
              "# Validate stack name"
              "valid_stacks=()"
            ]
            ++ map (stack: "valid_stacks+=(${lib.escapeShellArg stack})") allStackNames
            ++ [
              "is_valid=0"
              "for s in \"\${valid_stacks[@]}\"; do"
              "    if [[ \"\$s\" == \"\$env\" ]]; then"
              "        is_valid=1"
              "        break"
              "    fi"
              "done"
              "if [[ \$is_valid -eq 0 ]]; then"
              "    valid_stacks_display=${lib.escapeShellArg displayStacks}"
              "    printf '❌ Unknown stack: %s (valid: %s)\\n' \"\$env\" \"\$valid_stacks_display\""
              "    exit 1"
              "fi"
            ];

          previewRecipe =
            mkRecipeWithParams "preview" [''env="${defaultStack}"''] "Preview changes for all Pulumi projects (run 'just deploy' to apply)"
            ([
                "#!/usr/bin/env bash"
                "set -euo pipefail"
                "env=\"\${1:-${defaultStack}}\""
                ""
              ]
              ++ validationLogic
              ++ [
                ""
                "echo \"🔍 Previewing all Pulumi projects for \$env stack...\""
                ""
              ]
              ++ lib.concatMap (s: let
                escapedPath = lib.escapeShellArg s.path;
                fallbackStack = lib.escapeShellArg (lib.head s.stacks);
                projectStackChecks = lib.concatStringsSep " || " (map (stack: "[[ \"\$env\" == ${lib.escapeShellArg stack} ]]") s.stacks);
              in
                if s.alwaysDeploy
                then [
                  "echo \"\""
                  "project_path=${escapedPath}"
                  "# Determine effective stack: use env if it matches, else fallback to ${lib.head s.stacks}"
                  "if ${projectStackChecks}; then"
                  "    _effective_stack=\"\$env\""
                  "else"
                  "    _effective_stack=${fallbackStack}"
                  "fi"
                  "printf '📦 Previewing %s (stack: %s, alwaysDeploy)...\\n' \"\$project_path\" \"\$_effective_stack\""
                  "${pulumiExe} -C \"\$project_path\" preview --stack \"\$_effective_stack\""
                ]
                else [
                  "echo \"\""
                  "project_path=${escapedPath}"
                  "if ${projectStackChecks}; then"
                  "    printf '📦 Previewing %s (stack: %s)...\\n' \"\$project_path\" \"\$env\""
                  "    ${pulumiExe} -C \"\$project_path\" preview --stack \"\$env\""
                  "else"
                  "    printf '⏭️  Skipping %s (stack %s not configured for this project)\\n' \"\$project_path\" \"\$env\""
                  "fi"
                ])
              stacks
              ++ [
                ""
                "echo \"\""
                "echo \"✅ Preview complete! Run 'just deploy' to apply changes.\""
              ])
            false;

          deployRecipe =
            mkRecipeWithParams "deploy" [''env="${defaultStack}"''] "Deploy all Pulumi projects in dependency order"
            ([
                "#!/usr/bin/env bash"
                "set -euo pipefail"
                "env=\"\${1:-${defaultStack}}\""
                ""
              ]
              ++ validationLogic
              ++ [
                ""
                "set +e"
                ""
                "echo \"🚀 Deploying all Pulumi projects for \$env stack...\""
                "echo \"\""
                ""
                "failed_stacks=()"
                ""
              ]
              ++ lib.concatLists (lib.imap0 (i: s: let
                stepNum = i + 1;
                escapedPath = lib.escapeShellArg s.path;
                fallbackStack = lib.escapeShellArg (lib.head s.stacks);
                projectStackChecks = lib.concatStringsSep " || " (map (stack: "[[ \"\$env\" == ${lib.escapeShellArg stack} ]]") s.stacks);
              in
                if s.alwaysDeploy
                then [
                  "project_path=${escapedPath}"
                  "# Determine effective stack: use env if it matches, else fallback to ${lib.head s.stacks}"
                  "if ${projectStackChecks}; then"
                  "    _effective_stack=\"\$env\""
                  "else"
                  "    _effective_stack=${fallbackStack}"
                  "fi"
                  "printf '📦 Step ${toString stepNum}/${toString projectCount}: Deploying %s (stack: %s, alwaysDeploy)...\\n' \"\$project_path\" \"\$_effective_stack\""
                  "if ! ${pulumiExe} -C \"\$project_path\" up --yes --stack \"\$_effective_stack\"; then"
                  "    failed_stacks+=(\"\$project_path (\$_effective_stack)\")"
                  "fi"
                  "echo \"\""
                  ""
                ]
                else [
                  "project_path=${escapedPath}"
                  "if ${projectStackChecks}; then"
                  "    printf '📦 Step ${toString stepNum}/${toString projectCount}: Deploying %s...\\n' \"\$project_path\""
                  "    if ! ${pulumiExe} -C \"\$project_path\" up --yes --stack \"\$env\"; then"
                  "        failed_stacks+=(\"\$project_path (\$env)\")"
                  "    fi"
                  "else"
                  "    printf '⏭️  Step ${toString stepNum}/${toString projectCount}: Skipping %s (stack %s not configured for this project)\\n' \"\$project_path\" \"\$env\""
                  "fi"
                  "echo \"\""
                  ""
                ])
              stacks)
              ++ [
                "# Report summary"
                "if [ \${#failed_stacks[@]} -eq 0 ]; then"
                "    echo \"✅ All projects deployed successfully!\""
                "    exit 0"
                "else"
                "    echo \"⚠️  Deployment completed with failures\""
                "    echo \"\""
                "    echo \"❌ Failed projects:\""
                "    for stack in \"\${failed_stacks[@]}\"; do"
                "        echo \"   - \$stack\""
                "    done"
                "    exit 1"
                "fi"
              ])
            false;
        in
          if hasStacks
          then lib.concatStringsSep "\n\n" [previewRecipe deployRecipe]
          else "";
      };
    };
}
