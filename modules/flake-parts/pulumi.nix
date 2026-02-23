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

          # Collect all unique stack names across all projects for validation
          allStackNames = lib.unique (lib.concatMap (s: s.stacks) stacks);
          validStacksList = lib.concatStringsSep " " allStackNames;

          # Generate the preview recipe
          previewRecipe = mkRecipeWithParams "preview" ["env=\"\${1:-${defaultStack}}\""] "Preview changes for all Pulumi projects (run 'just deploy' to apply)"
            ([
              "#!/usr/bin/env bash"
              "set -euo pipefail"
              ""
              "# Validate stack name"
              "valid_stacks=(${validStacksList})"
              "if [[ ! \" \${valid_stacks[*]} \" =~ \" \$env \" ]]; then"
              "    echo \"❌ Unknown stack: \$env (valid: ${validStacksList})\""
              "    exit 1"
              "fi"
              ""
              "echo \"🔍 Previewing all Pulumi projects for \\$env stack...\""
              ""
            ]
            ++ lib.concatMap (s: [
              "echo \"\""
              "echo \"📦 Previewing ${s.path} (stack: \\$env)...\""
              "${pulumiExe} -C ${s.path} preview --stack \$env"
            ]) stacks
            ++ [
              ""
              "echo \"\""
              "echo \"✅ Preview complete! Run 'just deploy' to apply changes.\""
            ])
            true;

          # Generate the deploy recipe
          deployRecipe = mkRecipeWithParams "deploy" ["env=\"\${1:-${defaultStack}}\""] "Deploy all Pulumi projects in dependency order"
            ([
              "#!/usr/bin/env bash"
              ""
              "# Validate stack name"
              "valid_stacks=(${validStacksList})"
              "if [[ ! \" \${valid_stacks[*]} \" =~ \" \$env \" ]]; then"
              "    echo \"❌ Unknown stack: \$env (valid: ${validStacksList})\""
              "    exit 1"
              "fi"
              ""
              "set +e"
              ""
              "echo \"🚀 Deploying all Pulumi projects for \\$env stack...\""
              "echo \"\""
              ""
              "failed_stacks=()"
              ""
            ]
            ++ lib.concatLists (lib.imap0 (i: s: let
              stepNum = i + 1;
            in [
              "echo \"📦 Step ${toString stepNum}/${toString projectCount}: Deploying ${s.path}...\""
              "if ! ${pulumiExe} -C ${s.path} up --yes --stack \$env; then"
              "    failed_stacks+=(\"${s.path} (\$env)\")"
              "fi"
              "echo \"\""
              ""
            ]) stacks)
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
              "        echo \"   - \\$stack\""
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
