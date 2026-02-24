{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.pulumi;

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
          env = {
            PULUMI_IGNORE_AMBIENT_PLUGINS = "1";
            PULUMI_BACKEND_URL = cfg.backendUrl;
            PULUMI_SECRETS_PROVIDER = cfg.secretsProvider;
          };
        };

        devShells.ci-pulumi = pkgs.mkShell {
          packages = config.jackpkgs.pulumi.ci.packages;

          env = {
            PULUMI_IGNORE_AMBIENT_PLUGINS = "1";
            PULUMI_BACKEND_URL = cfg.backendUrl;
            PULUMI_SECRETS_PROVIDER = cfg.secretsProvider;
          };
        };

        jackpkgs.shell.inputsFrom = [
          config.jackpkgs.outputs.pulumiDevShell
        ];

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
            mkRecipeWithParams "preview" ["env=${defaultStack}"] "Preview changes for all Pulumi projects (run 'just deploy' to apply)"
            ([
                "#!/usr/bin/env bash"
                "set -euo pipefail"
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
                projectStackChecks = lib.concatStringsSep " || " (map (stack: "[[ \"\$env\" == ${lib.escapeShellArg stack} ]]") s.stacks);
              in [
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
            true;

          deployRecipe =
            mkRecipeWithParams "deploy" ["env=${defaultStack}"] "Deploy all Pulumi projects in dependency order"
            ([
                "#!/usr/bin/env bash"
                "set -euo pipefail"
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
                  projectStackChecks = lib.concatStringsSep " || " (map (stack: "[[ \"\$env\" == ${lib.escapeShellArg stack} ]]") s.stacks);
                in [
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
            true;
        in
          if hasStacks
          then lib.concatStringsSep "\n\n" [previewRecipe deployRecipe]
          else "";
      };
    };
}
