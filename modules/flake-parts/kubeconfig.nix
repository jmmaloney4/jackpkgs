{jackpkgsInputs}: {
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.kubeconfig;

  justfileHelpers = import ../../lib/justfile-helpers.nix {inherit lib;};
  inherit (justfileHelpers) mkRecipe;
in {
  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.kubeconfig = {
      enable = mkEnableOption "jackpkgs-kubeconfig";

      pulumiStackOutput = mkOption {
        type = types.submodule {
          options = {
            path = mkOption {
              type = types.str;
              description = "Path to the Pulumi project directory (relative to repo root) that exports a 'kubeconfig' stack output.";
            };
            stack = mkOption {
              type = types.str;
              default = "prod";
              description = "Pulumi stack name to query for the kubeconfig output.";
            };
          };
        };
        description = "Pulumi stack that exports a 'kubeconfig' output containing a complete kubeconfig YAML.";
      };
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      ...
    }: {
      options.jackpkgs.outputs.kubeconfigJustfile = mkOption {
        type = types.str;
        readOnly = true;
        description = "Generated justfile fragment for the kubeconfig recipe.";
      };

      options.jackpkgs.outputs.kubeconfigDevShell = mkOption {
        type = types.package;
        readOnly = true;
        description = "DevShell fragment that exports KUBECONFIG to a repo-local path.";
      };
    });
  };

  config =
    mkIf cfg.enable
    {
      # Kubeconfig requires pulumi to be enabled (for the pulumi binary)
      jackpkgs.pulumi.enable = lib.mkDefault true;

      perSystem = {
        pkgs,
        lib,
        config,
        ...
      }: let
        pulumiExe = lib.getExe' pkgs.pulumi-bin "pulumi";
        flakeRootExe = lib.getExe config.flake-root.package;

        kubeconfigRecipe =
          mkRecipe "kubeconfig"
          "Write kubeconfig from Pulumi stack output to $KUBECONFIG"
          [
            "#!/usr/bin/env bash"
            "set -euo pipefail"
            "if [ -z \"\\${KUBECONFIG:-}\" ]; then"
            "  echo \"KUBECONFIG not set — run from the nix devshell\" >&2"
            "  exit 1"
            "fi"
            "${pulumiExe} -C ${lib.escapeShellArg cfg.pulumiStackOutput.path} stack output kubeconfig --stack ${lib.escapeShellArg cfg.pulumiStackOutput.stack} --show-secrets > \"$KUBECONFIG\""
            "echo \"kubeconfig written to $KUBECONFIG\""
          ]
          false;
      in {
        jackpkgs.outputs.kubeconfigJustfile = kubeconfigRecipe;

        jackpkgs.outputs.kubeconfigDevShell = pkgs.mkShell {
          shellHook = ''
            export KUBECONFIG="$(${flakeRootExe})/kubeconfig.yaml"
          '';
        };

        jackpkgs.shell.inputsFrom = [
          config.jackpkgs.outputs.kubeconfigDevShell
        ];
      };
    };
}
